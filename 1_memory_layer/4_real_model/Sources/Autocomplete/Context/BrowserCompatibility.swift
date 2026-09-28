import AppKit

/// Detection and one-shot user-facing hints for browsers where macOS accessibility
/// can't expose per-character text bounds — meaning we can't position inline ghost
/// text at the cursor.
///
/// Why these specific browsers: they're all Chromium-based (or Firefox) and ship with
/// the `AXMode::kInlineTextBoxes` flag (Chromium's "Text Metrics" accessibility feature)
/// disabled by default. Without that flag, `AXBoundsForRange` returns no useful layout
/// data, and our caret-reading cascade falls all the way through to Strategy 4
/// (element-frame fallback), which positions ghost text at the top-right of the input
/// element rather than at the actual cursor — clearly wrong.
///
/// Standard Chrome and Edge work fine because they auto-enable Text Metrics whenever an
/// AX consumer (like our app) is active. Arc/Dia disabled this auto-enable for performance,
/// so users have to manually open `chrome://accessibility` and check "Text Metrics".
/// Firefox and Zen don't expose these AX APIs at all and can't be fixed from outside.
@MainActor
enum LimitedBrowser: String {
    case arc = "company.thebrowser.Browser"
    case dia = "company.thebrowser.dia"
    case firefox = "org.mozilla.firefox"
    case firefoxDev = "org.mozilla.firefoxdeveloperedition"
    case zen = "app.zen-browser.zen"

    var displayName: String {
        switch self {
        case .arc: return "Arc"
        case .dia: return "Dia"
        case .firefox: return "Firefox"
        case .firefoxDev: return "Firefox Developer Edition"
        case .zen: return "Zen Browser"
        }
    }

    /// Whether the user can fix this browser by enabling Text Metrics.
    /// Arc/Dia: yes (Chromium-based, just need the flag flipped).
    /// Firefox/Zen: no (Gecko doesn't expose the AX APIs at all).
    var isFixable: Bool {
        switch self {
        case .arc, .dia: return true
        case .firefox, .firefoxDev, .zen: return false
        }
    }

    static func from(bundleId: String) -> LimitedBrowser? {
        return LimitedBrowser(rawValue: bundleId)
    }
}

@MainActor
final class BrowserCompatibilityChecker {
    static let shared = BrowserCompatibilityChecker()

    /// Browsers we've already shown the hint for in this app session.
    /// Resets on app restart so users get a fresh chance to see it.
    private var shownThisSession: Set<String> = []

    /// Browsers the user has permanently dismissed via the ✕ button.
    private let dismissedKey = "BrowserCompatibility.permanentlyDismissed"

    private var permanentlyDismissed: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    private func dismissPermanently(_ bundleId: String) {
        var current = permanentlyDismissed
        current.insert(bundleId)
        UserDefaults.standard.set(Array(current), forKey: dismissedKey)
    }

    /// Lazily-created floating hint panel. Owned here so we can keep it alive
    /// across hint shows without each call paying construction cost.
    private lazy var hintPanel: BrowserHintPanel = BrowserHintPanel()

    /// Surface a one-shot hint for a limited browser if we haven't shown it this
    /// session and the user hasn't permanently dismissed it. Idempotent — calling
    /// this every keystroke is safe.
    ///
    /// `elementFrame` is the AX-coordinate frame of the focused input element;
    /// the hint panel attaches to its top edge.
    func notifyIfNeeded(browser: LimitedBrowser, elementFrame: CGRect) {
        let id = browser.rawValue
        guard !shownThisSession.contains(id),
              !permanentlyDismissed.contains(id) else { return }
        shownThisSession.insert(id)
        Log.info("BrowserCompat: \(browser.displayName) detected with degraded caret reading — surfacing hint")
        showHint(for: browser, elementFrame: elementFrame)
    }

    private func showHint(for browser: LimitedBrowser, elementFrame: CGRect) {
        let message: String
        let linkText: String?
        let linkURL: URL?
        if browser.isFixable {
            message = "FlowIn is limited in \(browser.displayName) — enable “Text Metrics” in chrome://accessibility for full access"
            linkText = "chrome://accessibility"
            linkURL = URL(string: "chrome://accessibility")
        } else {
            message = "FlowIn is limited in \(browser.displayName) — its accessibility APIs don’t expose the data FlowIn needs"
            linkText = nil
            linkURL = nil
        }

        // Link click: open the URL in the target browser via AppleScript's
        // standard `open location` command. chrome:// URLs can't be opened via
        // NSWorkspace because no app claims the scheme system-wide; the only way
        // to navigate to chrome://accessibility is to ask a specific browser to
        // open it. AppleScript automation requires user permission on first use
        // (macOS will prompt). Falls back to clipboard copy on failure.
        hintPanel.onLinkClick = { url in
            Self.openURLInBrowser(url.absoluteString, browserBundleId: browser.rawValue)
        }

        // Dismiss (✕): permanent — user has explicitly told us not to show this again.
        hintPanel.onDismissTap = { [weak self] in
            self?.dismissPermanently(browser.rawValue)
        }

        hintPanel.show(message: message, linkText: linkText, linkURL: linkURL, elementFrame: elementFrame)
    }

    /// Opens a URL in the given browser via AppleScript's `open location` command,
    /// which is part of the Standard Suite supported by all Cocoa/AppKit apps that
    /// register their bundle ID. Chromium-based browsers (Chrome, Arc, Dia, Edge,
    /// Brave, etc.) inherit this from Chrome's scripting dictionary. Falls back to
    /// copying the URL to the clipboard on failure.
    private static func openURLInBrowser(_ url: String, browserBundleId: String) {
        let script = """
        tell application id "\(browserBundleId)"
            activate
            open location "\(url)"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            _ = appleScript.executeAndReturnError(&error)
            if let error = error {
                Log.error("BrowserCompat: AppleScript open failed for \(browserBundleId): \(error). Falling back to pasteboard.")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url, forType: .string)
            } else {
                Log.info("BrowserCompat: opened \(url) in \(browserBundleId) via AppleScript")
            }
        }
    }
}
