import Foundation

/// Personal n-gram model with exponential time decay and Stupid Backoff.
///
/// - `halfLifeSeconds` controls forgetting: a pattern must *recur* to keep a
///   high effective count, so the surviving mass encodes long-term habits
///   (discrete Ebbinghaus consolidation — MemoryBank, arXiv:2305.10250).
/// - Scoring is Stupid Backoff (Brants et al. 2007): unnormalized, fast.
/// - Lookup is a chain of dictionary gets: O(order) per query, microseconds.
/// - Counters decay lazily: `value(t) = value · γ^(t − stamp)`; writes are
///   O(1), decay is only materialized on read.
///
/// Thread-safety: a single `NSLock` guards all state. Hot-path reads hold it
/// for a handful of dictionary lookups (sub-µs uncontended); the cold path
/// (observe/prune) holds it per batch. Under DPHM's design the write rate is
/// low (word boundaries + commits), so contention is negligible.
public final class DecayedNGramTrie: @unchecked Sendable {

    struct DecayedCount {
        var value: Double = 0
        var stamp: Double = 0
    }

    /// Context tokens are joined with `\u{1F}` (ASCII unit separator) to form
    /// a single hashable dictionary key — cheaper than hashing `[String]`.
    static let ctxSeparator = "\u{1F}"

    public let order: Int
    public let backoffAlpha: Double
    let logGamma: Double

    private var continuations: [String: [String: DecayedCount]] = [:]
    private var contextTotals: [String: DecayedCount] = [:]
    private let lock = NSLock()

    /// Log-score floor for "never seen".
    public static let floorLogScore: Double = -18.0

    public init(order: Int = 3, halfLifeSeconds: Double = 7 * 24 * 3600, backoffAlpha: Double = 0.4) {
        self.order = max(1, order)
        self.backoffAlpha = backoffAlpha
        self.logGamma = -log(2.0) / max(halfLifeSeconds, 1.0)
    }

    // MARK: - Internal decay helpers

    @inline(__always)
    private func decayed(_ c: DecayedCount, now: Double) -> Double {
        c.value * exp(logGamma * (now - c.stamp))
    }

    @inline(__always)
    private func bump(_ c: inout DecayedCount, now: Double, amount: Double) {
        c.value = decayed(c, now: now) + amount
        c.stamp = now
    }

    @inline(__always)
    static func key(_ ctx: ArraySlice<String>) -> String {
        ctx.joined(separator: ctxSeparator)
    }

    // MARK: - Write path (cold path only)

    /// Observe a token sequence: bump every (context, next) pair up to `order`.
    public func observe(_ tokens: [String], weight: Double = 1.0, now: Double? = nil) {
        guard !tokens.isEmpty else { return }
        let now = now ?? Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<tokens.count {
            for n in 1...order {
                let start = i - n + 1
                if start < 0 { break }
                let ctxKey = Self.key(tokens[start..<i])
                let nxt = tokens[i]
                bump(&continuations[ctxKey, default: [:]][nxt, default: DecayedCount()], now: now, amount: weight)
                bump(&contextTotals[ctxKey, default: DecayedCount()], now: now, amount: weight)
            }
        }
    }

    // MARK: - Read path (hot)

    /// Stupid-Backoff log-score: `S(w|c) = f(c,w)/f(c)` with α backoff per
    /// context shortening. Returns `floorLogScore` when never seen.
    public func score(context: [String], candidate: String, now: Double? = nil) -> Double {
        let now = now ?? Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        var penalty = 0.0
        let lowerBound = max(0, context.count - order + 1)
        for start in lowerBound...context.count {
            let ctxKey = Self.key(context[start..<context.count])
            if let bucket = continuations[ctxKey],
               let cell = bucket[candidate],
               let total = contextTotals[ctxKey] {
                let num = decayed(cell, now: now)
                let den = decayed(total, now: now)
                if num > 1e-6 && den > 1e-6 {
                    return log(num / den) + penalty
                }
            }
            penalty += log(backoffAlpha)
        }
        return Self.floorLogScore
    }

