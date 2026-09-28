import Foundation

/// DPHM: Dual-Path Habit Memory — a low-latency memory layer for real-time
/// text completion. Swift port of `3_dphm/dphm.py`, embedded in FlowIn.
///
/// Design principles:
///  1. **Hot path / cold path decoupling.** `suggest(bufferText:)` runs per
///     keystroke and only touches O(1) hash lookups — no embeddings, no ANN,
///     no LLM. Target p99 < 5 ms (measured µs in practice). Everything
///     expensive (consolidation, collocation mining, persistence) happens on
///     background queues and is *compiled* into hot-path data structures.
///  2. **Habit = decayed personal n-gram cache + shallow fusion.** Long-term
///     trie (slow decay) + session cache (fast decay), scored with Stupid
///     Backoff and fused: `score = λ_long·s_long + λ_sess·s_sess + β·boost`.
///     (Cache LM, Kuhn & De Mori 1990; Neural Cache, arXiv:1612.04426;
///     kNN-LM, arXiv:1911.00172; shallow fusion, arXiv:1503.03535.)
///  3. **Speculative prefetch.** Retrieval fires on word boundaries
///     (debounced, async), never on keystrokes; the hot path only reads the
///     published boost buffer.
public final class DPHMMemory: @unchecked Sendable {

    public struct HabitSuggestion: Sendable {
        /// Ready-to-insert continuation text (lowercase; excludes what the
        /// user already typed).
        public let text: String
        public let score: Double
        /// "habit" (lexicon phrase) | "ngram" (greedy trie walk)
        public let source: String
    }

    public struct Stats: Sendable {
        public let longTrieEntries: Int
        public let habitCount: Int
        public let commitCount: Int
    }

    /// Process-wide instance used by the app (config from `dphm.yaml`).
    public static let shared = DPHMMemory(config: DPHMConfig.load())

    public let config: DPHMConfig

    let longTrie: DecayedNGramTrie
    let sessionTrie: DecayedNGramTrie
    let lexicon: HabitLexicon
    let prefetchBuffer = PrefetchBuffer()
    private var prefetcher: SpeculativePrefetcher?
    private var consolidator: DPHMConsolidator!

    private let storeURL: URL
    private let ioQueue = DispatchQueue(label: "dphm.io", qos: .utility)

    /// Ring buffer of recent tokenized commits, mined by the default lexical
    /// prefetch retriever. Swap in an embedding/ANN retriever by replacing
    /// the closure passed to `SpeculativePrefetcher` — the hot path only ever
    /// reads `prefetchBuffer`.
    private var recentCommits: [[String]] = []
    private var commitCounter = 0
    private let stateLock = NSLock()

    public init(config: DPHMConfig, storeURL: URL? = nil, loadPersisted: Bool = true) {
        self.config = config
        self.longTrie = DecayedNGramTrie(order: config.longOrder,
                                         halfLifeSeconds: config.longHalfLifeDays * 86_400)
        self.sessionTrie = DecayedNGramTrie(order: config.sessionOrder,
                                            halfLifeSeconds: config.sessionHalfLifeMinutes * 60)
        self.lexicon = HabitLexicon()
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first!
            self.storeURL = appSupport.appendingPathComponent("Autocomplete/dphm_store.json")
        }

