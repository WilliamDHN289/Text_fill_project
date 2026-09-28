#if DEBUG
import Foundation

/// DEBUG-only test hooks for the mid-decode-cancel stress harness. Compiled out
/// of release builds entirely (the whole file is `#if DEBUG`).
///
/// `runInference` / `runPrefill` invoke `onPromptBatch` / `onPrefillBatch` at the
/// top of each prompt-decode batch (passing the 0-based batch index about to be
/// processed) so the harness can supersede the in-flight decode at a chosen
/// boundary. The bail counters let the harness confirm a bail actually fired
/// rather than the decode finishing first.
enum LlamaStressHooks {
    nonisolated(unsafe) static var onPromptBatch: ((Int) -> Void)?
    nonisolated(unsafe) static var onPrefillBatch: ((Int) -> Void)?
    nonisolated(unsafe) static var promptBailCount = 0
    nonisolated(unsafe) static var prefillBailCount = 0
}

/// Deterministically triggers Q1 mid-decode cancellation and verifies the
/// partial-decode cache recovers correctly.
///
/// Oracle: a bail-then-reuse completion must produce byte-identical output to a
/// cold completion of the same prompt. Sampling is temp=0.2 + fixed-seed `dist`
/// (LlamaProvider.swift), so it is NOT greedy — but resetting the sampler before
/// each oracle completion replays the same RNG, so identical KV ⇒ identical
/// tokens. A mismatch therefore means the reused KV differs from a clean decode,
/// i.e. the partial-cache bookkeeping (syncCache) corrupted state.
///
/// Triggered at launch by `defaults write Autocomplete autocomplete.stressMidDecodeCancel -bool true`.
@MainActor
final class MidDecodeCancelStress {
    private let provider: LlamaProvider
    init(provider: LlamaProvider) { self.provider = provider }

    func run() async {
        Log.info("[Stress] === mid-decode-cancel stress start ===")
        var pass = 0, fail = 0

        // Prompt-decode (runInference) path — bail mid-prefix at points 1..5.
        // This is the user-visible completion path and the one that records a
        // PARTIAL prefix section, so it is the highest-value case.
        for k in 1...5 {
            let prefix = Self.longText(tokensApprox: (k + 1) * 600, salt: "prompt-\(k)")
            (await runPromptCase(prefix: prefix, bailBatch: k)) ? (pass += 1) : (fail += 1)
        }

        // Prefill (runPrefill) path — bail mid-screen at points 1..3. Screen is a
        // whole-or-nothing section, so a mid-screen bail drops it entirely; the
        // recover must re-decode screen and still match cold output.
        for k in 1...3 {
            let screen = Self.longText(tokensApprox: (k + 1) * 600, salt: "prefill-\(k)")
            (await runPrefillCase(screen: screen, bailBatch: k)) ? (pass += 1) : (fail += 1)
        }

        Log.info("[Stress] === done: \(pass) PASS, \(fail) FAIL ===")
    }

    // MARK: - Prompt-decode path

    private func runPromptCase(prefix: String, bailBatch k: Int) async -> Bool {
        // 1) Cold baseline — ground truth, computed from scratch.
        provider.stressClearCacheAndResetSampler()
        let clean = (try? await runComplete(prefix: prefix)) ?? "<err>"

        // 2) Stress — bump generationId at batch k so the next check bails.
        provider.stressClearCacheAndResetSampler()
        LlamaStressHooks.promptBailCount = 0
        LlamaStressHooks.onPromptBatch = { [weak provider] idx in
            if idx == k { provider?.stressBumpGeneration() }
        }
        _ = try? await runComplete(prefix: prefix)
        LlamaStressHooks.onPromptBatch = nil
        let bailed = LlamaStressHooks.promptBailCount
        let synced = provider.stressCachedTotalCount

        // 3) Recover — reuse the partial cache the bail left (NO clear).
        provider.stressResetSamplerOnly()
        let recover = (try? await runComplete(prefix: prefix)) ?? "<err>"

        let match = !clean.isEmpty && clean == recover
        let ok = match && bailed == 1
        Log.info("[Stress] prompt k=\(k) bail=\(bailed) match=\(match) syncedAfterBail=\(synced) clean=\"\(Self.trunc(clean))\" recover=\"\(Self.trunc(recover))\" -> \(ok ? "PASS" : "FAIL")")
        return ok
    }

    private func runComplete(prefix: String) async throws -> String {
        try await provider.complete(
            prefix: prefix,
            suffixKind: .plain,
            maxTokens: 16,
            midDecodeCancelEnabled: true
        )
    }

    // MARK: - Prefill path

    private func runPrefillCase(screen: String, bailBatch k: Int) async -> Bool {
        let prefix = "The "  // tiny prefix; prefill warms bos…screen (never prefix)

        // 1) Cold baseline.
        provider.stressClearCacheAndResetSampler()
        let clean = (try? await runComplete(prefix: prefix, screen: screen)) ?? "<err>"

        // 2) Stress prefill — bump the prefill epoch at batch k to bail mid-warm.
        provider.stressClearCacheAndResetSampler()
        LlamaStressHooks.prefillBailCount = 0
        LlamaStressHooks.onPrefillBatch = { [weak provider] idx in
            if idx == k { provider?.stressBumpPrefillEpoch() }
        }
        await provider.prefill(
            prefix: prefix,
            suffixKind: .plain,
            screenContext: screen,
            midDecodeCancelEnabled: true
        )
        LlamaStressHooks.onPrefillBatch = nil
        let bailed = LlamaStressHooks.prefillBailCount
        let synced = provider.stressCachedTotalCount

        // 3) Recover — a real completion reuses whatever the partial warm left.
        provider.stressResetSamplerOnly()
        let recover = (try? await runComplete(prefix: prefix, screen: screen)) ?? "<err>"

        let match = !clean.isEmpty && clean == recover
        let ok = match && bailed == 1
        Log.info("[Stress] prefill k=\(k) bail=\(bailed) match=\(match) syncedAfterBail=\(synced) -> \(ok ? "PASS" : "FAIL")")
        return ok
    }

    private func runComplete(prefix: String, screen: String) async throws -> String {
        try await provider.complete(
            prefix: prefix,
            suffixKind: .plain,
            screenContext: screen,
            maxTokens: 16,
            midDecodeCancelEnabled: true
        )
    }

    // MARK: - Synthetic prompts

    /// Build a unique, long block of generic English (~`tokensApprox` tokens at
    /// ~4 chars/token). Unique per `salt` so iterations don't share cache and the
    /// baseline of one isn't the warm of the next.
    private static func longText(tokensApprox: Int, salt: String) -> String {
        let words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
                     "and", "then", "writes", "some", "notes", "while", "thinking",
                     "about", "tokens", "context", "window", "buffer", "vector",
                     "sample", "decode", "batch", "prompt", "system", "memory"]
        var s = "stress \(salt): "
        let target = tokensApprox * 4
        var i = 0
        while s.count < target {
            s += words[i % words.count] + " "
            i += 1
            if i % 12 == 0 { s += "\(salt)\(i) " }  // sprinkle uniqueness
        }
        return s
    }

    private static func trunc(_ s: String) -> String {
        s.count <= 24 ? s : String(s.prefix(24)) + "…"
    }
}
#endif
