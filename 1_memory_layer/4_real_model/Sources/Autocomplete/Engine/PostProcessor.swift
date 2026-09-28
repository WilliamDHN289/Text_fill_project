import Foundation

struct PostProcessor {

    /// Trims overlap between suggestion and existing text around cursor
    static func trimOverlap(suggestion: String, prefix: String, suffix: String) -> String {
        var result = suggestion

        // 0. Strip wrapping quotes that the model sometimes adds
        result = stripWrappingQuotes(result)

        // 1. Strip prefix overlap
        // Find the longest suffix of `prefix` that matches the start of `suggestion`.
        // Compare via dedupNormalize so NBSP↔regular-space and curly↔straight quotes
        // match (LinkedIn/Gmail/etc. emit NBSP; LLMs return ASCII; some models return U+2019).
        //
        // Mid-word floor: when prefix ends in a Latin letter/digit, require ≥2 chars
        // of overlap. A 1-char Latin letter match is almost always coincidental — e.g.
        // prefix "it is ef" + suggestion "fective" has a phantom "f"="f" tail
        // match that, if stripped, produces "ective" → "it is efective" (one f
        // missing). For non-Latin word-level scripts (CJK ideographs, etc.) and
        // non-alphanumeric tails, keep the 1-char threshold: a single CJK char is
        // already a word-level semantic unit, so 1-char CJK echo at the boundary
        // is virtually always a real overlap (cloud providers without assistant
        // prefill produce these regularly — "...这样" + "样，..." → strip "样").
        let minPrefixOverlap = isLatinAlphanumericTail(prefix) ? 2 : 1
        let maxPrefixCheck = min(prefix.count, result.count)
        var prefixOverlap = 0
        if maxPrefixCheck >= minPrefixOverlap {
            for length in stride(from: maxPrefixCheck, through: minPrefixOverlap, by: -1) {
                let prefixEnd = String(prefix.suffix(length))
                let suggestionStart = String(result.prefix(length))
                if dedupNormalize(prefixEnd) == dedupNormalize(suggestionStart) {
                    prefixOverlap = length
                    break
                }
            }
        }
        if prefixOverlap > 0 {
            result = String(result.dropFirst(prefixOverlap))
        }

        // 2. Strip suffix overlap
        // Find the longest prefix of `suffix` that matches the end of `result`
        let maxSuffixCheck = min(suffix.count, result.count)
        var suffixOverlap = 0
        for length in stride(from: maxSuffixCheck, through: 1, by: -1) {
            let suffixStart = String(suffix.prefix(length))
            let resultEnd = String(result.suffix(length))
            if dedupNormalize(suffixStart) == dedupNormalize(resultEnd) {
                suffixOverlap = length
                break
            }
        }
        if suffixOverlap > 0 {
            result = String(result.dropLast(suffixOverlap))
        }

        // 3. Strip trailing quote if one remains after overlap trimming
        if result.hasSuffix("\"") || result.hasSuffix("'") || result.hasSuffix("`") {
            result = String(result.dropLast())
        }

        return result
    }

    /// Insert a missing separator when the suggestion would be glued onto the
    /// last word in prefix without whitespace. Two trigger cases:
    ///
    ///   1. Prefix ends in terminal punctuation (".!?,;:" + CJK equivalents) —
    ///      always safe: "...further." + "I'm available..." → space added.
    ///
    ///   2. Prefix ends in a letter/number AND atWordBoundary is true (auto-
    ///      trigger after a full-accept) — "engagement" + "and rapid adoption"
    ///      → space added. We gate on atWordBoundary because we can't otherwise
    ///      distinguish end-of-word ("engagement"+"and") from mid-word resume
    ///      ("engag"+"ement"); the auto-trigger flag tells us the previous
    ///      chunk completed cleanly so the new request is a fresh continuation.
    ///
    /// Skips when the suggestion already starts with whitespace (model added
    /// its own separator) or with a non-letter (URLs, quotes, mid-word
    /// apostrophes like "you" + "'d like").
    static func ensureSeparator(suggestion: String, prefix: String, atWordBoundary: Bool = false) -> String {
        guard let suggestionFirst = suggestion.first,
              suggestionFirst.isLetter,
              let prefixLast = prefix.last else {
            return suggestion
        }
        let isTerminalPunct = ".!?,;:。！？，；：".contains(prefixLast)
        let isWordChar = prefixLast.isLetter || prefixLast.isNumber
        if isTerminalPunct || (atWordBoundary && isWordChar) {
            return " " + suggestion
        }
        return suggestion
    }