        self.consolidator = DPHMConsolidator(longTrie: longTrie, lexicon: lexicon,
                                             config: config) { [weak self] in
            self?.writeSnapshot()
        }
        if config.prefetchEnabled {
            self.prefetcher = SpeculativePrefetcher(
                buffer: prefetchBuffer,
                debounceInterval: config.prefetchDebounceMs / 1000.0
            ) { [weak self] contextText in
                self?.lexicalRetrieve(contextText: contextText) ?? [:]
            }
        }
        if loadPersisted && config.persistenceEnabled {
            ioQueue.async { [weak self] in self?.readSnapshot() }
        }
    }

    // MARK: - Integration events (cheap; called from the UI thread)

    /// Call when the user completes a word (space / punctuation). Feeds the
    /// fast-decay session cache inline (µs) and pokes the async prefetcher.
    public func onWordBoundary(bufferText: String) {
        guard config.enabled else { return }
        let tail = String(bufferText.suffix(config.contextTailChars))
        let tokens = DPHMTokenizer.tokenize(tail)
        guard !tokens.isEmpty else { return }
        sessionTrie.observe(Array(tokens.suffix(8)))
        prefetcher?.notify(contextText: tail)
    }

    /// User sent/submitted their own text — the strongest habit signal.
    public func commitSentMessage(_ text: String) {
        commit(text, weight: config.weightSentMessage)
    }

    /// User accepted AI-suggested text — endorsed, weaker habit signal.
    public func commitAcceptedSuggestion(_ text: String) {
        commit(text, weight: config.weightAcceptedSuggestion)
    }

    private func commit(_ text: String, weight: Double) {
        guard config.enabled, weight > 0,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        consolidator.submit(text: text, weight: weight)
        let tokens = DPHMTokenizer.tokenize(String(text.suffix(600)))
        stateLock.lock()
        commitCounter += 1
        recentCommits.append(tokens)
        if recentCommits.count > config.prefetchRecentCommits {
            recentCommits.removeFirst(recentCommits.count - config.prefetchRecentCommits)
        }
        stateLock.unlock()
    }

    // MARK: - Hot path (per keystroke; dict lookups only)

    /// Instant habit suggestion for the current buffer. Returns nil when no
    /// stored habit clears the display threshold.
    public func suggest(bufferText: String) -> HabitSuggestion? {
        guard config.enabled else { return nil }
        let now = Date().timeIntervalSince1970
        let tail = String(bufferText.suffix(config.contextTailChars))
        let atBoundary = tail.isEmpty || tail.last!.isWhitespace || tail.last!.isNewline
        var tokens = DPHMTokenizer.tokenize(tail)

        let typedPrefix: String
        if atBoundary || tokens.isEmpty {
            typedPrefix = ""
        } else {
            typedPrefix = tokens.removeLast()
        }
        let context = Array(tokens.suffix(4))

        // 1) Habit-lexicon phrase anchored on the last committed token —
        //    highest-precision path (phrase recurred over time with high PMI).
        if let anchor = context.last {
            var best: (rest: [String], score: Double)?
            for h in lexicon.candidates(after: anchor, maxCount: config.maxPhraseCandidates) {
                let rest = Array(h.phrase.dropFirst())
                guard !rest.isEmpty else { continue }
                if !typedPrefix.isEmpty && !rest[0].hasPrefix(typedPrefix) { continue }
                let s = 0.3 * log1p(h.strength) + 0.2 * h.pmi
                if best == nil || s > best!.score { best = (rest, s) }
            }
            if let best {
                let text = renderContinuation(tokens: best.rest, typedPrefix: typedPrefix)
                if !text.isEmpty {
                    return HabitSuggestion(text: text, score: best.score, source: "habit")
                }
            }
        }

        // 2) Greedy n-gram walk under shallow fusion.
        guard let first = fusedBest(context: context, typedPrefix: typedPrefix, now: now),
              first.score >= config.minDisplayScore else { return nil }

        var collected = [first.token]
        var walkContext = context + [first.token]
        var wordBudget = config.maxSuggestionWords - 1
        while wordBudget > 0 {
            guard let next = fusedBest(context: Array(walkContext.suffix(4)), typedPrefix: "", now: now),
                  next.score >= config.minContinueScore,
                  !Self.sentenceTerminators.contains(next.token),
                  next.token != collected.last else { break }  // repetition guard
            collected.append(next.token)
            walkContext.append(next.token)
            if DPHMTokenizer.isWordToken(next.token) || DPHMTokenizer.isCJKToken(next.token) {
                wordBudget -= 1
            }
        }

        let text = renderContinuation(tokens: collected, typedPrefix: typedPrefix)
        guard !text.isEmpty else { return nil }
        return HabitSuggestion(text: text, score: first.score, source: "ngram")
    }

    private static let sentenceTerminators: Set<String> = [".", "!", "?", "。", "！", "？", "\n"]

    /// Best next token under shallow fusion. Missing sources are excluded
    /// from a weighted average (rather than floored) so the result stays on a
    /// log-prob scale and can be compared against absolute display gates.
    private func fusedBest(context: [String], typedPrefix: String,
                           now: Double) -> (token: String, score: Double)? {
        var perToken: [String: (num: Double, den: Double)] = [:]
        for (tok, lp) in longTrie.topContinuations(context: context, k: config.topK,
                                                   prefix: typedPrefix, now: now) {
            let slot = perToken[tok] ?? (0, 0)
            perToken[tok] = (slot.num + config.lambdaLong * lp, slot.den + config.lambdaLong)
        }
        for (tok, lp) in sessionTrie.topContinuations(context: context, k: config.topK,
                                                      prefix: typedPrefix, now: now) {
            let slot = perToken[tok] ?? (0, 0)
            perToken[tok] = (slot.num + config.lambdaSession * lp, slot.den + config.lambdaSession)
        }
        var best: (token: String, score: Double)?
        for (tok, slot) in perToken {
            var s = slot.num / slot.den
            s += config.betaPrefetch * prefetchBuffer.boost(tok)
            if best == nil || s > best!.score { best = (tok, s) }
        }
        return best
    }

    /// Assemble display text from continuation tokens, dropping the chars the
    /// user already typed (mid-word completion).
    private func renderContinuation(tokens: [String], typedPrefix: String) -> String {
        guard !tokens.isEmpty else { return "" }
        let display = DPHMTokenizer.detokenize(tokens)
        if typedPrefix.isEmpty { return display }
        guard display.count > typedPrefix.count else { return "" }
        return String(display.dropFirst(typedPrefix.count))
    }

    // MARK: - Candidate re-ranking (shallow fusion at the candidate level)

    /// Re-order LLM candidates by personal-habit affinity. The first element
    /// only changes when a challenger beats it by `rerankMargin` (log-space) —
    /// conservative, since the LLM's own ordering encodes intent.
    public func rankCandidates(_ candidates: [String], bufferText: String) -> [String] {
        guard config.enabled, candidates.count > 1 else { return candidates }
        let now = Date().timeIntervalSince1970
        let tail = String(bufferText.suffix(config.contextTailChars))
        let contextTokens = DPHMTokenizer.tokenize(tail)

        func habitScore(_ candidate: String) -> Double {
            let candTokens = DPHMTokenizer.tokenize(candidate).prefix(6)
            guard !candTokens.isEmpty else { return DecayedNGramTrie.floorLogScore }
            var ctx = Array(contextTokens.suffix(4))
            var total = 0.0
            for tok in candTokens {
                let sLong = longTrie.score(context: ctx, candidate: tok, now: now)
                let sSess = sessionTrie.score(context: ctx, candidate: tok, now: now)
                total += max(sLong, sSess)
                ctx.append(tok)
                if ctx.count > 4 { ctx.removeFirst() }
            }
            return total / Double(candTokens.count)
        }

        let scored = candidates.enumerated().map { (idx: $0.offset, text: $0.element, s: habitScore($0.element)) }
        guard let challenger = scored.dropFirst().max(by: { $0.s < $1.s }),
              challenger.s - scored[0].s >= config.rerankMargin else { return candidates }
        var result = candidates
        result.remove(at: challenger.idx)
        result.insert(challenger.text, at: 0)
        return result
    }

    // MARK: - Default lexical prefetch retriever (runs on the prefetch queue)

    /// Cheap semantic proxy: boost tokens from recent commits that share a
    /// content word with the current context. Replaceable by embedding+ANN —
    /// nothing on the hot path would change.
    private func lexicalRetrieve(contextText: String) -> [String: Double] {
        let ctxWords = Set(DPHMTokenizer.tokenize(String(contextText.suffix(120)))
            .filter { DPHMTokenizer.isWordToken($0) && $0.count >= 3 })
        guard !ctxWords.isEmpty else { return [:] }
        stateLock.lock()
        let commits = recentCommits
        stateLock.unlock()
        var boosts: [String: Double] = [:]
        for commitTokens in commits {
            guard commitTokens.contains(where: { ctxWords.contains($0) }) else { continue }
            for tok in commitTokens where DPHMTokenizer.isWordToken(tok) {
                boosts[tok] = min((boosts[tok] ?? 0) + config.prefetchBoostUnit,
                                  3 * config.prefetchBoostUnit)
            }
            if boosts.count > 512 { break }
        }
        return boosts
    }

    // MARK: - Persistence

    private struct Store: Codable, Sendable {
        var version: Int
        var savedAt: Double
        var long: [DecayedNGramTrie.SnapshotEntry]
        var habits: [Habit]
    }

    private func writeSnapshot() {
        longTrie.prune(floor: config.pruneFloor)
        let store = Store(version: 1, savedAt: Date().timeIntervalSince1970,
                          long: longTrie.snapshot(), habits: lexicon.snapshot())
        ioQueue.async { [storeURL] in
            do {
                try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(store)
                try data.write(to: storeURL, options: .atomic)
            } catch {
                // Persistence failures must never surface on the typing path.
            }
        }
    }

    private func readSnapshot() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        longTrie.restore(store.long)
        lexicon.restore(store.habits)
    }

    /// Force a synchronous snapshot write (app quit / tests).
    public func saveNow() {
        guard config.persistenceEnabled else { return }
        writeSnapshot()
        ioQueue.sync {}
    }

    /// Test hook: block until all pending consolidation work has landed.
    public func flushConsolidation() {
        consolidator.flush()
    }

    /// Test hook: wait for any debounced prefetch to publish.
    public func flushPrefetch() {
        prefetcher?.flush()
    }

    public var stats: Stats {
        stateLock.lock()
        let commits = commitCounter
        stateLock.unlock()
        return Stats(longTrieEntries: longTrie.entryCount,
                     habitCount: lexicon.count,
                     commitCount: commits)
    }
}
