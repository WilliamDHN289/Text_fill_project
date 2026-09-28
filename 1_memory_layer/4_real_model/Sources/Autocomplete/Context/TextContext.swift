import AppKit

struct TextContext {
    let textLength: Int            // Total character count of the text field
    let caretPosition: Int         // Cursor offset in text
    let prefix: String             // Text before cursor (up to ~6000 chars)
    let suffix: String             // Text after cursor (up to ~2000 chars)
    let caretScreenRect: CGRect    // Screen coordinates of caret (AX top-left origin)
    let elementFrame: CGRect       // Screen coordinates of the text field (AX top-left origin)
    let inputBandFrame: CGRect     // Screen coordinates of the input band (text field + buttons)
    let appName: String            // e.g. "TextEdit"
    let appBundleId: String        // e.g. "com.apple.TextEdit"
    let appPid: pid_t              // Process ID of the focused app
    let windowTitle: String        // e.g. "My Document"
    let isPasswordField: Bool
    let isSearchField: Bool
    let font: NSFont?              // Detected font (best effort)
    let textAreaLeftEdge: CGFloat? // X coordinate where text begins (AX screen coords)
    let caretReadingDegraded: Bool // True when caret cascade fell through to Strategy 4
                                   // (element-frame fallback) — meaning per-character bounds
                                   // aren't available and ghost text positioning will be wrong.
                                   // Used by Engine to surface a one-shot hint when the user
                                   // actually triggers a suggestion in a known-limited browser.

    /// Text on the current line before the caret (after last \n or from start)
    var currentLinePrefix: String {
        if let lastNewline = prefix.lastIndex(of: "\n") {
            return String(prefix[prefix.index(after: lastNewline)...])
        }
        return prefix
    }

    /// Whether the caret is at the end of the text (or only trailing whitespace/zero-width chars remain)
    var isAtEndOfText: Bool {
        if suffix.isEmpty { return true }
        return suffix.allSatisfy { $0.isWhitespace || $0 == "\u{FEFF}" || $0 == "\u{200B}" }
    }

    /// Whether the caret is at the end of the current line
    var isAtEndOfLine: Bool {
        if isAtEndOfText { return true }
        // Treat trailing whitespace before newline (or end of text) as end-of-line
        var i = suffix.startIndex
        while i < suffix.endIndex && (suffix[i].isWhitespace || suffix[i] == "\u{200B}" || suffix[i] == "\u{FEFF}") && !suffix[i].isNewline { i = suffix.index(after: i) }
        return i >= suffix.endIndex || suffix[i].isNewline
    }

    /// Whether we should suggest at this position
    var shouldSuggest: Bool {
        if isPasswordField { return false }
        if isSearchField { return false }
        if textLength < 3 { return false }
        return isAtEndOfText || isAtEndOfLine
    }
}