    /// True if the substring contains at least one letter or number.
    /// Used to reject degenerate punctuation-only chunks during chunking.
    private static func hasMeaningfulContent(_ s: Substring) -> Bool {
        return s.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// True when the prefix's last character is a Basic-Latin/Latin-1 letter or
    /// ASCII digit. Used to apply the 2-char mid-word floor only to scripts where
    /// 1-char letter matches are typically phantom ("it is ef" + "fective"
    /// matching "f"="f"). CJK / Cyrillic / Arabic / etc. fall through to the
    /// 1-char threshold since their characters are word-level units.
    private static func isLatinAlphanumericTail(_ prefix: String) -> Bool {
        guard let last = prefix.last,
              let v = last.unicodeScalars.first?.value else { return false }
        guard last.isLetter || last.isNumber else { return false }
        // Basic Latin (0x0000–0x007F) + Latin-1 Supplement (0x0080–0x00FF) +
        // Latin Extended-A (0x0100–0x017F) + Latin Extended-B (0x0180–0x024F).
        // Everything from 0x0250+ (IPA, combining, Greek, CJK, ...) is excluded.
        return v < 0x0250
    }

    /// Lowercase + collapse common variant whitespace/quotes for overlap matching.
    /// Keeps length stable so the matched count maps back to the original string.
    private static func dedupNormalize(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            let c: Character
            switch scalar.value {
            case 0x00A0, 0x2007, 0x202F: c = " "          // NBSP, figure space, narrow NBSP
            case 0x2018, 0x2019, 0x201B: c = "'"          // curly / reversed single quotes
            case 0x201C, 0x201D, 0x201F: c = "\""         // curly double quotes
            default: c = Character(scalar)
            }
            out.append(c)
        }
        return out.lowercased()
    }

