import Foundation

/// Tolerant comparison of two OCR results. Vision OCR isn't deterministic across
/// runs even on near-identical images (anti-aliasing jitter, language correction,
/// line-split differences), so we use token-set Jaccard similarity with a
/// threshold rather than literal string equality.
///
/// The threshold is intentionally tight (`0.95`) and biased toward re-firing on
/// any real change — a missed refresh leaves the user with a stale-context
/// suggestion they might commit, which is worse than an extra cloud round-trip.
enum OCRSimilarity {
    static let defaultThreshold: Double = 0.95

    /// Decide whether the context change warrants notifying the engine.
    /// - nil → nil:  no change
    /// - nil → text: first context arrived, notify
    /// - text → nil: intentional invalidation, don't re-fire
    /// - text → text: notify iff Jaccard similarity < threshold
    static func contextChanged(old: String?, new: String?, threshold: Double = defaultThreshold) -> Bool {
        switch (old, new) {
        case (nil, nil):           return false
        case (nil, _):             return true
        case (_, nil):             return false
        case let (.some(a), .some(b)):
            let sim = jaccardSimilarity(tokenize(a), tokenize(b))
            return sim < threshold
        }
    }

    static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 1.0 : Double(inter) / Double(union)
    }

    /// CJK characters become single-character tokens (each Han / Kana glyph is
    /// semantically a "word"); Latin/digit runs are grouped until the next
    /// whitespace or punctuation. This gives a fair token-set comparison for
    /// the Chinese-heavy chat content we see in practice.
    static func tokenize(_ s: String) -> Set<String> {
        var tokens: Set<String> = []
        var word = ""
        for ch in s {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            let isCJK = (0x4E00...0x9FFF).contains(scalar)       // CJK Unified Ideographs
                    || (0x3400...0x4DBF).contains(scalar)        // Extension A
                    || (0x3040...0x30FF).contains(scalar)        // Hiragana + Katakana
                    || (0xAC00...0xD7AF).contains(scalar)        // Hangul syllables
            if isCJK {
                if !word.isEmpty { tokens.insert(word); word = "" }
                tokens.insert(String(ch))
            } else if ch.isLetter || ch.isNumber {
                word.append(ch.lowercased())
            } else {
                if !word.isEmpty { tokens.insert(word); word = "" }
            }
        }
        if !word.isEmpty { tokens.insert(word) }
        return tokens
    }
}
