import Foundation

/// A consolidated multi-token habit (phrase / template) promoted by the cold
/// path when its *decayed* count and PMI both clear thresholds — i.e. the
/// phrase recurs across time (consolidation), not just within one burst.
public struct Habit: Codable, Sendable {
    public let phrase: [String]
    public let strength: Double   // consolidated (decayed) frequency
    public let pmi: Double        // collocation cohesion

    public init(phrase: [String], strength: Double, pmi: Double) {
        self.phrase = phrase
        self.strength = strength
        self.pmi = pmi
    }
}

/// Long-term, human-auditable habit store.
///
/// Hot-path access is `candidates(after:)` — a single dictionary get keyed by
/// the habit's first (anchor) token → O(1) candidate fetch.
public final class HabitLexicon: @unchecked Sendable {

    private var habits: [String: Habit] = [:]          // key: joined phrase
    private var byAnchor: [String: [Habit]] = [:]      // key: first token
    private let lock = NSLock()

    public init() {}

    private static func key(_ phrase: [String]) -> String {
        phrase.joined(separator: DecayedNGramTrie.ctxSeparator)
    }

    /// Insert or refresh a habit. Anchor list keeps the strongest habits first.
    public func promote(_ habit: Habit) {
        guard let anchor = habit.phrase.first else { return }
        lock.lock()
        defer { lock.unlock() }
        let k = Self.key(habit.phrase)
        let isNew = habits[k] == nil
        habits[k] = habit
        if isNew {
            byAnchor[anchor, default: []].append(habit)
        } else if let idx = byAnchor[anchor]?.firstIndex(where: { $0.phrase == habit.phrase }) {
            byAnchor[anchor]?[idx] = habit
        }
        byAnchor[anchor]?.sort { $0.strength > $1.strength }
    }

    /// Habits anchored on `lastToken` (strongest first).
    public func candidates(after lastToken: String, maxCount: Int = 5) -> [Habit] {
        lock.lock()
        defer { lock.unlock() }
        guard let list = byAnchor[lastToken] else { return [] }
        return Array(list.prefix(maxCount))
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return habits.count
    }

    // MARK: - Persistence

    public func snapshot() -> [Habit] {
        lock.lock()
        defer { lock.unlock() }
        return Array(habits.values)
    }

    public func restore(_ list: [Habit]) {
        lock.lock()
        habits.removeAll()
        byAnchor.removeAll()
        lock.unlock()
        for h in list { promote(h) }
    }
}
