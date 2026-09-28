import Foundation

/// Per-host insertion policy. A policy is a list of `InsertionMethod` tiers to try
/// in order; the first tier that successfully inserts wins.
///
/// Most hosts use the default policy `[.m1, .m2, .m3]`. A small number
/// of known-quirky host classes override the default because their preferred primitive
/// is different. Examples:
///
/// - **Terminal emulators**: clipboard-first, because modern shells and TUI apps
///   interpret pasted content via *bracketed paste mode* — a single escape-wrapped
///   text chunk that bypasses the shell's per-char interpretation (Tab → completion,
///   Enter → submit, etc.). Synthesis sends each character as an individual key event,
///   which the shell processes one at a time, causing Tab-triggered completions,
///   premature command submission, and other pathologies.
///
/// Routing is a pure in-memory dictionary lookup (~50–100ns), zero I/O, zero AX calls.
/// Adding new overrides is a one-line addition to `overrides`.
struct InsertionPolicy {
    /// Ordered list of tiers to attempt. The insert function walks this list and
    /// stops at the first tier that returns true.
    let tiers: [InsertionMethod]
    /// Milliseconds to sleep after each synthesized Return keystroke before the
    /// next sync setUnicodeString batch. Workaround for WebKit/Blink hosts where
    /// Return triggers async DOM mutation (new <div>/<br>, autosave, reflow) and
    /// the next batch otherwise lands on the stale DOM (text on previous line).
    /// Default 0 = no delay (native Cocoa apps, terminals).
    let newlineDelayMs: Int
    /// Whether this host renders its cursor as a full-width block (terminals).
    /// When true, `SuggestionPanel` offsets ghost text by ~one char width so the
    /// first glyph doesn't land inside the cursor block.
    let isCursorBlock: Bool

    init(tiers: [InsertionMethod], newlineDelayMs: Int = 0, isCursorBlock: Bool = false) {
        self.tiers = tiers
        self.newlineDelayMs = newlineDelayMs
        self.isCursorBlock = isCursorBlock
    }
}

enum InsertionRouting {
    /// Default for the vast majority of hosts. Safari, Chrome (non-blockquote Gmail),
    /// all native Cocoa text views, Electron apps, WKWebView embeds, etc.
    /// - AX is fastest and leaves the host in a coherent state.
    /// - Synthesis handles WebKit contenteditables with structured siblings where
    ///   AX set silently fails (Gmail expanded-history compose, Zoho mail compose).
    /// - Clipboard is a last-resort fallback for anything synthesis can't handle.
    static let defaultPolicy = InsertionPolicy(tiers: [.m1, .m2, .m3])

    /// Policy for terminal emulators. Clipboard paste (which shells interpret as
    /// bracketed paste) is the correct primitive for inserting text into a shell's
    /// input buffer. Synthesis is kept as a fallback in case the clipboard path
    /// fails for some reason (e.g. the shell has bracketed paste disabled).
    /// AX is skipped entirely — terminals don't support `setSelectedText` on their
    /// display grid.
    private static let terminalPolicy = InsertionPolicy(tiers: [.m3, .m2], isCursorBlock: true)

    /// Safari: same tier order as default, but a 200ms gap after each synthesized
    /// Return. WebKit contenteditables (Gmail, Outlook web) process Return through
    /// an async DOM-mutation path; without the delay the next sync setUnicodeString
    /// batch arrives before the new line exists and lands on the old line.
    private static let safariPolicy = InsertionPolicy(tiers: [.m1, .m2, .m3], newlineDelayMs: 200)

    /// Bundle ID → policy overrides. Unlisted apps get `defaultPolicy`.
    private static let overrides: [String: InsertionPolicy] = [
        // Terminal emulators — bracketed paste is the right primitive
        "com.apple.Terminal": terminalPolicy,
        "com.googlecode.iterm2": terminalPolicy,
        "net.kovidgoyal.kitty": terminalPolicy,
        "io.alacritty": terminalPolicy,
        "dev.warp.Warp-Stable": terminalPolicy,
        "com.mitchellh.ghostty": terminalPolicy,
        "com.github.wez.wezterm": terminalPolicy,
        "co.zeit.hyper": terminalPolicy,
        "org.tabby": terminalPolicy,

        // Safari — Return goes async in WebKit contenteditables (Gmail compose)
        "com.apple.Safari": safariPolicy,
        "com.apple.SafariTechnologyPreview": safariPolicy,
    ]

    /// Resolve the insertion policy for a given bundle ID. Returns `defaultPolicy`
    /// for unknown/unlisted hosts. Called once per `TextInserter.insert(...)`.
    static func policy(for bundleId: String) -> InsertionPolicy {
        return overrides[bundleId] ?? defaultPolicy
    }

    /// Whether the given host renders its cursor as a full-width block (e.g. terminal
    /// emulators). Used by `SuggestionPanel` to offset the ghost text by one character
    /// width so the first glyph doesn't land inside the cursor block.
    ///
    /// Driven by `InsertionPolicy.isCursorBlock` — not derived from dictionary
    /// membership, since `overrides` also holds non-terminal policies (e.g. Safari's
    /// `newlineDelayMs` override) that must keep the default I-beam alignment.
    static func isCursorBlockHost(_ bundleId: String) -> Bool {
        return policy(for: bundleId).isCursorBlock
    }
}
