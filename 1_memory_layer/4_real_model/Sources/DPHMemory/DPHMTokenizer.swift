import Foundation

/// Lightweight bilingual tokenizer for the DPHM hot path.
///
/// English/Latin words stay whole (including intra-word `'`/`-`/`_`), CJK is
/// split per character, everything else (punctuation) becomes a single-char
/// token. Hand-rolled scanner — no regex — so per-keystroke cost is a few µs
/// even on 200-char tails. Mirrors `_WORD_RE` in the Python reference
/// (3_dphm/dphm.py).
public enum DPHMTokenizer {

    @inline(__always)
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        // CJK Unified Ideographs (base block, same range as the reference).
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    @inline(__always)
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39,          // 0-9
             0x41...0x5A,          // A-Z
             0x61...0x7A,          // a-z
             0x5F,                 // _
             0x2D,                 // -
             0x27:                 // '
            return true
        case 0xC0...0x24F:         // Latin-1 Supplement + Extended-A/B (é, ü, …)
            return true
        default:
            return false
        }
    }

    /// Tokenize `text` (lowercased). O(n) single pass.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        tokens.reserveCapacity(text.count / 4 + 4)
        var current = String.UnicodeScalarView()
        @inline(__always) func flushWord() {
            if !current.isEmpty {
                tokens.append(String(current).lowercased())
                current = String.UnicodeScalarView()
            }
        }
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if isCJK(scalar) {
                flushWord()
                tokens.append(String(Character(scalar)))
            } else if scalar.properties.isWhitespace || scalar == "\n" || scalar == "\t" {
                flushWord()
            } else {
                flushWord()
                tokens.append(String(Character(scalar)))
            }
        }
        flushWord()
        return tokens
    }

    /// True when a token is a Latin/digit word (as opposed to CJK char or punctuation).
    @inline(__always)
    public static func isWordToken(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first else { return false }
        return isWordScalar(first)
    }

    @inline(__always)
    static func isCJKToken(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first else { return false }
        return isCJK(first)
    }

    /// Punctuation that binds to the LEFT (no space before it when detokenizing).
    private static let closingPunct: Set<String> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "…",
        "，", "。", "！", "？", "；", "：", "）", "】", "”", "'",
    ]
    /// Punctuation that binds to the RIGHT (no space after it).
    private static let openingPunct: Set<String> = [
        "(", "[", "{", "（", "【", "“",
    ]

    /// Reassemble tokens into display text: space between two Latin word
    /// tokens, nothing around CJK, closing punctuation glued left, opening
    /// punctuation glued right. Good enough for short habit ghost text.
    public static func detokenize(_ tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "" }
        var out = tokens[0]
        for i in 1..<tokens.count {
            let prev = tokens[i - 1]
            let cur = tokens[i]
            let needsSpace: Bool
            if closingPunct.contains(cur) {
                needsSpace = false
            } else if openingPunct.contains(prev) {
                needsSpace = false
            } else if isCJKToken(prev) || isCJKToken(cur) {
                needsSpace = false
            } else if isWordToken(prev) && isWordToken(cur) {
                needsSpace = true
            } else if closingPunct.contains(prev) {
                // after a closing punct, a following word gets a space
                needsSpace = isWordToken(cur)
            } else {
                needsSpace = false
            }
            if needsSpace { out += " " }
            out += cur
        }
        return out
    }
}
