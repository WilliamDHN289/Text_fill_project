import Foundation

/// Per-app preprocessor for Claude Code windows (Terminal / iTerm running
/// `claude --resume` or similar). Isolates the knowledge about Claude Code's
/// TUI quirks — cell padding, horizontal border, `❯` input marker, column
/// width — so the Engine stays boring and future per-app adapters can be
/// added without expanding inline branches.
///
/// The adapter's goal is to keep priorContext (scrollback above the input
/// box) byte-stable as the user keeps typing, so both the OpenAI prompt
/// cache (cloud) and llama.cpp's section-level KV cache (local) can reuse
/// it across keystrokes. Cloud and local share the same split, border
/// strip, and caps — only the downstream prompt layout differs:
/// - Cloud: priorContext is emitted as a labelled `[SCROLLBACK]` section
///   at the head of the user message so the volatile tail doesn't poison
///   the cache prefix.
/// - Local: priorContext is a dedicated section between screenContext and
///   prefix in the llama prompt, with its own cachedScrollbackTokens slot.
enum ClaudeCodeAdapter {
    struct Result {
        /// The active input-line text after the `❯` marker. Small and
        /// volatile (changes every keystroke).
        let trimmedPrefix: String
        /// The stable scrollback above the input-box border. Nil only when
        /// the marker isn't found in the raw prefix (unusual — means we're
        /// probably not actually in Claude Code's input box).
        let priorContext: String?
        /// Claude Code's AX suffix is just empty TUI cells + status chrome;
        /// always cleared.
        let trimmedSuffix: String
    }

    // Heuristic: terminal window running Claude Code. Claude Code sets the
    // window title via ANSI escape; the format varies by version and state —
    // seen forms include `... Claude Code — sourcekit-lsp ◂ claude --resume`
    // and `... — node ✱ claude`. A case-insensitive match on the substring
    // `claude` inside a terminal app covers every format we've observed.
    // The terminal-app gate prevents false positives from browser tabs
    // (`claude.ai` open in Safari/Chrome) or Notes pages titled "Claude".
    /// Known terminal-emulator app names. Exposed so other call sites (e.g. the
    /// message-history transition capture) can recognize a terminal regardless
    /// of whether Claude Code in particular is running in it.
    static let terminalApps: Set<String> = [
        "Terminal",   // Apple Terminal.app
        "iTerm",      // iTerm 1 (legacy)
        "iTerm2",     // iTerm2
        "Warp",
        "Ghostty",
        "Alacritty",
        "kitty",
        "WezTerm",
        "Hyper",
    ]

    /// True if `appName` is a known terminal emulator.
    static func isTerminal(appName: String) -> Bool {
        terminalApps.contains(appName)
    }

    static func matches(windowTitle: String, appName: String) -> Bool {
        guard isTerminal(appName: appName) else { return false }
        return windowTitle.range(of: "claude", options: .caseInsensitive) != nil
    }

    /// Run the full preprocessing pipeline. Assumes `matches` has already
    /// returned true for this context.
    static func preprocess(
        rawPrefix: String,
        provider: String,
        localCap: Int
    ) -> Result {
        // 1. Strip trailing whitespace per line — TUI cells pad every row to
        //    column width (~190 chars), which would eat the prefix cap for
        //    no signal.
        let cleanedPrefix = stripLinePadding(rawPrefix)

        // 2. Locate the `\n❯\u{00A0}` marker that separates scrollback from
        //    the active input line. NOTE: the space after `❯` is U+00A0
        //    NO-BREAK SPACE, not a regular 0x20 space (Claude Code uses
        //    NBSP to keep the prompt glyph glued to the cursor). A literal
        //    regular-space marker silently never matches.
        guard let marker = cleanedPrefix.range(of: inputMarker, options: .backwards) else {
            // No marker → not actually in Claude Code's input box. Fall
            // back to a single-cap trim with no split. Local uses the
            // caller-supplied cap (kept for non-Claude-Code parity); cloud
            // uses the active-prefix cap so the fallback stays small.
            let cap = provider == "local" ? localCap : maxActiveChars
            return Result(
                trimmedPrefix: trimPrefix(cleanedPrefix, maxChars: cap),
                priorContext: nil,
                trimmedSuffix: ""
            )
        }

        let rawPrior = String(cleanedPrefix[..<marker.lowerBound])
        let rawActive = String(cleanedPrefix[marker.upperBound...])

        // 3. Strip trailing TUI chrome from the scrollback — the horizontal
        //    `─` border above the input box, and any blank lines above it.
        //    Done before capping so the freed budget holds real content.
        let strippedPrior = stripTrailingBorder(rawPrior)

        // 4. Independent caps for both providers. A shared cap would crop
        //    priorContext from the head every keystroke as active grows,
        //    defeating both the OpenAI prompt cache (cloud) and llama.cpp's
        //    section-level KV cache (local). Local stays tighter than cloud
        //    because scrollback churn re-decodes the priorContext section when
        //    it changes (3399/3537 new in measured runs during generation).
        //    Raised 500→2000 after observing that reply composition (Claude
        //    idle) keeps scrollback stable with near-total cache reuse, so the
        //    extra context is usually free — churn cost only bites mid-generation.
        let priorCap = provider == "local" ? maxPriorCharsLocal : maxPriorChars
        return Result(
            trimmedPrefix: trimPrefix(rawActive, maxChars: maxActiveChars),
            priorContext: trimPrefix(strippedPrior, maxChars: priorCap),
            trimmedSuffix: ""
        )
    }

    // MARK: - Tunables

    private static let inputMarker = "\n❯\u{00A0}"
    private static let maxPriorChars = 3500       // cloud
    private static let maxPriorCharsLocal = 2000  // local — see comment above
    private static let maxActiveChars = 500

    // MARK: - Helpers

    /// Strip trailing whitespace from every line except the last. Preserves a
    /// trailing space the user just typed (a word boundary the model may rely
    /// on) while removing the TUI cell padding that fills to column width.
    private static func stripLinePadding(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text }
        let lastIdx = lines.count - 1
        let cleaned: [String] = lines.enumerated().map { idx, line in
            if idx == lastIdx { return String(line) }
            var end = line.endIndex
            while end > line.startIndex,
                  line[line.index(before: end)].isWhitespace {
                end = line.index(before: end)
            }
            return String(line[..<end])
        }
        return cleaned.joined(separator: "\n")
    }

    /// Drop trailing "chrome" lines: entirely blank, or composed only of the
    /// `─` box-drawing character (Claude Code's horizontal border above the
    /// input box, 200+ chars of no signal).
    private static func stripTrailingBorder(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "─" }) {
                lines.removeLast()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Cap to `maxChars` keeping the tail; snaps forward to the next newline
    /// for a clean boundary. Duplicated from Engine.trimPrefix so this adapter
    /// stays self-contained.
    private static func trimPrefix(_ prefix: String, maxChars: Int) -> String {
        guard prefix.count > maxChars else { return prefix }
        let startIndex = prefix.index(prefix.endIndex, offsetBy: -maxChars)
        if let newlineIndex = prefix[startIndex...].firstIndex(of: "\n") {
            return String(prefix[prefix.index(after: newlineIndex)...])
        }
        return String(prefix[startIndex...])
    }
}