    /// Remove wrapping quotes from AI responses: "text" → text, 'text' → text
    private static func stripWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 {
            let first = trimmed.first!
            let last = trimmed.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "`" && last == "`") {
                return String(trimmed.dropFirst().dropLast())
            }
            // Also handle leading quote without matching close (model started with quote)
            if first == "\"" || first == "'" || first == "`" {
                return String(trimmed.dropFirst())
            }
        }
        return text
    }

    /// Extract the first word from a suggestion for partial (word-by-word) accept,
    /// INCLUDING any trailing whitespace run after it. Bundling the trailing space
    /// means each Tab leaves the caret ready for the next word ("hello |" rather
    /// than "hello|"), and the remaining ghost text carries no dangling leading
    /// space. The text after a full word-by-word accept is identical either way —
    /// the space just lands with the word instead of in front of the next one.
    ///
    /// Sentence punctuation (".!?,;:" + CJK equivalents) is split off as its own
    /// unit rather than bundled with the word: "hello," accepts as "hello", then
    /// "," on the next Tab. Intra-word marks (apostrophes, hyphens) stay attached,
    /// so contractions ("don't") and compounds ("well-known") aren't split.
    static func firstWord(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }

        // Include leading whitespace from original text
        let leadingWhitespace = String(text.prefix(while: { $0.isWhitespace }))

        // Find the first word boundary after the leading whitespace
        let rest = String(text.drop(while: { $0.isWhitespace }))

        // Locate the end of the word unit within `rest`. Sentence punctuation
        // (".!?,;:" + CJK equivalents) is NOT bundled with the word — it forms
        // its own accept unit, so word-by-word Tab commits one word OR one
        // punctuation run per press. (Full accept via backtick still takes the
        // whole suggestion, punctuation included.)
        let wordEnd: String.Index
        if let firstChar = rest.first, isCJKWordUnit(firstChar) {
            // CJK ideographs / Japanese kana are word-level units and aren't
            // space-separated. Accept one character per Tab so users get the
            // same per-token feel as Latin "one word per press". Hangul is
            // excluded — Korean uses spaces between words.
            wordEnd = rest.index(after: rest.startIndex)
        } else if let firstChar = rest.first, isSentencePunctuation(firstChar) {
            // `rest` leads with sentence punctuation — the preceding word was
            // accepted on the previous Tab. Accept the whole consecutive run
            // ("..." or "?!") as a single unit.
            var end = rest.startIndex
            while end < rest.endIndex, isSentencePunctuation(rest[end]) {
                end = rest.index(after: end)
            }
            wordEnd = end
        } else if let boundary = rest.firstIndex(where: { $0.isWhitespace || isSentencePunctuation($0) }) {
            // Word ends at the next space or sentence punctuation. Stop before
            // the punctuation so it becomes its own unit on the next Tab.
            wordEnd = boundary
        } else {
            return text // Entire text is one word (no trailing space to bundle)
        }

        // Bundle the trailing whitespace run so the accepted unit is "word + space".
        var end = wordEnd
        while end < rest.endIndex, rest[end].isWhitespace {
            end = rest.index(after: end)
        }
        return leadingWhitespace + String(rest[rest.startIndex..<end])
    }

    /// Sentence / clause punctuation (".!?,;:" + CJK equivalents). During
    /// word-by-word accept this forms its own unit rather than bundling with the
    /// adjacent word. Same terminal-punctuation set ensureSeparator keys on.
    private static func isSentencePunctuation(_ ch: Character) -> Bool {
        return ".!?,;:。！？，；：".contains(ch)
    }

    /// True for CJK ideographs and Japanese kana — scripts where each char is
    /// a word-level unit and text isn't space-delimited. Excludes Hangul
    /// (Korean is space-delimited like Latin) and CJK punctuation (handled by
    /// the isSentencePunctuation branch).
    private static func isCJKWordUnit(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3040...0x30FF,    // Hiragana / Katakana
             0x3400...0x4DBF,    // CJK Ext A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xF900...0xFAFF,    // CJK Compat Ideographs
             0xFF66...0xFF9F:    // Halfwidth Katakana
            return true
        default:
            return false
        }
    }

    /// Split text into a display chunk and remainder for progressive disclosure.
    /// Returns (chunk to display, remaining text). Breaks at natural boundaries:
    /// 1. First \n (paragraph break)
    /// 1.5. If total display width > comfortWidth (20): earliest punctuation of any kind within the first comfortWidth units (CJK = 2, Latin = 1)
    /// 2. First sentence end (. ! ? 。 ！ ？) if within maxLength
    /// 3. First clause boundary (, ; : ， ； ： 、) within maxLength
    /// 4. Last word boundary within maxLength (only when text > maxLength, to prevent mid-word hard cut)
    static func firstChunk(of text: String, maxLength: Int = 70, comfortWidth: Int = 20, forceComfort: Bool = false) -> (chunk: String, remainder: String) {
        guard text.count > 0 else { return (text, "") }
        Log.debug("[Chunk] input length=\(text.count) maxLength=\(maxLength) text='\(text.prefix(50))'")

        // 0. Include leading newlines in the chunk so they don't block the text behind them
        let leadingNewlines = String(text.prefix(while: { $0.isNewline }))
        let textAfterNewlines = String(text.dropFirst(leadingNewlines.count))
        if !leadingNewlines.isEmpty {
            if textAfterNewlines.isEmpty { return (text, "") }
            let (subChunk, subRemainder) = firstChunk(of: textAfterNewlines, maxLength: maxLength, comfortWidth: comfortWidth, forceComfort: forceComfort)
            return (leadingNewlines + subChunk, subRemainder)
        }

        // 1. Break at first \n if within maxLength — keep \n in remainder
        if let newlineIdx = text.firstIndex(of: "\n") {
            let distToNewline = text.distance(from: text.startIndex, to: newlineIdx)
            if distToNewline <= maxLength {
                let chunk = String(text[..<newlineIdx])
                let remainder = String(text[newlineIdx...]) // keeps the \n
                return (chunk, remainder)
            }
            // Newline exists but beyond maxLength — fall through to break within maxLength
        }

        // 1.5. Comfort break: when text is visually long, prefer the earliest punctuation in the
        //      first `comfortWidth` width units so the reader sees a digestible first chunk.
        //      Width-aware: CJK chars count as 2, Latin as 1, so 20 width ≈ 10 汉字 ≈ 20 letters.
        //      forceComfort: progressive disclosure passes true to require a break within the cap;
        //      falls through to word-boundary safety (extend forward) before hard-cut.
        if displayWidth(of: text) > comfortWidth {
            let comfortEnd = prefixIndex(of: text, widthAtMost: comfortWidth)
            if comfortEnd > text.startIndex {
                let comfortRange = text.startIndex..<comfortEnd
                let allBreaks = [". ", "! ", "? ", "。", "！", "？", ", ", "; ", ": ", "，", "；", "：", "、"]
                var earliest: Range<String.Index>? = nil
                for pattern in allBreaks {
                    if let range = text.range(of: pattern, range: comfortRange),
                       earliest == nil || range.lowerBound < earliest!.lowerBound {
                        earliest = range
                    }
                }
                // Skip degenerate breaks (leading punctuation: model continues into ", with…").
                // Without this, chunk 0 ends up as just "," when text starts with ", ".
                if let range = earliest, hasMeaningfulContent(text[..<range.lowerBound]) {
                    let breakIdx = range.lowerBound
                    let chunk = String(text[...breakIdx]) // includes punctuation
                    let remainder = String(text[text.index(after: breakIdx)...])
                    return (chunk, remainder)
                }
                if forceComfort {
                    // Last word boundary inside cap range
                    if let spaceIdx = text[comfortRange].lastIndex(of: " ") {
                        let chunk = String(text[..<spaceIdx])
                        let remainder = String(text[spaceIdx...])
                        return (chunk, remainder)
                    }
                    // Word-boundary safety: extend cap to first space after the cap range
                    if let spaceIdx = text[comfortEnd...].firstIndex(of: " ") {
                        let chunk = String(text[..<spaceIdx])
                        let remainder = String(text[spaceIdx...])
                        return (chunk, remainder)
                    }
                    // Hard cut at comfortEnd (rare: pathological no-space text)
                    return (String(text[..<comfortEnd]), String(text[comfortEnd...]))
                }
            }
        }

        // 2. Find first sentence end within search window — same degenerate-break guard as 1.5/3.
        let searchLength = min(maxLength, text.count)
        let searchEnd = text.index(text.startIndex, offsetBy: searchLength)
        let searchRange = text.startIndex..<searchEnd
        // English patterns require a trailing space; CJK patterns are single-char (no trailing space).
        for pattern in [". ", "! ", "? ", "。", "！", "？"] {
            if let range = text.range(of: pattern, range: searchRange),
               hasMeaningfulContent(text[..<range.lowerBound]) {
                let breakIdx = range.lowerBound
                let chunk = String(text[...breakIdx]) // includes punctuation
                let remainder = String(text[text.index(after: breakIdx)...]) // for English: keeps leading space
                return (chunk, remainder)
            }
        }
        // Check if text ends with sentence punctuation within search window
        let upToMax = String(text[..<searchEnd])
        if let last = upToMax.last, ".!?。！？".contains(last) {
            let remainder = String(text[searchEnd...])
            // For English, prepend a space to normalize remainder; for CJK, no leading space.
            let needsSpace = ".!?".contains(last) && !remainder.isEmpty
            return (upToMax, needsSpace ? " " + remainder : remainder)
        }

        // 3. First clause boundary within search window — same degenerate-break guard as 1.5.
        for pattern in [", ", "; ", ": ", "，", "；", "：", "、"] {
            if let range = text.range(of: pattern, range: searchRange),
               hasMeaningfulContent(text[..<range.lowerBound]) {
                let chunk = String(text[...range.lowerBound]) // includes punctuation
                let remainder = String(text[text.index(after: range.lowerBound)...]) // for English: keeps leading space
                return (chunk, remainder)
            }
        }

        // If text fits within maxLength and no punctuation break found, show it all
        if text.count <= maxLength { return (text, "") }

        // 4. Last word boundary within maxLength — prevent mid-word hard cut
        if let spaceIdx = text[..<searchEnd].lastIndex(of: " ") {
            let chunk = String(text[..<spaceIdx])
            let remainder = String(text[spaceIdx...]) // keeps the space
            return (chunk, remainder)
        }

        // Fallback: hard cut at maxLength
        return (upToMax, String(text[searchEnd...]))
    }

    /// East Asian Width approximation: CJK / fullwidth / Hangul = 2, else 1.
    /// Emoji and exotic scripts fall through to 1 (acceptable for our UX scope).
    static func displayWidth(of character: Character) -> Int {
        guard let v = character.unicodeScalars.first?.value else { return 1 }
        switch v {
        case 0x1100...0x115F,    // Hangul Jamo
             0x2E80...0x303E,    // CJK Radicals / Kangxi / CJK Symbols and Punctuation
             0x3041...0x33FF,    // Hiragana / Katakana / Bopomofo / CJK compat
             0x3400...0x4DBF,    // CJK Ext A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xA000...0xA4CF,    // Yi Syllables
             0xAC00...0xD7A3,    // Hangul Syllables
             0xF900...0xFAFF,    // CJK Compat Ideographs
             0xFE30...0xFE4F,    // CJK Compat Forms
             0xFF00...0xFF60,    // Fullwidth Forms
             0xFFE0...0xFFE6:    // Fullwidth Signs
            return 2
        default:
            return 1
        }
    }

    static func displayWidth(of text: String) -> Int {
        text.reduce(0) { $0 + displayWidth(of: $1) }
    }

    /// Returns the largest index `i` such that `displayWidth(text[..<i]) <= maxWidth`.
    static func prefixIndex(of text: String, widthAtMost maxWidth: Int) -> String.Index {
        var acc = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            let w = displayWidth(of: text[idx])
            if acc + w > maxWidth { return idx }
            acc += w
            idx = text.index(after: idx)
        }
        return text.endIndex
    }

    /// Check if suggestion is worth showing (basic quality filter)
    static func isWorthShowing(_ suggestion: String) -> Bool {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        // Threshold lowered to <1 (was <2) — experiment: allow single-character
        // suggestions to observe whether they're useful or just flicker.
        if trimmed.count < 1 { return false }
        // Don't show if it's just whitespace
        if trimmed.isEmpty { return false }
        return true
    }

    /// Width cap per chunk index, parameterized by chunking style.
    /// - progressive: per-chunk-idx ramp (15/30/45/60/75/90/105/unbounded).
    /// - natural:     fixed 70 for every chunk — break at any punctuation in the
    ///                first 70 wu, otherwise word boundary, otherwise hard cut.
    /// Returns nil only in progressive mode at chunk_idx ≥ 7 (unbounded).
    static func progressiveWidthCap(forChunkIndex idx: Int, style: ChunkingStyle = .progressive) -> Int? {
        switch style {
        case .natural:
            return 70
        case .progressive:
            switch idx {
            case 0: return 15
            case 1: return 30
            case 2: return 45
            case 3: return 60
            case 4: return 75
            case 5: return 90
            case 6: return 105
            default: return nil
            }
        }
    }

    /// Progressive chunk: scales the comfort cap by chunk index (progressive style)
    /// or uses a fixed 70-wu cap (natural style). Forces a break within the cap when
    /// bounded; falls through to firstChunk's natural-break behavior when unbounded.
    static func progressiveChunk(of text: String, chunkIndex: Int, style: ChunkingStyle = .progressive) -> (chunk: String, remainder: String) {
        if let cap = progressiveWidthCap(forChunkIndex: chunkIndex, style: style) {
            return firstChunk(of: text, comfortWidth: cap, forceComfort: true)
        }
        return firstChunk(of: text)
    }
}
