import Foundation

/// Shared text-normalization helpers for content we feed into the LLM —
/// recent sent messages, clipboard items, screen-context OCR, and
/// (eventually) user-provided about-me context. Centralizes the
/// definition of "what counts as whitespace for our purposes" plus the
/// two collapse policies so each consumer doesn't grow its own
/// idiosyncratic version.
enum TextNormalize {
    /// Whitespace-equivalent set used for trim/collapse. Extends Apple's
    /// `.whitespacesAndNewlines` (which catches U+0020, U+00A0, tab, all
    /// common newlines) with zero-width Unicode chars that some apps —
    /// notably Terminal scrollback and iMessage — sprinkle into AX text.
    /// Without these, normalization can stop at a trailing zero-width
    /// char and leave visible whitespace untouched.
    static let trimCharacterSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{2060}\u{0000}")
        return set
    }()

    /// Aggressive collapse: trim edges + collapse ALL internal whitespace
    /// runs (including newlines) to a single space. Use for content where
    /// flat representation is acceptable (chat messages, clipboard items).
    /// Tradeoff: paragraph breaks become a single space — line structure
    /// is lost. Worth it for density.
    static func collapseToSingleLine(_ raw: String) -> String {
        raw.components(separatedBy: trimCharacterSet)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Per-line collapse: `collapseToSingleLine` applied to each line
    /// independently, preserving line structure. Use for OCR output or
    /// any content where line semantics matter (UI layouts, terminal
    /// scrollback, structured text). Empty lines are dropped.
    static func collapsePerLine(_ raw: String) -> String {
        raw.components(separatedBy: "\n")
            .map { collapseToSingleLine($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