    /// Top-k next tokens under the longest matching context, optionally
    /// filtered by a typed `prefix` (for mid-word completion).
    ///
    /// `minContextMatch` is the minimum number of context tokens that must
    /// match: 1 (default) requires at least bigram evidence — without it the
    /// unigram fallback happily "suggests" the user's most frequent words in
    /// contexts it has never seen, which reads as noise in a completion UI.
    public func topContinuations(context: [String], k: Int = 8, prefix: String = "",
                                 minContextMatch: Int = 1,
                                 now: Double? = nil) -> [(token: String, logProb: Double)] {
        let now = now ?? Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        let upperBound = context.count - minContextMatch
        guard upperBound >= 0 else { return [] }
        let lowerBound = max(0, context.count - order + 1)
        guard lowerBound <= upperBound else { return [] }
        for start in lowerBound...upperBound {
            let ctxKey = Self.key(context[start..<context.count])
            guard let bucket = continuations[ctxKey], !bucket.isEmpty,
                  let total = contextTotals[ctxKey] else { continue }
            let den = decayed(total, now: now)
            guard den > 1e-6 else { continue }
            var items: [(String, Double)] = []
            items.reserveCapacity(min(bucket.count, 16))
            for (tok, cell) in bucket {
                if !prefix.isEmpty && !tok.hasPrefix(prefix) { continue }
                let v = decayed(cell, now: now)
                if v > 1e-4 {
                    items.append((tok, log(v / den)))
                }
            }
            if !items.isEmpty {
                items.sort { $0.1 > $1.1 }
                return Array(items.prefix(k)).map { (token: $0.0, logProb: $0.1) }
            }
        }
        return []
    }

    /// Decayed joint count of (context → next). Used by collocation mining.
    func decayedCount(context ctxKey: String, next: String, now: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let cell = continuations[ctxKey]?[next] else { return 0 }
        return decayed(cell, now: now)
    }

    /// Decayed unigram total (denominator of the empty context).
    func unigramTotal(now: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let total = contextTotals[""] else { return 0 }
        return decayed(total, now: now)
    }

    /// Decayed unigram count of a single token.
    func unigramCount(_ token: String, now: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let cell = continuations[""]?[token] else { return 0 }
        return decayed(cell, now: now)
    }

    // MARK: - Maintenance (cold path)

    /// Delete entries whose decayed value fell below `floor`. Returns removed count.
    @discardableResult
    public func prune(floor: Double = 0.05, now: Double? = nil) -> Int {
        let now = now ?? Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        var removed = 0
        for ctxKey in Array(continuations.keys) {
            var bucket = continuations[ctxKey]!
            for tok in Array(bucket.keys) where decayed(bucket[tok]!, now: now) < floor {
                bucket.removeValue(forKey: tok)
                removed += 1
            }
            if bucket.isEmpty {
                continuations.removeValue(forKey: ctxKey)
                contextTotals.removeValue(forKey: ctxKey)
            } else {
                continuations[ctxKey] = bucket
            }
        }
        return removed
    }

    /// Approximate number of stored (context, next) pairs.
    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.reduce(0) { $0 + $1.value.count }
    }

    // MARK: - Persistence

    public struct SnapshotEntry: Codable, Sendable {
        public let c: String   // context key ("\u{1F}"-joined)
        public let t: String   // next token
        public let v: Double   // raw counter value
        public let s: Double   // stamp (epoch seconds)
    }

    /// Export all entries (context totals are rebuilt on restore).
    public func snapshot() -> [SnapshotEntry] {
        lock.lock()
        defer { lock.unlock() }
        var out: [SnapshotEntry] = []
        out.reserveCapacity(continuations.count * 2)
        for (ctxKey, bucket) in continuations {
            for (tok, cell) in bucket {
                out.append(SnapshotEntry(c: ctxKey, t: tok, v: cell.value, s: cell.stamp))
            }
        }
        return out
    }

    /// Restore from a snapshot, replacing current state. Context totals are
    /// rebuilt exactly: `total = Σ vᵢ · γ^(maxStamp − stampᵢ)` at `maxStamp`.
    public func restore(_ entries: [SnapshotEntry]) {
        lock.lock()
        defer { lock.unlock() }
        continuations.removeAll()
        contextTotals.removeAll()
        var maxStampPerCtx: [String: Double] = [:]
        for e in entries {
            maxStampPerCtx[e.c] = max(maxStampPerCtx[e.c] ?? -.infinity, e.s)
        }
        for e in entries {
            continuations[e.c, default: [:]][e.t] = DecayedCount(value: e.v, stamp: e.s)
            let ref = maxStampPerCtx[e.c]!
            let decayedToRef = e.v * exp(logGamma * (ref - e.s))
            var total = contextTotals[e.c] ?? DecayedCount(value: 0, stamp: ref)
            total.value += decayedToRef
            total.stamp = ref
            contextTotals[e.c] = total
        }
    }
}
