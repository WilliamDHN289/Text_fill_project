import Foundation

/// The entire write / "memory formation" pipeline — DPHM's cold path.
///
/// Consumes committed text on a background serial queue and:
///   1. updates the long-term trie (slow decay)              — observation
///   2. mines collocations by decayed count × PMI and
///      promotes them into the `HabitLexicon`                — consolidation
///   3. periodically prunes decayed-out entries              — forgetting
///   4. schedules a debounced persistence snapshot           — durability
///
/// Everything here can be arbitrarily slow without hurting typing latency:
/// the hot path never waits on this queue.
final class DPHMConsolidator: @unchecked Sendable {

    private let longTrie: DecayedNGramTrie
    private let lexicon: HabitLexicon
    private let config: DPHMConfig
    /// Called (on the consolidator queue) when a snapshot should be written.
    private let persist: @Sendable () -> Void

    private let queue = DispatchQueue(label: "dphm.consolidator", qos: .utility)
    private var lastPruneAt: Double = 0
    private var lastSaveAt: Double = 0
    private var saveScheduled = false

    init(longTrie: DecayedNGramTrie, lexicon: HabitLexicon, config: DPHMConfig,
         persist: @escaping @Sendable () -> Void) {
        self.longTrie = longTrie
        self.lexicon = lexicon
        self.config = config
        self.persist = persist
    }

    /// Enqueue committed text. Returns immediately (cheap).
    func submit(text: String, weight: Double, now: Double? = nil) {
        let now = now ?? Date().timeIntervalSince1970
        queue.async { [self] in
            consolidate(text: text, weight: weight, now: now)
        }
    }

    /// Test hook: block until all submitted work has been processed.
    func flush() {
        queue.sync {}
    }

    // MARK: - Pipeline (runs on `queue`)

    private func consolidate(text: String, weight: Double, now: Double) {
        let tokens = DPHMTokenizer.tokenize(text)
        guard !tokens.isEmpty else { return }
        longTrie.observe(tokens, weight: weight, now: now)
        mineAndPromote(tokens: tokens, now: now)

        if now - lastPruneAt >= config.pruneIntervalSeconds {
            lastPruneAt = now
            longTrie.prune(floor: config.pruneFloor, now: now)
        }
        scheduleSave(now: now)
    }

    /// Promote bigrams/trigrams whose *decayed* joint count and PMI are both
    /// high: recurrence over time (not burstiness) defines a habit.
    private func mineAndPromote(tokens: [String], now: Double) {
        let total = longTrie.unigramTotal(now: now)
        guard total > 1.0 else { return }

        func uniP(_ tok: String) -> Double {
            max(longTrie.unigramCount(tok, now: now), 1e-9) / total
        }

        for n in 2...3 {
            guard tokens.count >= n else { continue }
            for i in 0...(tokens.count - n) {
                let phrase = Array(tokens[i..<(i + n)])
                let ctxKey = phrase.dropLast().joined(separator: DecayedNGramTrie.ctxSeparator)
                let joint = longTrie.decayedCount(context: ctxKey, next: phrase[n - 1], now: now)
                guard joint >= config.promoteMinCount else { continue }
                let pJoint = joint / total
                var pIndep = 1.0
                for t in phrase { pIndep *= uniP(t) }
                let pmi = log(pJoint / max(pIndep, 1e-12)) / Double(n - 1)
                if pmi >= config.promoteMinPMI {
                    lexicon.promote(Habit(phrase: phrase, strength: joint, pmi: pmi))
                }
            }
        }
    }

    /// Debounced snapshot: at most one write per `saveIntervalSeconds`.
    private func scheduleSave(now: Double) {
        guard config.persistenceEnabled, !saveScheduled else { return }
        let wait = max(0, config.saveIntervalSeconds - (now - lastSaveAt))
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + wait) { [self] in
            saveScheduled = false
            lastSaveAt = Date().timeIntervalSince1970
            persist()
        }
    }
}
