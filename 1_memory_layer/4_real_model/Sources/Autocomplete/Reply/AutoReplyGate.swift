import Foundation

/// Decides whether the reply badge may auto-appear (idle-in-a-reply-box) for a
/// given app. The manual reply hotkey is NOT gated by this — it works anywhere.
///
/// A generic "is this a reply box" detector is unreliable, so we allowlist apps
/// whose focused, empty, non-search text field is reliably the message/compose
/// box. Gmail and LinkedIn run inside a browser, so they're matched by a
/// window-title brand segment (the same signal MailReplyAdapter uses for Gmail).
enum AutoReplyGate {
    /// Native chat/mail apps, matched by language-independent bundle id.
    private static let nativeBundleIds: Set<String> = [
        "com.tencent.xinWeChat",                          // WeChat
        "com.tinyspeck.slackmacgap",                      // Slack
        "com.microsoft.Outlook",                          // Outlook
        "com.microsoft.teams2", "com.microsoft.teams",    // Teams (new + classic)
        "net.whatsapp.WhatsApp",                          // WhatsApp
        "org.telegram.desktop", "ru.keepcoder.Telegram",  // Telegram (Desktop + macOS)
        "com.hnc.Discord",                                // Discord
        "org.whispersystems.signal-desktop",              // Signal
        "com.apple.MobileSMS",                            // Messages
    ]

    /// Browsers where Gmail / LinkedIn run as web apps.
    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", // Arc
    ]

    /// Window-title brand carried as a standalone segment, e.g.
    /// "… - me@x.com - Gmail - Google Chrome" or "(3) Messaging | LinkedIn".
    private static let webBrands: Set<String> = ["gmail", "linkedin"]

    static func allows(appBundleId: String, windowTitle: String, appName: String) -> Bool {
        if nativeBundleIds.contains(appBundleId) { return true }
        guard browserBundleIds.contains(appBundleId) else { return false }
        // Segment EQUALITY, not substring — a Doc titled "My LinkedIn plan -
        // Google Docs" must not match. Both " - " (Gmail) and " | " (LinkedIn)
        // appear as segment separators across these sites.
        let segments = windowTitle.lowercased()
            .replacingOccurrences(of: " | ", with: " - ")
            .replacingOccurrences(of: " — ", with: " - ")
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return segments.contains { webBrands.contains($0) }
    }
}
