import Foundation

// Global nonisolated callback for llama_log_set — must not capture @MainActor context
// Only forward error-level messages from llama.cpp to our log (warn and info are noisy).
private func suppressLlamaLog(_ level: ggml_log_level, _ text: UnsafePointer<CChar>?, _ userData: UnsafeMutableRawPointer?) {
    guard level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text = text else { return }
    let msg = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !msg.isEmpty else { return }
    Log.error("[llama.cpp] \(msg)")
}


@MainActor
final class LlamaProvider {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private let inferenceQueue = DispatchQueue(label: "com.autocomplete.llama", qos: .userInitiated)

    nonisolated(unsafe) private var generationId: UInt64 = 0

    // Section-aware KV cache tracking.
    // Prompt: [BOS][systemInstruction][userContext\n\n][screenContext\n\n][scrollback\n\n][prefix]
    // Sections are ordered by expected stability (most stable first). Scrollback
    // sits between screen and prefix because it changes on terminal output —
    // more often than user/screen context, but stable across typing bursts.
    // We track each section's tokens separately so we can reuse stable sections.
    //
    // Threading invariant: these are ONLY read/written from inferenceQueue.async blocks.
    // They are marked `nonisolated(unsafe)` so nonisolated (queue-dispatched) code can
    // touch them. Any MainActor code that needs to clear them must do so inside
    // inferenceQueue.async so the write is serialized with runInference().
    nonisolated(unsafe) private var cachedBosTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedSystemTokens: [llama_token] = []
    // The former single `user` section, split into three independently-cached
    // sections so a volatile change (a clipboard copy or a new sent message)
    // no longer forces a re-decode of the static, often-large About-me block.
    // Prompt text order is unchanged (aboutMe → clipboard → messages); only
    // the cache granularity is finer.
    nonisolated(unsafe) private var cachedAboutMeTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedClipboardTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedMessagesTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedScreenTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedScrollbackTokens: [llama_token] = []
    // Text after the cursor (email quoted history, doc continuation) wrapped
    // with a "Below the cursor:" label and used as background context. Sits
    // between scrollback and prefix in the prompt. Empty for Claude Code
    // (the adapter clears suffix) and any other no-suffix scenario.
    nonisolated(unsafe) private var cachedSuffixContextTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedPrefixTokens: [llama_token] = []
    nonisolated(unsafe) private var cachedTotalCount: Int = 0

    // Speculative-prefill bookkeeping.
    // `latestPrefillEpoch` is bumped on MainActor in `prefill()` before each
    // enqueue; `runPrefill` bails if its captured epoch is stale (a newer
    // prefill superseded it — newest wins on rapid context changes). A real-
    // request bail reuses `generationId` (complete() bumps it; prefill never
    // does), so no separate "real request pending" flag is needed.
    nonisolated(unsafe) private var latestPrefillEpoch: UInt64 = 0
    // Token count the most recent speculative prefill warmed; read + reset by
    // the next runInference to tag its log line `prewarmed`. Touched only on
    // inferenceQueue (set in runPrefill, consumed in runInference).
    nonisolated(unsafe) private var lastPrefillWarmedCount: Int = 0
    // The prefill's pre-decode reuse (nCached at prefill start). A later real
    // request "benefited" from the prefill iff its own nCached exceeds this
    // baseline. Compared instead of lastPrefillWarmedCount because the real
    // request's prompt can be shorter than the warmed extent (e.g. the screen
    // OCR shifted between warm and keystroke), so nCached can never reach the
    // full warmed count even on a near-total hit. Touched only on inferenceQueue.
    nonisolated(unsafe) private var lastPrefillBaseline: Int = 0

    // llama.cpp sampler chain. Built once at model-load time with tuned
    // sampling defaults plus a logit_bias entry banning `<unused*>`, dialogue control tokens
    // (`<|turn>`, `<|channel>`, `<|think|>`, `<|tool*>`, `<|image>`, `<|audio>`),
    // and legacy dialogue markers. Addresses llama.cpp #21321/#21516 where
    // the model spontaneously samples these tokens, and ollama#15595 template
    // bleed-through. EOS/EOT are NOT banned — legitimate stop signals.
    // Owned by the inferenceQueue: initialised there at load, freed there on
    // unload. Never touched from MainActor after publication.
    nonisolated(unsafe) private var sampler: UnsafeMutablePointer<llama_sampler>?

    // Decoded text of every vocab token, indexed by token id. Built once at
    // model-load time on inferenceQueue. Used by the token-healing path to
    // find tokens whose piece text starts with the partial-word fragment the
    // user is typing (e.g. user types "mor", we look up `▁morning` ≈ "
    // morning" as a candidate to replace the `▁mor` token in the prompt).
    // Memory: ~256K strings, typically <10 MB total. Read-only after init.
    // See `tryHealLastToken` for the algorithm.
    nonisolated(unsafe) private var vocabPieces: [String] = []

    private(set) var isModelLoaded = false

    private let contextSize = 4096
    private let maxGenerationTokens = 10

    init() {
        #if DEBUG
        // Force the lazy promptLogURL static to initialise now (at app launch),
        // not on the first local request. Without this touch, the log keeps its
        // previous-session content until the first dumpPrompt call fires, which
        // is confusing when tailing the log after a relaunch.
        _ = Self.promptLogURL
        #endif
    }

    static let systemInstruction = _d(
        "kSWCSy5OMgbi39nA9QJOBsmME63fofZaFQanS3tczGe0ryocGPQ1SAnoF+vKJL8pwuxuWZqlGdFHYpH2OIZsSnEz4jS2HIutzuLVE1vo8adOfR0+4Tz9ggOgIxCVLU3BFXJZicpZMGrWhKNgbV4XwutYBR1jIo72RN2QPe+ovHGJet7VTmk9cWS5xlzyEZQbX/M8oVKUgJ9s2CHSNS8C+Y0moEJ7A0XcLJxtucm6/7OwQJJGXh7WYltfvCpTKLOqMdB8ZbrX77A7GqlgfS45X1E8DGtsVX7sJqrNXJX8a8RGI4SqcctL/R7IuVL7o6waWz0AsWkO6hIvCfaXrMTG3SJOZPcvW5Y0qC6RZTuN45FcvWQMhPBywwfmbGclq1M55mJ9Q5pxsTq8TozIDoFqdsp+uLWzh1wHXcADDjsih2+OuAo5fon7vDhUiD2OCOnav6bwyleRct7I0Y/rlBPM6wFrjw8fdgH8rU7dgcKjq7Q0DxMRbi8xOOSu/HUGOhheJFCFR40LoPRiHdv8IisZ5ER5AjC9LkkFvKquESOkKFLSia1xdyhdEORtVtvfO2Q1V0QbLYcK4ckm2Vjn8ImxYzLTABHbmSQLhdNREv8r4dEwHYFWPuBzLPIh8+9qvqlkO/VMvsW3VGbsYC9/It7dto59HgGkbTozrsgfgHvsriKXcImke1gjfYd+WDzA7LJ+2iJ6uwjeDuis2kyr06CWZ0tACbKWnI1Eo//ZKrTKcTxcBFYdm0knZuR5wG8ppROiYx5ZlYu+NBtAnnbGxx5NyqgkiaDZrwJeetXYZ/oeMKf0oSVY0UxFYfZFzBTqCxFoCW3q9nOyWArXmkHgDJB9Dg=="
    ) + "\n\n"


    func loadModel(path: String) throws {
        guard model == nil else { return }

        llama_backend_init()
        llama_log_set(suppressLlamaLog, nil)

        // Step 1: Load model from file
        let modelStart = CFAbsoluteTimeGetCurrent()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1

        // KV-override: lower the model's final_logit_softcapping from the GGUF
        // default 30.0 to 25.0. The softcap (logit = cap * tanh(logit/cap))
        // compresses the logit range — at cap=30 the range is wide enough that
        // many tokens cluster at high probability, contributing to the "all
        // outputs feel similar / digit-collapse" failure class. A user on
        // llama.cpp PR #21390 reported that lowering to 25 "introduces a lot
        // more diversity of output while staying coherent". The override is
        // applied at model-load time and bakes into hparams; not runtime
        // tunable. Build the array + sentinel inside withUnsafeBufferPointer
        // so it stays alive for the synchronous load call.
        var softcapOverride = llama_model_kv_override()
        softcapOverride.tag = LLAMA_KV_OVERRIDE_TYPE_FLOAT
        softcapOverride.val_f64 = 30.0
        Self.writeKvOverrideKey(_d("JKhtWJ0g7gesz6bEqO8SHAlpkBS/mY+cMowqnTnbNoVBkgXZQgUUH68wEuTcIcE1"), into: &softcapOverride)
        let sentinel = llama_model_kv_override() // zero-initialised → empty key terminates the array

        let loadedModel: OpaquePointer? = [softcapOverride, sentinel].withUnsafeBufferPointer { buf in
            modelParams.kv_overrides = buf.baseAddress
            return llama_model_load_from_file(path, modelParams)
        }

        guard let loadedModel = loadedModel else {
            throw LlamaError.modelLoadFailed
        }
        model = loadedModel
        let modelMs = (CFAbsoluteTimeGetCurrent() - modelStart) * 1000
        Log.info("[Startup] Model loaded in \(Int(modelMs))ms (kv_override: softcap=30.0)")

        // Step 2: Create context (allocates KV cache)
        let ctxStart = CFAbsoluteTimeGetCurrent()
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextSize)
        ctxParams.n_batch = 512
        // AUTO lets llama.cpp pick the FA kernel based on arch + context size.
        // ENABLED has reported hangs/slowdowns on Apple Silicon with prompts
        // >500 tokens (hybrid sliding-window attention edge case), so AUTO
        // is safer for our typical 1.5–3K context.
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO

        guard let loadedCtx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            model = nil
            throw LlamaError.contextCreationFailed
        }
        ctx = loadedCtx
        isModelLoaded = true
        let ctxMs = (CFAbsoluteTimeGetCurrent() - ctxStart) * 1000
        Log.info("[Startup] Context created (n_ctx=\(contextSize)) in \(Int(ctxMs))ms")

        // Step 3: build the llama.cpp sampler chain with tuned sampling
        // defaults, plus a logit_bias banning known-bad tokens.
        // Everything runs on inferenceQueue so the sampler's lifetime sits
        // entirely on that thread — MainActor never touches it. Order matches
        // common/sampling.cpp in llama.cpp:
        //   logit_bias → top_k → top_p → min_p → temp → dist
        if let vocab = llama_model_get_vocab(loadedModel) {
            let vocabPtr = SendablePointer(vocab)
            inferenceQueue.async { [weak self] in
                guard let self = self else { return }
                let banned = Self.buildBannedTokenSet(vocab: vocabPtr.pointer)
                let nVocab = Int32(llama_vocab_n_tokens(vocabPtr.pointer))

                let chainParams = llama_sampler_chain_default_params()
                guard let chain = llama_sampler_chain_init(chainParams) else {
                    Log.error("[Startup] llama_sampler_chain_init failed")
                    return
                }

                // Logit bias: permanent -infinity on each banned id. llama.cpp
                // copies the array internally, so `biasArray` may safely go
                // out of scope after the init call.
                if !banned.isEmpty {
                    let biasArray = banned.map { llama_logit_bias(token: $0, bias: -.infinity) }
                    biasArray.withUnsafeBufferPointer { buf in
                        if let biasSampler = llama_sampler_init_logit_bias(nVocab, Int32(biasArray.count), buf.baseAddress) {
                            llama_sampler_chain_add(chain, biasSampler)
                        }
                    }
                }

                // Tuned sampling defaults. Values also match the
                // `general.sampling.*` metadata embedded in the GGUF — but
                // llama.cpp does NOT auto-read those, so we set them
                // explicitly. min_keep=1 on top_p/min_p guarantees at least
                // one token survives.
                llama_sampler_chain_add(chain, llama_sampler_init_top_k(64))
                llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
                llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.0, 1))
                llama_sampler_chain_add(chain, llama_sampler_init_temp(0.2))
                // LLAMA_DEFAULT_SEED = 0xFFFFFFFF → draw from system clock each
                // session, so identical prefixes don't produce byte-identical
                // suggestions every time.
                llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

                self.sampler = chain
                Log.info("[Startup] Sampler chain initialised (banned \(banned.count) special/unused tokens)")

                // Step 4: Build vocab piece index for token healing (see
                // tryHealLastToken). One-shot ~256K llama_token_to_piece
                // calls — costs ~50-100ms but only runs once at model load.
                let healStart = CFAbsoluteTimeGetCurrent()
                let pieces = Self.buildVocabPieces(vocab: vocabPtr.pointer)
                self.vocabPieces = pieces
                let healMs = (CFAbsoluteTimeGetCurrent() - healStart) * 1000
                Log.info("[Startup] Vocab piece index built (\(pieces.count) tokens) in \(Int(healMs))ms")
            }
        }
    }

    /// Pre-decode the stable context (system instruction + user section) into
    /// the KV cache so the first real request only decodes the sections after
    /// `user` (screen/scrollback/suffix/prefix). The warmed tokens match only
    /// if the inputs are what Engine attaches to real requests: userContext
    /// must already be per-line normalized, and clipboard/message snapshots
    /// must come from the same histories Engine reads.
    func warmup(userContext: String?, clipboardItems: [String]?, recentMessages: [String]?) async {
        guard let model = model, let ctx = ctx else { return }
        let vocab = llama_model_get_vocab(model)!

        // Tokenize BOS
        var bosTokensBuf = [llama_token](repeating: 0, count: 1)
        let bosN = llama_tokenize(vocab, "", 0, &bosTokensBuf, 1, true, false)
        let bosTokens = bosN > 0 ? Array(bosTokensBuf.prefix(Int(bosN))) : []

        // Tokenize system instruction + the three user subsections (same
        // assembly as complete()). At startup clipboard/messages are usually
        // empty, so this typically warms bos + system + aboutMe.
        let systemTokens = tokenizeString(Self.systemInstruction, vocab: vocab)
        let (aboutMeText, clipboardText, messagesText) = Self.buildUserSections(
            userContext: userContext,
            clipboardItems: clipboardItems,
            recentMessages: recentMessages
        )
        let aboutMeTokens = tokenizeString(aboutMeText, vocab: vocab)
        let clipboardTokens = tokenizeString(clipboardText, vocab: vocab)
        let messagesTokens = tokenizeString(messagesText, vocab: vocab)

        let tokens = bosTokens + systemTokens + aboutMeTokens + clipboardTokens + messagesTokens
        guard !tokens.isEmpty else { return }

        let ctxPtr = SendablePointer(ctx)
        let localTokens = tokens

        Log.info("Warming up KV cache with \(localTokens.count) tokens...")
        let start = CFAbsoluteTimeGetCurrent()

        let decoded: Int = await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<Int, Never>) in
            self?.inferenceQueue.async { [weak self] in
                guard let self = self else { continuation.resume(returning: 0); return }
                let memory = llama_get_memory(ctxPtr.pointer)
                llama_memory_clear(memory, true)

                let batchSize = 512
                var batch = llama_batch_init(Int32(batchSize), 0, 1)
                defer { llama_batch_free(batch) }

                var offset = 0
                while offset < localTokens.count {
                    batch.n_tokens = 0
                    let chunkEnd = min(offset + batchSize, localTokens.count)
                    for i in offset..<chunkEnd {
                        let idx = Int(batch.n_tokens)
                        batch.token[idx] = localTokens[i]
                        batch.pos[idx] = llama_pos(i)
                        batch.n_seq_id[idx] = 1
                        batch.seq_id[idx]![0] = 0
                        batch.logits[idx] = (i == localTokens.count - 1) ? 1 : 0
                        batch.n_tokens += 1
                    }
                    let status = llama_decode(ctxPtr.pointer, batch)
                    if status != 0 {
                        let memMax = llama_memory_seq_pos_max(memory, 0)
                        Log.error("[LlamaProvider] warmup chunk failed: status=\(status) offset=\(offset) memMax=\(memMax)")
                        break
                    }
                    offset = chunkEnd
                }

                // Update section cache to reflect only what actually decoded.
                // Greedy fill in section order; each is cached only if `offset`
                // (tokens actually decoded) covers its full extent. Runs on
                // inferenceQueue — serialized with all other cache access.
                self.cachedBosTokens = []
                self.cachedSystemTokens = []
                self.cachedAboutMeTokens = []
                self.cachedClipboardTokens = []
                self.cachedMessagesTokens = []
                var remaining = offset
                if remaining >= bosTokens.count {
                    self.cachedBosTokens = bosTokens
                    remaining -= bosTokens.count
                    if remaining >= systemTokens.count {
                        self.cachedSystemTokens = systemTokens
                        remaining -= systemTokens.count
                        if remaining >= aboutMeTokens.count {
                            self.cachedAboutMeTokens = aboutMeTokens
                            remaining -= aboutMeTokens.count
                            if remaining >= clipboardTokens.count {
                                self.cachedClipboardTokens = clipboardTokens
                                remaining -= clipboardTokens.count
                                if remaining >= messagesTokens.count {
                                    self.cachedMessagesTokens = messagesTokens
                                    remaining -= messagesTokens.count
                                }
                            }
                        }
                    }
                }
                self.cachedScreenTokens = []
                self.cachedScrollbackTokens = []
                self.cachedSuffixContextTokens = []
                self.cachedPrefixTokens = []
                self.cachedTotalCount = max(0, offset)

                continuation.resume(returning: offset)
            }
        }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Log.info("KV cache warmup complete: \(decoded)/\(localTokens.count) tokens in \(Int(ms))ms")
    }

    private func tokenizeString(_ text: String, vocab: OpaquePointer) -> [llama_token] {
        guard !text.isEmpty else { return [] }
        let maxCount = Int32(text.utf8.count + 1)
        var tokens = [llama_token](repeating: 0, count: Int(maxCount))
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, maxCount, false, true)
        guard n > 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    /// Build a one-line markdown heading describing where the user is typing, e.g.
    /// `# Mail: Re: Project update — Inbox` or `# Messages`. Formatted so it
    /// resembles pretraining data (doc titles) rather than a special-token prompt.
    /// Empty string if both appName and windowTitle are empty.
    /// Skips windowTitle when it already contains appName to avoid "# Mail: … — Mail"
    /// redundancy (common on macOS where apps append their name to window titles).
    /// Window title is trimmed to 120 chars to keep header size bounded.
    private static func appHeader(appName: String, windowTitle: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if app.isEmpty && title.isEmpty { return "" }
        // Terminal window titles are volatile chrome: progress spinners (the
        // glyph is unstable — braille ⠂, star ✻, and whatever future versions
        // use), elapsed-time counters, running command, cwd. None of it is useful
        // document context, and any of it would change this header — and thus
        // churn the screen cache section — on every redraw. So for terminals key
        // the header on the app name alone and drop the title entirely; the
        // session content is already supplied to the model via scrollback.
        if !app.isEmpty, ClaudeCodeAdapter.isTerminal(appName: app) {
            return "# \(app)"
        }
        let cappedTitle = title.count > 120 ? String(title.prefix(120)) : title
        if app.isEmpty { return "# \(cappedTitle)" }
        if cappedTitle.isEmpty || cappedTitle.localizedCaseInsensitiveContains(app) {
            return "# \(app)"
        }
        return "# \(app): \(cappedTitle)"
    }

    /// Assemble the three user-context subsections — About me, Recently copied,
    /// Recently sent — as separate strings so each is tokenized and cached
    /// independently. Their concatenation in this order is byte-identical to
    /// what the former single `user` section produced, so the prompt the model
    /// sees is unchanged. Single source of truth shared by complete() and
    /// warmup(): the warmed KV tokens are reusable only if both build identical
    /// text, so neither may assemble these on its own.
    private static func buildUserSections(
        userContext: String?,
        clipboardItems: [String]?,
        recentMessages: [String]?
    ) -> (aboutMe: String, clipboard: String, messages: String) {
        // "About me:" reads like a bio/profile label common in blogs and social
        // profiles — natural pretraining data for a base model, and matches
        // that settings userContext is usually first-person. Static across a
        // session (only Settings edits change it), so its own cache section
        // ahead of the volatile clipboard/message sections lets it survive
        // their churn.
        var aboutMe = ""
        if let body = userContext, !body.isEmpty {
            aboutMe = "About me:\n" + body + "\n\n"
        }
        // Recent clipboard items (most recent first). Own cache section: a copy
        // invalidates this and what follows, but not About me above it.
        // Listed oldest → newest so the most recent item is closest to the
        // prefix (LLM attention falls off with distance, recency is what
        // typically matters for predicting next tokens).
        var clipboard = ""
        if let items = clipboardItems, !items.isEmpty {
            let body = items.reversed().enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            clipboard = "Recently copied:\n" + body + "\n\n"
        }
        // Recent sent-message texts captured by MessageHistory on Return +
        // 250ms confirmation or context transitions. Own cache section, last of
        // the three so a new send (the most frequent of the three in a chat
        // workflow) re-decodes the least. Same oldest→newest ordering.
        var messages = ""
        if let items = recentMessages, !items.isEmpty {
            let body = items.reversed().enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            messages = "Recently sent:\n" + body + "\n\n"
        }
        return (aboutMe, clipboard, messages)
    }

    #if DEBUG
    // Append-only log of every outgoing local prompt, one block per request.
    // Shares `~/.autocomplete-prompts.log` with CloudProvider — the `provider=`
    // field in the header disambiguates. Diffing consecutive blocks shows
    // exactly which bytes moved across keystrokes, useful for verifying that
    // section-cache-eligible sections (system/user/screen/scrollback) stay
    // byte-stable while the prefix changes.
    private static let promptLogURL: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".autocomplete-prompts.log")
        // createFile overwrites if the file exists — truncates on first use,
        // matching CloudProvider's same-file init and our ~/.autocomplete.log
        // convention. Each app launch starts with a clean log.
        // Note: if both providers' statics initialise in the same process
        // (provider switch mid-session), the second truncation wipes the
        // first's output. Negligible in practice — debug tooling only.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }()
    private static var promptSeq = 0

    private static func dumpPrompt(
        aboutMeText: String,
        clipboardText: String,
        messagesText: String,
        screenText: String,
        scrollbackText: String,
        suffixContextText: String,
        prefix: String,
        request: InferenceRequest
    ) {
        promptSeq += 1
        let ts = ISO8601DateFormatter().string(from: Date())
        let totalTokens = request.bos.count + request.system.count
            + request.aboutMe.count + request.clipboard.count + request.messages.count
            + request.screen.count + request.scrollback.count + request.suffixContext.count + request.prefix.count
        var block = "===== req #\(promptSeq)  \(ts)  provider=local =====\n"
        block += "tokens: bos=\(request.bos.count)"
        block += " system=\(request.system.count)"
        block += " aboutMe=\(request.aboutMe.count)"
        block += " clipboard=\(request.clipboard.count)"
        block += " messages=\(request.messages.count)"
        block += " screen=\(request.screen.count)"
        block += " scrollback=\(request.scrollback.count)"
        block += " suffixContext=\(request.suffixContext.count)"
        block += " prefix=\(request.prefix.count)"
        block += " total=\(totalTokens)\n"
        // The exact byte sequence handed to the tokenizer. <BOS> is prepended by
        // llama.cpp during tokenization (not part of the text), shown here as a
        // literal placeholder. The `│` pipe at the tail marks the cursor —
        // everything left of it is context, everything right of it is what we
        // want the model to generate.
        let systemText = Self.systemInstruction
        let assembled = systemText + aboutMeText + clipboardText + messagesText + screenText + scrollbackText + suffixContextText + prefix
        block += "--- prompt (chars=\(assembled.count + 5), tokens=\(totalTokens)) ---\n"
        block += "<BOS>\(assembled)│\n"
        block += "\n"
        guard let data = block.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: promptLogURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
    #endif

    /// Assemble an `InferenceRequest` from raw inputs: build each prompt
    /// section's text (app header, user sections, screen, scrollback, suffix
    /// context, framed prefix), strip the prefix's trailing whitespace, and
    /// tokenize every section. Shared by `complete()` (real requests) and
    /// `prefill()` (speculative warm) so both produce byte-identical tokens —
    /// any divergence here would turn a warmed prefill into a guaranteed cache
    /// miss. MainActor-isolated: `llama_tokenize` only reads `vocab`.
    /// `dump` gates the DEBUG prompt log so speculative prefills don't pollute
    /// the per-request prompt dump the real path emits.
    private func makeInferenceRequest(
        prefix: String,
        suffix: String?,
        suffixKind: SuffixKind,
        userContext: String?,
        screenContext: String?,
        scrollback: String?,
        clipboardItems: [String]?,
        recentMessages: [String]?,
        appName: String,
        windowTitle: String,
        maxTokens: Int,
        generationId: UInt64,
        vocab: OpaquePointer,
        dump: Bool
    ) -> (request: InferenceRequest, trailingWhitespaceCount: Int) {
        // Tokenize on MainActor — llama_tokenize only reads vocab (no ctx mutation),
        // safe to call from any thread. Doing it here avoids bouncing vocab strings
        // through the inferenceQueue.
        var bosTokensBuf = [llama_token](repeating: 0, count: 1)
        let bosN = llama_tokenize(vocab, "", 0, &bosTokensBuf, 1, true, false)
        let bosTokens = bosN > 0 ? Array(bosTokensBuf.prefix(Int(bosN))) : []

        let systemTokens = tokenizeString(Self.systemInstruction, vocab: vocab)

        // App/window context header. One markdown heading line based on appName +
        // windowTitle — mirrors the inline-label pattern used by Copilot, Mellum,
        // and Continue's CodeGeeX path, which works on base models because it
        // looks like pretraining data (doc titles, comments) rather than a
        // special-token prompt the model wasn't trained on.
        // Sits between recentMessages and screenContext (prepended to screenText)
        // so it pair-invalidates with screen on app/window switch — both change
        // together anyway — instead of hitching on user/clipboard/recentMessages
        // which churn on different triggers.
        let header = Self.appHeader(appName: appName, windowTitle: windowTitle)
        let (aboutMeText, clipboardText, messagesText) = Self.buildUserSections(
            userContext: userContext,
            clipboardItems: clipboardItems,
            recentMessages: recentMessages
        )
        // appHeader prepended to screenText so it travels with the screen
        // section's cache slot — both invalidate together on app/window switch.
        // "On screen:" frames the OCR dump as ambient context the user can see.
        let screenText: String = {
            let headerText = header.isEmpty ? "" : header + "\n\n"
            guard let sc = screenContext, !sc.isEmpty else { return headerText }
            return headerText + "On screen:\n" + sc + "\n\n"
        }()
        // "Previous conversation:" pairs with the "User:" chat-turn marker added
        // below; together they reframe the Claude Code scrollback as an
        // ongoing dialogue so the model predicts a user turn, not an
        // assistant continuation.
        let scrollbackText: String = {
            guard let sb = scrollback, !sb.isEmpty else { return "" }
            return "Previous conversation:\n" + sb + "\n\n"
        }()
        // Text after the cursor as background context. The base model has
        // no FIM tokens, so we can't use suffix as a fill-in target; instead
        // we present it as labelled context the model considers while
        // continuing from prefix. Critical for email replies (cursor at the
        // top of an empty reply, original email below) and mid-document
        // edits. AX often returns suffix prefixed with junk whitespace
        // (`\n\n`, cell padding) — strip leading whitespace before wrapping
        // so the model isn't shown a blank lead-in. Suppress the section
        // entirely if the suffix is whitespace-only after stripping.
        // Note: ClaudeCodeAdapter already returns `trimmedSuffix: ""` for
        // its windows, so this branch never fires there — Claude Code uses
        // scrollback for the same role.
        func strip(_ s: String) -> String {
            var t = s
            while let f = t.first, f.isWhitespace { t.removeFirst() }
            return t
        }
        // Email-aware: label the newest quoted message distinctly from older history —
        // descriptive noun-phrase labels ("Message being replied to:"), not directives;
        // base models read document structure, not instructions. Pairs with the
        // "Reply:" prefix framing below. Falls back to the generic "Below the cursor:"
        // for non-mail suffixes.
        let suffixContextText: String = {
            switch suffixKind {
            case .mailReply(let quote):
                // quote is authoritative here; the `suffix` param is unused for mail
                // (Engine guarantees lead+newest+older == trimmed suffix, lossless).
                // Proximity-ordered: older first, the message being replied to
                // nearest the "Reply:" framing, the user's own after-caret text
                // (lead) nearest of all. clean() also normalizes Word/Outlook
                // soft line breaks (\u{0B} etc.) to plain newlines — render-only.
                func clean(_ s: String) -> String {
                    String(s.map { $0.isNewline && $0 != "\n" ? Character("\n") : $0 })
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let newest = clean(quote.newest)
                if newest.isEmpty { return "" }
                var out = ""
                if let older = quote.older {
                    let o = clean(older)
                    if !o.isEmpty { out += "Earlier messages (reference only):\n" + o + "\n\n" }
                }
                out += "Message being replied to:\n" + newest + "\n\n"
                let lead = clean(quote.lead)
                if !lead.isEmpty { out += "Below the cursor:\n" + lead + "\n\n" }
                return out
            case .plain:
                guard let s = suffix, !strip(s).isEmpty else { return "" }
                return "Below the cursor:\n" + strip(s) + "\n\n"
            }
        }()

        // When scrollback is present (today: Claude Code), the last thing the
        // model sees without intervention is Claude Code's assistant output,
        // and a base LM will naturally continue as the assistant (more tool
        // logs, more bullets) instead of suggesting what the *user* is about
        // to type. Prepend a chat-turn marker to the prefix so the model
        // interprets the cursor position as a user message rather than an
        // assistant continuation. `User:` is ubiquitous in pretraining chat
        // corpora (ShareGPT / forums / Q&A), so a base model recognises it
        // as a role cue without needing special tokens. The marker sits at
        // the very start of the prefix section; its tokens are byte-stable
        // across keystrokes and match via the per-token prefix overlap, so
        // cache cost is the one-time decode on the first request.
        //
        // Special case — empty prefix in a scrollback context (user just
        // opened the input box, hasn't typed yet). The naive "User: " framing
        // ends with a colon-space and the base model reads the empty turn
        // as a finished one, sampling EOG immediately → empty output. Switch
        // to a narrative framing — pretraining sees `... typed: ...` patterns
        // in chat-log analysis and dialogue passages, which biases the model
        // toward continuing with predicted user content rather than emitting
        // a stop signal.
        //
        // Mail replies get a first-person variant: with an empty prefix the
        // generic "Continuing, the user typed:" left "the user" unbound, and
        // the base model continued in the quoted counterpart's voice — the
        // nearest salient author in the document is the quoted sender
        // (observed in live QA). "Then I wrote:" opens a new turn in the
        // thread's attribution idiom ("… wrote:") whose author ("I") is
        // distinct from every named quoted sender, so the model writes as
        // the user instead of the counterpart.
        let framedPrefix: String
        if let sb = scrollback, !sb.isEmpty {
            // Claude Code-style chat context.
            if prefix.isEmpty {
                framedPrefix = "Continuing the conversation, the user typed: "
            } else {
                framedPrefix = "User: " + prefix
            }
        } else if case .mailReply = suffixKind, !suffixContextText.isEmpty {
            // Mail reply: open the next turn in the thread's own idiom
            // ("… wrote:") with a first-person author, so the base model
            // writes as the user rather than continuing the quoted
            // counterpart's voice (observed in live QA with an empty prefix).
            // Works for both empty and non-empty prefixes — "wrote:\n" is
            // near-always followed by body text in pretraining, so the empty
            // case carries no EOG risk.
            // A/B note (2026-06-11, user preference): name dropped from the
            // framing — the account name (NSFullUserName) often differs from
            // the name the user signs with, and "I" alone still binds the
            // turn. If counterpart-voice output returns, the stronger binding
            // to restore is "Then I (<NSFullUserName()>) wrote:\n".
            framedPrefix = "Then I wrote:\n" + prefix
        } else if !suffixContextText.isEmpty {
            // Suffix-context (email reply, mid-doc edit with content below
            // the cursor). Without a label here, the base model treats the
            // bare prefix as continuation of whatever's in the suffix
            // section — it keeps writing the original email instead of the
            // user's distinct reply. The "Reply:" label is a strong signal
            // (pretraining sees `> quoted\n\nReply: ...` patterns in email
            // and forum data) that demarcates the prefix as a separate,
            // user-authored response. Empty prefix uses narrative framing
            // ("Continuing, the user typed:") for the same anti-EOG reason
            // as the Claude Code empty case.
            if prefix.isEmpty {
                framedPrefix = "Continuing, the user typed: "
            } else {
                framedPrefix = "Reply: " + prefix
            }
        } else {
            // A/B EXPERIMENT (2026-06-10, user request; name dropped
            // 2026-06-11): first-person framing on the plain-continuation
            // branch too. Watch QA in non-prose contexts (terminal without
            // Claude Code, code editors, Notes, search fields) for
            // prose-register drift, quoted/summarized output, or post-snippet
            // narration. Revert path: bare `framedPrefix = prefix` (the
            // pre-experiment behavior — no label cues "natural document
            // continuation" mode).
            framedPrefix = "Then I wrote:\n" + prefix
        }

        // Strip trailing whitespace from the prefix BEFORE tokenizing. The
        // SentencePiece BPE tokenizer uses word-initial tokens (` word`,
        // ` finishes`) — space is leading, not trailing. A prefix that ends
        // with a bare space token puts the model in an out-of-distribution
        // state where EOS (the highest unconditional prior) wins the
        // first-token sample, producing empty output. The tokenizer docs
        // explicitly warn: "it is important to not add a trailing space as
        // it would make the output out of distribution." We strip here and
        // un-double at output time so the user's caret position stays clean.
        let (trimmedFramedPrefix, trailingWhitespaceCount): (String, Int) = {
            var s = framedPrefix
            var n = 0
            while let last = s.last, last.isWhitespace {
                s.removeLast()
                n += 1
            }
            return (s, n)
        }()

        let aboutMeTokens = tokenizeString(aboutMeText, vocab: vocab)
        let clipboardTokens = tokenizeString(clipboardText, vocab: vocab)
        let messagesTokens = tokenizeString(messagesText, vocab: vocab)
        let screenTokens = tokenizeString(screenText, vocab: vocab)
        let scrollbackTokens = tokenizeString(scrollbackText, vocab: vocab)
        let suffixContextTokens = tokenizeString(suffixContextText, vocab: vocab)
        let prefixTokens = tokenizeString(trimmedFramedPrefix, vocab: vocab)

        let request = InferenceRequest(
            bos: bosTokens,
            system: systemTokens,
            aboutMe: aboutMeTokens,
            clipboard: clipboardTokens,
            messages: messagesTokens,
            screen: screenTokens,
            scrollback: scrollbackTokens,
            suffixContext: suffixContextTokens,
            prefix: prefixTokens,
            totalBudget: contextSize - maxGenerationTokens,
            maxTokens: min(maxTokens, maxGenerationTokens),
            generationId: generationId,
            prefixHadTrailingWhitespace: trailingWhitespaceCount > 0
        )

        #if DEBUG
        if dump {
            Self.dumpPrompt(
                aboutMeText: aboutMeText,
                clipboardText: clipboardText,
                messagesText: messagesText,
                screenText: screenText,
                scrollbackText: scrollbackText,
                suffixContextText: suffixContextText,
                prefix: trimmedFramedPrefix,
                request: request
            )
        }
        #endif

        return (request, trailingWhitespaceCount)
    }

    func complete(
        prefix: String,
        suffix: String? = nil,
        suffixKind: SuffixKind,  // Engine's computed kind; no default — a defaulted .plain silently loses mail labels
        userContext: String? = nil,
        screenContext: String? = nil,
        scrollback: String? = nil,
        clipboardItems: [String]? = nil,
        recentMessages: [String]? = nil,
        appName: String = "",
        windowTitle: String = "",
        maxTokens: Int = 10,
        midDecodeCancelEnabled: Bool = false
    ) async throws -> String {
        guard let model = model, let ctx = ctx else {
            throw LlamaError.modelNotLoaded
        }

        generationId += 1
        let thisGeneration = generationId

        let vocab = llama_model_get_vocab(model)!

        let (request, trailingWhitespaceCount) = makeInferenceRequest(
            prefix: prefix,
            suffix: suffix,
            suffixKind: suffixKind,
            userContext: userContext,
            screenContext: screenContext,
            scrollback: scrollback,
            clipboardItems: clipboardItems,
            recentMessages: recentMessages,
            appName: appName,
            windowTitle: windowTitle,
            maxTokens: maxTokens,
            generationId: thisGeneration,
            vocab: vocab,
            dump: true
        )

        let ctxPtr = SendablePointer(ctx)
        let vocabPtr = SendablePointer(vocab)

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: LlamaError.modelNotLoaded); return
            }
            self.inferenceQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: LlamaError.modelNotLoaded); return
                }
                if self.generationId != thisGeneration {
                    continuation.resume(returning: "")
                    return
                }
                do {
                    var text = try self.runInference(
                        ctx: ctxPtr.pointer,
                        vocab: vocabPtr.pointer,
                        request: request,
                        midDecodeCancelEnabled: midDecodeCancelEnabled
                    )
                    // If we stripped trailing whitespace from the tokenizer
                    // input, the model typically emits a word-initial token
                    // starting with a space (` and`, ` with`). Strip up to N
                    // leading whitespace chars from the output so the insertion
                    // at the user's caret (which already sits after their
                    // trailing space) doesn't double up.
                    var stripped = 0
                    while stripped < trailingWhitespaceCount,
                          text.first?.isWhitespace == true {
                        text.removeFirst()
                        stripped += 1
                    }
                    // Strip HTML/XML-like tags from the output. The base
                    // model is prone to wrapping suggestions in `<b>...`,
                    // `<code>` etc. when the prompt context is structure-heavy
                    // (Claude Code scrollback with code blocks, markdown
                    // headers, tool output) — markup-leakage failure class
                    // documented in ollama#15595. Pattern requires the first
                    // char after `<` to be non-whitespace and non-`<>` so
                    // that `< 3`, standalone `<`, and unpaired `<` in user
                    // text are preserved.
                    text = text.replacingOccurrences(
                        of: #"<[^<>\s][^<>]*>"#,
                        with: "",
                        options: .regularExpression
                    )
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Speculatively warm the KV cache for `context` without generating
    /// (fire-and-forget; no UI, no suggestion). Builds the exact same sections
    /// as `complete()` via `makeInferenceRequest`, then decodes bos…suffixContext
    /// on the inferenceQueue. Never bumps `generationId` (so it can't cancel a
    /// real request) and supersedes older in-flight prefills via
    /// `latestPrefillEpoch` (newest wins). The framed prefix is intentionally
    /// excluded from the warm — see `runPrefill`.
    func prefill(
        prefix: String,
        suffix: String? = nil,
        suffixKind: SuffixKind,
        userContext: String? = nil,
        screenContext: String? = nil,
        scrollback: String? = nil,
        clipboardItems: [String]? = nil,
        recentMessages: [String]? = nil,
        appName: String = "",
        windowTitle: String = "",
        midDecodeCancelEnabled: Bool = false
    ) async {
        guard let model = model, let ctx = ctx else { return }
        let vocab = llama_model_get_vocab(model)!

        // UInt64.max: a sentinel generation that can never collide with a real
        // one. runPrefill never reads request.generationId (it bails off the
        // live `generationId` vs the captured `generationAtFire`), but the
        // factory requires a value — this documents "speculative, not cancellable
        // via generationId".
        let (request, _) = makeInferenceRequest(
            prefix: prefix,
            suffix: suffix,
            suffixKind: suffixKind,
            userContext: userContext,
            screenContext: screenContext,
            scrollback: scrollback,
            clipboardItems: clipboardItems,
            recentMessages: recentMessages,
            appName: appName,
            windowTitle: windowTitle,
            maxTokens: maxGenerationTokens,
            generationId: UInt64.max,
            vocab: vocab,
            dump: false
        )

        // Bump epoch + snapshot the live generation on MainActor BEFORE the
        // enqueue, so the dispatch's happens-before edge carries both to
        // runPrefill's bail checks (same discipline as `generationId`).
        latestPrefillEpoch &+= 1
        let myEpoch = latestPrefillEpoch
        let generationAtFire = generationId
        let ctxPtr = SendablePointer(ctx)

        await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<Void, Never>) in
            guard let self = self else { continuation.resume(); return }
            self.inferenceQueue.async { [weak self] in
                guard let self = self else { continuation.resume(); return }
                self.runPrefill(
                    ctx: ctxPtr.pointer,
                    request: request,
                    epoch: myEpoch,
                    generationAtFire: generationAtFire,
                    midDecodeCancelEnabled: midDecodeCancelEnabled
                )
                continuation.resume()
            }
        }
    }

    /// Runs on inferenceQueue — owns cached* state alongside llama.cpp memory.
    /// All section matching, nCached computation, decode, and cache sync happen here,
    /// serialized by the queue so no MainActor↔queue race is possible. Prompt decode
    /// can be cancelled between batches when `midDecodeCancelEnabled` is set: a
    /// superseded request bails at the next 512-token boundary and syncCaches the
    /// partial decode, so the KV cache is always consistent at exit. Generation is
    /// likewise cancellable between tokens via the `generationId` check.
    private nonisolated func runInference(
        ctx: OpaquePointer,
        vocab: OpaquePointer,
        request: InferenceRequest,
        midDecodeCancelEnabled: Bool
    ) throws -> String {
        let memory = llama_get_memory(ctx)

        // === Token-healing setup ===
        // If the user's last typed token is a partial-word fragment
        // (`▁mor`, `▁loo`), we'll DROP it from the prompt decode and
        // replace it with a constrained sample below. This rebinds the
        // last-position KV to whatever whole-word token the model actually
        // wants there (`▁morning`, `▁looking`), fixing both the empty-
        // output case (`loo` → "") and the wrong-continuation case
        // (`mor` → "moring"). When `healCandidate == nil`, the rest of
        // this function behaves identically to the no-healing version.
        let healCandidate: llama_token?
        let healPiece: String
        let effectivePrefix: [llama_token]
        // Skip healing when the user typed trailing whitespace before
        // their last char was tokenized — they have explicitly closed
        // the previous word boundary (e.g. "lo " means "I'm done with
        // 'lo', start a new word"). complete() strips that trailing
        // whitespace before tokenizing (the tokenizer's trailing-space →
        // OOD empty-output mitigation), so without this guard healing fires
        // on what looks like "▁lo at the tail" and tries to extend it
        // into ▁looking — wrong: the user wants a fresh word, not an
        // extension of the previous one.
        if !vocabPieces.isEmpty,
           !request.prefixHadTrailingWhitespace,
           let lastTok = request.prefix.last,
           Int(lastTok) < vocabPieces.count,
           isHealablePiece(vocabPieces[Int(lastTok)]) {
            healCandidate = lastTok
            healPiece = vocabPieces[Int(lastTok)]
            effectivePrefix = Array(request.prefix.dropLast())
        } else {
            healCandidate = nil
            healPiece = ""
            effectivePrefix = request.prefix
        }

        // Section match against cache. Sections ordered [BOS][system][user][screen][scrollback][suffixContext][prefix];
        // reuse everything up to (and including) the first section that changed.
        // Note: healing trims the last prefix token, so prefix-overlap
        // counting uses `effectivePrefix` (the trimmed version) rather
        // than `request.prefix`.
        // Whole-section match in prompt order: reuse the KV cache up to the
        // first section whose tokens differ. Prefix is matched separately
        // below via per-token overlap. An ordered walk (rather than a boolean
        // cascade with hand-summed cumulative counts) means splitting or adding
        // a section is a one-line list change and the counts can't drift out of
        // sync with syncCache.
        let orderedSections: [(req: [llama_token], cached: [llama_token])] = [
            (request.bos, cachedBosTokens),
            (request.system, cachedSystemTokens),
            (request.aboutMe, cachedAboutMeTokens),
            (request.clipboard, cachedClipboardTokens),
            (request.messages, cachedMessagesTokens),
            (request.screen, cachedScreenTokens),
            (request.scrollback, cachedScrollbackTokens),
            (request.suffixContext, cachedSuffixContextTokens),
        ]
        var nCached = 0
        var allSectionsMatched = true
        for section in orderedSections {
            if section.req == section.cached {
                nCached += section.req.count
            } else {
                allSectionsMatched = false
                break
            }
        }
        // Per-token prefix overlap only when every whole section above matched
        // (otherwise KV positions have shifted and the prefix can't align).
        if allSectionsMatched {
            let prefixOverlap = min(effectivePrefix.count, cachedPrefixTokens.count)
            for i in 0..<prefixOverlap {
                if effectivePrefix[i] == cachedPrefixTokens[i] { nCached += 1 } else { break }
            }
        }

        // Defence in depth: if the cache thinks more positions are in memory than
        // really are, reset. Should be unreachable now that prompt decode is atomic,
        // but keep the guard so we self-heal if anything else ever mutates memory.
        let memMax = Int(llama_memory_seq_pos_max(memory, 0))
        if nCached > memMax + 1 {
            Log.error("[Cancel][DRIFT] over-claim nCached=\(nCached) memMax=\(memMax) — resetting")
            nCached = 0
        }

        // Assemble full token array (using effectivePrefix when healing —
        // we'll replace the dropped token via the heal step below),
        // truncating if over the context budget.
        var tokens = request.bos + request.system + request.aboutMe + request.clipboard + request.messages + request.screen + request.scrollback + request.suffixContext + effectivePrefix
        if tokens.count > request.totalBudget {
            Log.debug("[LlamaProvider] Truncating: \(tokens.count) tokens > budget \(request.totalBudget)")
            tokens = Array(tokens.suffix(request.totalBudget))
            nCached = 0  // truncation shifts positions, cache invalid
        }
        // Did a speculative prefill warm the sections this request is reusing?
        // `prewarmed` is true when the real request's reuse (nCached) covers at
        // least the prefill's warmed extent. Consume the marker — one prefill
        // credits at most one real request — so a later cold request reads false.
        let prewarmed = lastPrefillWarmedCount > 0 && nCached > lastPrefillBaseline
        lastPrefillWarmedCount = 0
        lastPrefillBaseline = 0
        Log.debug("[LlamaProvider] tokens=\(tokens.count) nCached=\(nCached) new=\(tokens.count - nCached) healing=\(healCandidate != nil) prewarmed=\(prewarmed)")

        // Layer 1a: pre-mutation bail. If a newer request superseded us before we
        // touched KV memory, return now — memory + cache stay at the prior full
        // state, so the next request reuses everything. No syncCache: nothing
        // was mutated.
        if midDecodeCancelEnabled && self.generationId != request.generationId {
            Log.debug("[Cancel] bail @prompt pre-mutation gen=\(request.generationId)")
            return ""
        }

        // Built before the decode loop so the between-batch bail and the
        // post-loop sync share one definition. When healing, the cache must
        // reflect effectivePrefix (the dropped last token sits outside the cache).
        let cacheRequest = healCandidate != nil
            ? InferenceRequest(
                bos: request.bos, system: request.system,
                aboutMe: request.aboutMe, clipboard: request.clipboard, messages: request.messages,
                screen: request.screen, scrollback: request.scrollback,
                suffixContext: request.suffixContext, prefix: effectivePrefix,
                totalBudget: request.totalBudget, maxTokens: request.maxTokens,
                generationId: request.generationId,
                prefixHadTrailingWhitespace: request.prefixHadTrailingWhitespace)
            : request

        if nCached > 0 {
            _ = llama_memory_seq_rm(memory, 0, Int32(nCached), -1)
        } else {
            llama_memory_clear(memory, true)
        }

        // Decode prompt tokens in chunks. With midDecodeCancelEnabled, bail at a
        // batch boundary if superseded (Layer 1b). On failure, clear and surface.
        let newTokens = Array(tokens.dropFirst(nCached))
        let batchSize = 512
        var promptTokensProcessed = 0
        if !newTokens.isEmpty {
            var batch = llama_batch_init(Int32(batchSize), 0, 1)
            defer { llama_batch_free(batch) }

            var offset = 0
            while offset < newTokens.count {
                #if DEBUG
                LlamaStressHooks.onPromptBatch?(offset / batchSize)
                #endif
                // Layer 1b: between-batch bail. promptTokensProcessed counts only
                // completed batches, so KV memory holds exactly [0, nCached+processed);
                // syncCache records ≤ that (cachedTotalCount = exact count), so the
                // next request reuses validated positions and re-decodes the rest.
                if midDecodeCancelEnabled && self.generationId != request.generationId {
                    let synced = nCached + promptTokensProcessed
                    syncCache(totalProcessed: synced, request: cacheRequest, tokens: tokens)
                    Log.debug("[Cancel] bail @prompt processed=\(promptTokensProcessed)/\(newTokens.count) synced=\(synced) gen=\(request.generationId)")
                    #if DEBUG
                    LlamaStressHooks.promptBailCount += 1
                    #endif
                    return ""
                }
                batch.n_tokens = 0
                let chunkEnd = min(offset + batchSize, newTokens.count)
                for i in offset..<chunkEnd {
                    let idx = Int(batch.n_tokens)
                    batch.token[idx] = newTokens[i]
                    batch.pos[idx] = llama_pos(nCached + i)
                    batch.n_seq_id[idx] = 1
                    batch.seq_id[idx]![0] = 0
                    batch.logits[idx] = (i == newTokens.count - 1) ? 1 : 0
                    batch.n_tokens += 1
                }
                let status = llama_decode(ctx, batch)
                if status != 0 {
                    Log.error("[LlamaProvider] decodeFailed@prompt status=\(status) nCached=\(nCached) newTokens=\(newTokens.count) offset=\(offset) totalTokens=\(tokens.count)")
                    resetCacheAndMemory(memory: memory)
                    throw LlamaError.decodeFailed
                }
                promptTokensProcessed += (chunkEnd - offset)
                offset = chunkEnd
            }
        } else if nCached > 0 {
            // Exact cache hit — re-decode the last cached token to get fresh logits
            // (stale logits from the previous sample position would be wrong).
            let lastPos = Int32(tokens.count - 1)
            _ = llama_memory_seq_rm(memory, 0, lastPos, lastPos + 1)

            let lastToken = tokens[tokens.count - 1]
            var batch = llama_batch_init(1, 0, 1)
            defer { llama_batch_free(batch) }
            batch.n_tokens = 1
            batch.token[0] = lastToken
            batch.pos[0] = llama_pos(lastPos)
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            let status = llama_decode(ctx, batch)
            if status != 0 {
                Log.error("[LlamaProvider] decodeFailed@reeval status=\(status) lastPos=\(lastPos) totalTokens=\(tokens.count) nCached=\(nCached)")
                resetCacheAndMemory(memory: memory)
                throw LlamaError.decodeFailed
            }
        }

        // Sync cache sections to reflect exactly what's in memory now.
        // When healing, the cache reflects effectivePrefix (without the
        // dropped last token) — the heal-decoded token below sits OUTSIDE
        // the cache so the next request's section match cleanly invalidates
        // it on any prefix change.
        let totalProcessed = nCached + promptTokensProcessed
        syncCache(
            totalProcessed: totalProcessed,
            request: cacheRequest,
            tokens: tokens
        )

        // === Healing step ===
        // Sample one token under a hard mask that allows only tokens whose
        // piece text starts with `healPiece`. The sampled token is decoded
        // at position `tokens.count`, taking the slot the dropped original
        // would have occupied. From here on, the generation loop sees the
        // same KV layout it would have for a non-healed prompt.
        var healedFirstPiece = ""
        var currentPos = llama_pos(tokens.count)
        if let original = healCandidate {
            // Bail if the request was cancelled while the prompt was
            // decoding. Without this, the heal step's ~30–50 ms decode
            // still runs in full and the generation loop's first iteration
            // is the one that exits — wasted work on every rapid-typing
            // burst.
            if self.generationId != request.generationId { return "" }
            let extensions = extensionsOf(prefix: healPiece, original: original)
            let nVocab32 = Int32(llama_vocab_n_tokens(vocab))
            let healed: llama_token
            if extensions.count <= 1 {
                // Only the original matches — healing wouldn't change the
                // outcome, but we still need to put a token at this slot.
                healed = original
            } else if let healChain = makeHealChain(allowed: extensions, nVocab: nVocab32) {
                healed = llama_sampler_sample(healChain, ctx, -1)
                llama_sampler_free(healChain)
            } else {
                healed = original
            }

            var healBatch = llama_batch_init(1, 0, 1)
            defer { llama_batch_free(healBatch) }
            healBatch.n_tokens = 1
            healBatch.token[0] = healed
            healBatch.pos[0] = currentPos
            healBatch.n_seq_id[0] = 1
            healBatch.seq_id[0]![0] = 0
            healBatch.logits[0] = 1
            let status = llama_decode(ctx, healBatch)
            if status != 0 {
                Log.error("[LlamaProvider] heal decode failed status=\(status)")
                resetCacheAndMemory(memory: memory)
                throw LlamaError.decodeFailed
            }
            currentPos += 1

            if Int(healed) < vocabPieces.count {
                healedFirstPiece = vocabPieces[Int(healed)]
            }
            // Keep the main sampler chain's history consistent with what
            // actually got decoded. No-op for our chain (no penalty
            // samplers), but cheap insurance against future config drift.
            if let mainSampler = self.sampler {
                llama_sampler_accept(mainSampler, healed)
            }
            Log.debug("[LlamaProvider] heal: original=\(original) (\(healPiece.debugDescription)) → healed=\(healed) (\(healedFirstPiece.debugDescription)), \(extensions.count) extensions")
        }

        // Generate tokens. Cancellation between tokens is safe — generated positions
        // aren't part of our cached prompt tracking, and the next request will
        // seq_rm them away before decoding fresh.
        var generated = healedFirstPiece
        var genBatch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(genBatch) }
        var buf = [CChar](repeating: 0, count: 64)

        guard let sampler = self.sampler else { return "" }

        // The healed token counts toward the generation budget — don't
        // double-spend by generating a full `maxTokens` more on top.
        let genBudget = healCandidate != nil ? max(0, request.maxTokens - 1) : request.maxTokens
        for _ in 0..<genBudget {
            if self.generationId != request.generationId { break }

            // llama.cpp built-in sampler chain: reads logits from the last
            // decoded position (idx=-1), runs logit_bias → top_k → top_p →
            // min_p → temp → dist internally in native C++, returns the
            // sampled token.
            let nextToken = llama_sampler_sample(sampler, ctx, -1)

            // Use llama_vocab_is_eog — checks the full EOG set (EOS + EOT +
            // `<|tool_response>`), not just `eos_token_id`. Comparing only
            // against llama_vocab_eos/eot misses `<|tool_response>` (id 50)
            // which is also a legitimate stop.
            if llama_vocab_is_eog(vocab, nextToken) { break }

            let len = llama_token_to_piece(vocab, nextToken, &buf, 64, 0, true)
            if len > 0 {
                let piece = String(bytes: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                if piece.contains("\n") { break }
                generated += piece
            }

            genBatch.n_tokens = 1
            genBatch.token[0] = nextToken
            genBatch.pos[0] = currentPos
            genBatch.n_seq_id[0] = 1
            genBatch.seq_id[0]![0] = 0
            genBatch.logits[0] = 1

            let status = llama_decode(ctx, genBatch)
            if status != 0 { break }
            currentPos += 1
        }

        // === Healing output cleanup ===
        // Strip ONLY the BPE leading-space marker from the front of the
        // generated text — Engine.PostProcessor.trimOverlap (called by
        // Engine.handleCompletionResult) handles the rest of the overlap.
        //
        // Background: the SentencePiece BPE tokenizer encodes whole-word
        // tokens with a leading `▁` (U+2581) that decodes to ' '. Our healed
        // token's piece (e.g. " looking") therefore starts with a space
        // representing a "word boundary" — sometimes that space is real
        // (user typed "Hello lo" → `lo` is preceded by a literal space)
        // and sometimes it's a tokenizer artifact (user typed "lo" at
        // start of doc → no literal space, `▁lo`'s leading space is
        // virtual).
        //
        // If the user's prefix ends with whitespace OR contains the
        // healPiece's leading space as a real char, leave the leading
        // space in `generated`: trimOverlap will detect the full-piece
        // overlap (e.g. " lo" matching " lo") and strip the right chars.
        //
        // If the user's prefix DOES NOT end with whitespace, the leading
        // space in `generated` is a virtual BPE marker that has no
        // corresponding char in the prefix. trimOverlap, which compares
        // literal characters, can't see it as overlap (single-char
        // " " ≠ user's last typed letter), so it would either fail to
        // strip enough OR find a coincidental 1-char tail-match like
        // "Thanks Manu, lo"+"o" → strip just "o" → produces "king…"
        // instead of "oking…". By stripping the BPE leading-WS here,
        // trimOverlap is left with a clean word-to-word overlap (e.g.
        // "lo" matching "lo") that it handles correctly.
        // Strip the entire healPiece (not just leading whitespace). By the
        // makeHealChain constraint, the healed token's piece always starts
        // with healPiece, so generated's first healPiece.count chars are
        // guaranteed redundant with the prefix's tail — not coincidental
        // overlap. trimOverlap's mid-word floor (≥2 chars for alphanumeric
        // tails) otherwise blocks the 1-char case ("coty"+"ypist" → can't
        // strip the leading "y"; "...它"+"它：" → can't strip "它"), which
        // produces visible duplication. Guarded on !prefixHadTrailingWhitespace
        // so the case where the prefix's trailing space is "real" still leaves
        // overlap detection to trimOverlap (see commentary above on BPE
        // leading-space ambiguity).
        if !healPiece.isEmpty && !request.prefixHadTrailingWhitespace {
            if generated.hasPrefix(healPiece) {
                generated.removeFirst(healPiece.count)
            }
        }

        return generated
    }

    /// Speculative, prefill-only sibling of `runInference`: warms the KV cache
    /// for `bos…suffixContext` (NOT the prefix) and returns. No healing, no
    /// sampling, no generation. Runs on inferenceQueue, so it shares cached*
    /// with runInference under the queue's serialization.
    ///
    /// Three consistent exits, each leaving cache tracking and llama memory in
    /// agreement: (1) pre-mutation bail — superseded by a newer prefill or a
    /// real request — returns before any seq_rm/decode, so nothing changed;
    /// (2) clean completion — syncCache records exactly what decoded, with an
    /// EMPTY prefix slot (we never decode the framed prefix, so `remaining`
    /// hits 0 at suffixContext and cachedPrefixTokens lands []); the next real
    /// keystroke decodes its correctly-framed prefix fresh; (3) decode failure
    /// — resetCacheAndMemory. Q1 (mid-decode cancel) is deferred: once past the
    /// pre-mutation bail this runs every chunk to completion.
    private nonisolated func runPrefill(
        ctx: OpaquePointer,
        request: InferenceRequest,
        epoch: UInt64,
        generationAtFire: UInt64,
        midDecodeCancelEnabled: Bool
    ) {
        // Bail #1 (top): nothing decoded yet, so returning here changes no state.
        if generationId != generationAtFire || epoch != latestPrefillEpoch { return }

        let memory = llama_get_memory(ctx)

        // Whole-section match against cache, prompt order bos…suffixContext.
        // A prefill warms everything up to but NOT including the framed prefix,
        // so there is no per-token prefix-overlap step.
        let orderedSections: [(req: [llama_token], cached: [llama_token])] = [
            (request.bos, cachedBosTokens),
            (request.system, cachedSystemTokens),
            (request.aboutMe, cachedAboutMeTokens),
            (request.clipboard, cachedClipboardTokens),
            (request.messages, cachedMessagesTokens),
            (request.screen, cachedScreenTokens),
            (request.scrollback, cachedScrollbackTokens),
            (request.suffixContext, cachedSuffixContextTokens),
        ]
        var nCached = 0
        for section in orderedSections {
            if section.req == section.cached { nCached += section.req.count }
            else { break }
        }

        // Same drift defence as runInference.
        let memMax = Int(llama_memory_seq_pos_max(memory, 0))
        if nCached > memMax + 1 {
            Log.error("[Cancel][DRIFT] prefill over-claim nCached=\(nCached) memMax=\(memMax) — resetting")
            nCached = 0
        }

        // Assemble bos…suffixContext (NO prefix), truncating to budget.
        var tokens = request.bos + request.system + request.aboutMe + request.clipboard + request.messages + request.screen + request.scrollback + request.suffixContext
        if tokens.count > request.totalBudget {
            tokens = Array(tokens.suffix(request.totalBudget))
            nCached = 0
        }

        let newTokens = Array(tokens.dropFirst(nCached))
        Log.debug("[Prefill] tokens=\(tokens.count) nCached=\(nCached) new=\(newTokens.count)")

        // Cache already covers bos…suffixContext — no-op. Leave the cache (incl.
        // any prefix slot a prior real request warmed) untouched.
        if newTokens.isEmpty { return }

        // Bail #2: re-check immediately before the first KV mutation, to catch a
        // real request / newer prefill that arrived during the match walk.
        if generationId != generationAtFire || epoch != latestPrefillEpoch {
            Log.debug("[Prefill] superseded before decode (discarded \(newTokens.count) new tokens)")
            return
        }

        if nCached > 0 {
            _ = llama_memory_seq_rm(memory, 0, Int32(nCached), -1)
        } else {
            llama_memory_clear(memory, true)
        }

        let batchSize = 512
        var promptTokensProcessed = 0
        var batch = llama_batch_init(Int32(batchSize), 0, 1)
        defer { llama_batch_free(batch) }
        var offset = 0
        while offset < newTokens.count {
            #if DEBUG
            LlamaStressHooks.onPrefillBatch?(offset / batchSize)
            #endif
            // Layer 1b: between-batch bail. Same safety argument as runInference —
            // syncCache the completed batches (request, no heal in prefill) so the
            // cache reflects exactly what KV memory holds.
            if midDecodeCancelEnabled && (generationId != generationAtFire || epoch != latestPrefillEpoch) {
                let synced = nCached + promptTokensProcessed
                syncCache(totalProcessed: synced, request: request, tokens: tokens)
                Log.debug("[Cancel] bail @prefill processed=\(promptTokensProcessed)/\(newTokens.count) synced=\(synced) gen=\(generationAtFire) epoch=\(epoch)")
                #if DEBUG
                LlamaStressHooks.prefillBailCount += 1
                #endif
                return
            }
            batch.n_tokens = 0
            let chunkEnd = min(offset + batchSize, newTokens.count)
            for i in offset..<chunkEnd {
                let idx = Int(batch.n_tokens)
                batch.token[idx] = newTokens[i]
                batch.pos[idx] = llama_pos(nCached + i)
                batch.n_seq_id[idx] = 1
                batch.seq_id[idx]![0] = 0
                batch.logits[idx] = (i == newTokens.count - 1) ? 1 : 0
                batch.n_tokens += 1
            }
            let status = llama_decode(ctx, batch)
            if status != 0 {
                Log.error("[Prefill] decode failed status=\(status) offset=\(offset)")
                resetCacheAndMemory(memory: memory)
                return
            }
            promptTokensProcessed += (chunkEnd - offset)
            offset = chunkEnd
        }

        let totalProcessed = nCached + promptTokensProcessed
        // syncCache with the full request: because totalProcessed stops at
        // suffixContext, `remaining` reaches 0 there and cachedPrefixTokens lands
        // [] — the framed prefix is intentionally excluded from the warm.
        syncCache(totalProcessed: totalProcessed, request: request, tokens: tokens)
        lastPrefillWarmedCount = totalProcessed
        lastPrefillBaseline = nCached
    }

    /// Update the section-cache arrays to reflect actual KV memory state after a
    /// successful decode. Only the portion of each section that fully fits within
    /// `totalProcessed` is kept; later sections are cleared.
    /// Called only from runInference (inferenceQueue) — touches cached* state.
    private nonisolated func syncCache(
        totalProcessed: Int,
        request: InferenceRequest,
        tokens: [llama_token]
    ) {
        // Reset every section cache, then re-fill in prompt order (BOS → system
        // → aboutMe → clipboard → messages → screen → scrollback → suffixContext
        // → prefix), stopping at the first section `totalProcessed` doesn't
        // fully cover. Flat guard chain rather than a pyramid so adding a
        // section is a two-line insert; mirrors the ordered match walk in
        // runInference so the two can't drift.
        cachedBosTokens = []
        cachedSystemTokens = []
        cachedAboutMeTokens = []
        cachedClipboardTokens = []
        cachedMessagesTokens = []
        cachedScreenTokens = []
        cachedScrollbackTokens = []
        cachedSuffixContextTokens = []
        cachedPrefixTokens = []
        cachedTotalCount = max(0, totalProcessed)

        var remaining = totalProcessed
        guard remaining >= request.bos.count else { return }
        cachedBosTokens = request.bos
        remaining -= request.bos.count

        guard remaining >= request.system.count else { return }
        cachedSystemTokens = request.system
        remaining -= request.system.count

        guard remaining >= request.aboutMe.count else { return }
        cachedAboutMeTokens = request.aboutMe
        remaining -= request.aboutMe.count

        guard remaining >= request.clipboard.count else { return }
        cachedClipboardTokens = request.clipboard
        remaining -= request.clipboard.count

        guard remaining >= request.messages.count else { return }
        cachedMessagesTokens = request.messages
        remaining -= request.messages.count

        guard remaining >= request.screen.count else { return }
        cachedScreenTokens = request.screen
        remaining -= request.screen.count

        guard remaining >= request.scrollback.count else { return }
        cachedScrollbackTokens = request.scrollback
        remaining -= request.scrollback.count

        guard remaining >= request.suffixContext.count else { return }
        cachedSuffixContextTokens = request.suffixContext
        remaining -= request.suffixContext.count

        cachedPrefixTokens = Array(request.prefix.prefix(remaining))
    }

    /// Wipe both the section cache and llama.cpp memory. Used after a decode error
    /// where we can't trust the partial state.
    private nonisolated func resetCacheAndMemory(memory: OpaquePointer?) {
        cachedBosTokens = []
        cachedSystemTokens = []
        cachedAboutMeTokens = []
        cachedClipboardTokens = []
        cachedMessagesTokens = []
        cachedScreenTokens = []
        cachedScrollbackTokens = []
        cachedSuffixContextTokens = []
        cachedPrefixTokens = []
        cachedTotalCount = 0
        if let memory = memory { llama_memory_clear(memory, true) }
    }

    /// Scan the vocab once and return token IDs whose text matches either
    /// the `<unused\d+>` pattern or a known dialogue-template control token.
    /// Called on the model thread at load time. Must not retain the vocab
    /// pointer — caller owns it.
    /// Copy a Swift String into the fixed-size `char key[128]` C array of an
    /// `llama_model_kv_override`. Truncates at 127 bytes and null-terminates.
    /// The C tuple-typed key field can't be assigned from a String directly,
    /// so we rebind to a CChar buffer and copy bytes by hand.
    private nonisolated static func writeKvOverrideKey(_ key: String, into override: inout llama_model_kv_override) {
        withUnsafeMutablePointer(to: &override.key) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: 128) { charPtr in
                let bytes = Array(key.utf8)
                let n = min(bytes.count, 127)
                for i in 0..<n { charPtr[i] = CChar(bytes[i]) }
                charPtr[n] = 0
            }
        }
    }

    /// Decode every vocab token to its piece text, returning an array indexed
    /// by token id. The piece text is what `llama_token_to_piece(special: true)`
    /// returns — preserves SentencePiece `▁` (U+2581) leading-space markers,
    /// which is what we want for the healing prefix-match (the user-typed
    /// fragment "mor" matches `▁morning`'s piece, not `morning`'s,
    /// because the tokenizer's whole-word tokens carry the `▁` prefix).
    private nonisolated static func buildVocabPieces(vocab: OpaquePointer) -> [String] {
        let n = Int(llama_vocab_n_tokens(vocab))
        var pieces = [String](repeating: "", count: n)
        var buf = [CChar](repeating: 0, count: 128)
        for id in 0..<Int32(n) {
            let len = llama_token_to_piece(vocab, id, &buf, Int32(buf.count), 0, true)
            guard len > 0 else { continue }
            pieces[Int(id)] = String(bytes: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        }
        return pieces
    }

    // MARK: - Token healing
    //
    // SentencePiece-style BPE tokenizers encode whole common words as
    // single high-probability tokens (`▁morning`, `▁looking`).
    // When the user is mid-typing ("mor", "loo"), greedy tokenization
    // produces fragment tokens (`▁mor`, `▁loo`) that the model has never
    // been trained to predict the rest of — those characters were always
    // swallowed by the longer whole-word token at training time. Result:
    // empty output (model emits EOS because `▁loo` is itself a valid word)
    // or wrong continuation (`mor` + `ing` = "moring", missing the `n`).
    //
    // Token healing fixes this by **dropping the last prompt token before
    // sampling** and constraining the first sampled token to one whose
    // piece text starts with the dropped token's piece. So instead of
    // sampling "after ▁mor", the model samples "instead of ▁mor" from
    // {▁mor, ▁more, ▁morning, ▁moral, ▁mortal, ...} — letting the wider
    // training-distribution prior pick `▁morning` if context favours it.
    //
    // Design follows Microsoft Guidance v0.0.64 + Sweep AI's blog post:
    //   - Single-token backtrack (the simplest case; multi-token would
    //     cover deeper BPE splits like `swim`+`m`).
    //   - Hard `-INFINITY` mask on disallowed tokens (Sweep's approach).
    //   - Original token always kept in the allowed set (Guidance's
    //     "favor original" safeguard) so `extensions.count >= 1` always.

    /// Returns true if the given piece text looks like a partial word the
    /// user is mid-typing. False for whitespace, punctuation, special
    /// tokens, and complete-word boundaries that don't need healing.
    private nonisolated func isHealablePiece(_ piece: String) -> Bool {
        guard let last = piece.last else { return false }
        // Word-character endings: a–z, A–Z, 0–9, plus letters from any
        // script (handles CJK / accented chars). Excludes whitespace,
        // punctuation, control chars, and any specialish text like `<eos>`.
        return last.isLetter || last.isNumber
    }

    /// All token IDs whose piece text starts with `prefix`. Linear scan of
    /// the vocab piece array — ~1ms for 256K entries on Apple Silicon. The
    /// caller-supplied `original` is always included so the allowed set is
    /// non-empty (Guidance "favor original" safeguard). The returned set
    /// includes `original` exactly once even if its piece matches the
    /// prefix naturally.
    private nonisolated func extensionsOf(prefix: String, original: llama_token) -> [llama_token] {
        guard !prefix.isEmpty else { return [original] }
        var out: [llama_token] = []
        out.reserveCapacity(64)
        let n = Int32(vocabPieces.count)
        for id in 0..<n {
            if vocabPieces[Int(id)].hasPrefix(prefix) {
                out.append(id)
            }
        }
        if !out.contains(original) {
            out.append(original)
        }
        return out
    }

    /// Build a transient sampler chain that strongly biases toward tokens
    /// in `allowed`, then samples greedily. Used for the healing step.
    /// Caller must `llama_sampler_free` the returned chain.
    ///
    /// Mechanism: positive +100 bias on every allowed token. The model's
    /// `final_logit_softcapping=30` caps any unbiased logit at ±30, so
    /// any allowed token's post-bias logit (≥ −30 + 100 = 70) dominates
    /// any disallowed token's logit (≤ +30) by ≥ 40 — greedy always picks
    /// from the allowed set.
    ///
    /// Equivalent to "mask all disallowed at −∞" mathematically, but
    /// builds a bias array of size `allowed.count` (~5–200) instead of
    /// `nVocab − allowed.count` (~256K). Saves the 256K iteration and
    /// ~2 MB allocation per healed request — the same trick Microsoft
    /// Guidance v0.0.64 uses with its +100 bias.
    private nonisolated func makeHealChain(allowed: [llama_token], nVocab: Int32) -> UnsafeMutablePointer<llama_sampler>? {
        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else { return nil }

        let biases: [llama_logit_bias] = allowed.map {
            llama_logit_bias(token: $0, bias: 100)
        }
        biases.withUnsafeBufferPointer { buf in
            if let s = llama_sampler_init_logit_bias(nVocab, Int32(biases.count), buf.baseAddress) {
                llama_sampler_chain_add(chain, s)
            }
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        return chain
    }

    private nonisolated static func buildBannedTokenSet(vocab: OpaquePointer) -> Set<llama_token> {
        let n = llama_vocab_n_tokens(vocab)
        var banned = Set<llama_token>()

        // Exact-match set covers documented dialogue / multimodal /
        // reasoning / tool tokens plus legacy markers that are still
        // present in some vocabularies.
        let bannedExact: Set<String> = [
            "<|turn>", "<turn|>",
            "<|channel>", "<channel|>",
            "<|think|>",
            "<|tool>", "<|tool_call>", "<|tool_response>",
            "<|image>", "<image|>",
            "<|audio>", "<audio|>",
            "<start_of_turn>", "<end_of_turn>",
        ]

        var buf = [CChar](repeating: 0, count: 128)
        for id in 0..<n {
            let len = llama_token_to_piece(vocab, id, &buf, Int32(buf.count), 0, true)
            guard len > 0 else { continue }
            let text = String(bytes: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            if bannedExact.contains(text) {
                banned.insert(id)
                continue
            }
            // <unused0>..<unused99+> — any token whose text starts with
            // "<unused" and ends with ">" with a digit body.
            if text.hasPrefix("<unused") && text.hasSuffix(">") {
                let mid = text.dropFirst(7).dropLast(1)
                if !mid.isEmpty && mid.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    banned.insert(id)
                }
            }
        }
        return banned
    }

    func cancel() {
        // Supersede any in-flight decode now (don't wait for the next complete()).
        // runInference / runPrefill bail at their next check point — between
        // batches (Layer 1) and between generated tokens — and syncCache any
        // partial decode. Only invoked when the rollout flag is on (see
        // Engine.cancelCurrentRequest), so flag-off behavior is unchanged.
        generationId += 1
    }

    #if DEBUG
    // MARK: - Mid-decode-cancel stress hooks (DEBUG only; compiled out of release)
    // Drive deterministic supersession + cold-cache resets for MidDecodeCancelStress.
    nonisolated func stressBumpGeneration() { generationId += 1 }
    nonisolated func stressBumpPrefillEpoch() { latestPrefillEpoch &+= 1 }

    /// Force a cold cache (section arrays + llama memory) and replay the sampler
    /// RNG from its seed. Runs on the inference queue like `unloadModel`.
    func stressClearCacheAndResetSampler() {
        guard let ctx = ctx else { return }
        let ctxPtr = SendablePointer(ctx)
        inferenceQueue.sync { [weak self] in
            guard let self = self else { return }
            self.resetCacheAndMemory(memory: llama_get_memory(ctxPtr.pointer))
            if let sampler = self.sampler { llama_sampler_reset(sampler) }
        }
    }

    /// Replay the sampler RNG without touching the cache (used before the recover
    /// completion, which must reuse the partial cache left by a bail).
    func stressResetSamplerOnly() {
        inferenceQueue.sync { [weak self] in
            if let sampler = self?.sampler { llama_sampler_reset(sampler) }
        }
    }

    var stressCachedTotalCount: Int { cachedTotalCount }
    #endif

    func unloadModel() {
        let ctxToFree: OpaquePointer? = ctx
        let modelToFree: OpaquePointer? = model
        ctx = nil
        model = nil
        isModelLoaded = false
        generationId += 1

        // Free on the inference queue so any in-flight work finishes first, and clear
        // cache state there too (it's owned by the queue). Use .sync so callers (notably
        // applicationWillTerminate) actually wait for llama_free/llama_model_free to
        // complete before continuing to exit — otherwise C++ static destructors race
        // with our pending free block.
        let ctxPtr = ctxToFree.map { SendablePointer($0) }
        let modelPtr = modelToFree.map { SendablePointer($0) }
        inferenceQueue.sync { [weak self] in
            self?.cachedBosTokens = []
            self?.cachedSystemTokens = []
            self?.cachedAboutMeTokens = []
            self?.cachedClipboardTokens = []
            self?.cachedMessagesTokens = []
            self?.cachedScreenTokens = []
            self?.cachedScrollbackTokens = []
            self?.cachedSuffixContextTokens = []
            self?.cachedPrefixTokens = []
            self?.cachedTotalCount = 0
            self?.vocabPieces = []
            // Free the sampler chain (also frees every sampler added to it
            // via llama_sampler_chain_add — no need to walk and free each).
            if let samplerToFree = self?.sampler {
                llama_sampler_free(samplerToFree)
                self?.sampler = nil
            }
            if let ctxPtr = ctxPtr { llama_free(ctxPtr.pointer) }
            if let modelPtr = modelPtr { llama_model_free(modelPtr.pointer) }
            Log.info("llama.cpp model unloaded")
        }
    }
}

private struct SendablePointer: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// A snapshot of everything `runInference` needs to execute one request.
/// All value types; trivially Sendable across actor boundaries.
private struct InferenceRequest: Sendable {
    let bos: [llama_token]
    let system: [llama_token]
    let aboutMe: [llama_token]
    let clipboard: [llama_token]
    let messages: [llama_token]
    let screen: [llama_token]
    let scrollback: [llama_token]
    let suffixContext: [llama_token]
    let prefix: [llama_token]
    let totalBudget: Int
    let maxTokens: Int
    let generationId: UInt64
    /// Did the user's literal typed text end with whitespace before we
    /// stripped it for tokenization? Lets the healing output cleanup tell
    /// "user typed at a real word boundary" (real space → don't strip BPE
    /// leading-space marker, let Engine.trimOverlap match it as a literal
    /// char) from "user typed at start-of-doc / post-newline boundary"
    /// (no real space → strip the BPE artifact so trimOverlap finds the
    /// word overlap).
    let prefixHadTrailingWhitespace: Bool
}

enum LlamaError: Error, LocalizedError {
    case modelLoadFailed
    case contextCreationFailed
    case modelNotLoaded
    case tokenizationFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load llama.cpp model"
        case .contextCreationFailed: return "Failed to create llama.cpp context"
        case .modelNotLoaded: return "Model not loaded"
        case .tokenizationFailed: return "Failed to tokenize input"
        case .decodeFailed: return "llama.cpp decode failed"
        }
    }
}
