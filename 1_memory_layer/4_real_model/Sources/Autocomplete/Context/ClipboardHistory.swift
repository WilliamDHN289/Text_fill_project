import AppKit
import Foundation

/// In-memory history of the last 3 clipboard items. Polled at 1 Hz off
/// `NSPasteboard.general.changeCount`. Text is captured directly; a clipboard
/// holding a bitmap image but no text (a screenshot / "Copy Image") is OCR'd
/// via `OCREngine` and the recognized text is recorded like any text item.
/// The same capture-time filters apply to both: items copied while a password
/// manager is frontmost are dropped, and the credential heuristic
/// (`looksSensitive`) drops obvious secrets — including in OCR output — before
/// they reach the clipboard context.
@MainActor
final class ClipboardHistory {
    private(set) var items: [String] = []
    private var lastChangeCount: Int = 0
    private var timer: Timer?

    private static let maxItems = 3
    private static let perItemCharCap = 500
    private static let totalCharCap = 1500

    /// Apps where copy events are typically credentials or other secrets.
    /// We skip capture entirely while one of these is the frontmost app.
    private static let captureBlocklist: Set<String> = [
        "com.1password.1password",            // 1Password 8
        "com.1password.1password-launcher",
        "com.1password7",                      // 1Password 7 legacy
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
    ]

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Snapshot of the current items, clipped to the per-item / total caps so
    /// callers don't have to reapply the limits.
    func snapshot() -> [String] {
        var capped: [String] = []
        var total = 0
        for raw in items {
            let item = trimToTail(raw, max: Self.perItemCharCap)
            if total + item.count > Self.totalCharCap { break }
            capped.append(item)
            total += item.count
        }
        return capped
    }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Skip our own paste-based insertion (TextInserter.insertViaClipboard):
        // it transiently puts the inserted text on the clipboard, tagged with a
        // private marker type. Capturing it would pollute the user's clipboard
        // history and churn the `clipboard` context section — invalidating the KV
        // cache on every accept.
        if NSPasteboard.general.data(forType: .flowinSelfPaste) != nil {
            return
        }

        // Drop entirely if a password manager is frontmost — this also catches
        // the "user copied from 1Password and immediately switched apps" case
        // so long as we read changeCount before the switch.
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.captureBlocklist.contains(bundleID) {
            return
        }

        guard let str = NSPasteboard.general.string(forType: .string),
              !str.isEmpty,
              !looksSensitive(str) else {
            // No usable text on the clipboard — fall back to OCR'ing a bitmap
            // image (screenshot / "Copy Image") if one is present. OCR runs off
            // the main actor; the recognized text is filtered and recorded just
            // like a text item.
            if let image = Self.readClipboardImage() {
                Task { @MainActor [weak self] in
                    let text = await OCREngine.recognizeText(in: image)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self, !trimmed.isEmpty, !looksSensitive(trimmed) else { return }
                    self.record(trimmed)
                    Log.debug("Clipboard image OCR: recorded \(trimmed.count) chars")
                }
            }
            return
        }

        record(str)
    }

    /// Dedupe, insert most-recent-first, and cap to `maxItems`. Shared by the
    /// text and image-OCR capture paths.
    private func record(_ text: String) {
        items.removeAll { $0 == text }      // dedupe
        items.insert(text, at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
    }

    /// Reads a bitmap image off the general pasteboard as a `CGImage`, or nil if
    /// the clipboard has no raw image data. Restricted to `.png`/`.tiff` so
    /// copied files (file-URLs) and other non-bitmap types never trigger OCR.
    private static func readClipboardImage() -> CGImage? {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return rep.cgImage
    }

    /// Long pastes (e.g. a captured email body) are tail-trimmed: a paste's
    /// head usually has framing that's already in screen context, but the tail
    /// is what the user just yanked.
    private func trimToTail(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.suffix(max))
    }
}

// MARK: - Sensitive content heuristics

/// Returns true if the string looks like a credential or secret token. False
/// positives are acceptable (we just skip capturing); the bar is "obvious
/// secrets shouldn't end up in cloud requests."
func looksSensitive(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    // Single-line tokens only — multi-line text rarely matches a secret pattern.
    let oneLine = !trimmed.contains("\n")

    if oneLine {
        for pattern in Self_secretPrefixes where trimmed.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
    }

    // Entropy heuristic: a contiguous high-entropy token of 20–100 chars with
    // no whitespace and a mix of cases/digits/symbols looks like an API key
    // even if it doesn't match a known prefix.
    if oneLine, trimmed.count >= 20, trimmed.count <= 100 {
        var hasUpper = false, hasLower = false, hasDigit = false, hasSym = false
        for ch in trimmed {
            if ch.isUppercase { hasUpper = true }
            else if ch.isLowercase { hasLower = true }
            else if ch.isNumber { hasDigit = true }
            else if ch.isPunctuation || ch.isSymbol { hasSym = true }
        }
        let mixCount = [hasUpper, hasLower, hasDigit, hasSym].filter { $0 }.count
        // 3+ classes + no whitespace + no English-word ratio = likely a token.
        if mixCount >= 3, !trimmed.contains(where: { $0.isWhitespace }) {
            // Reject if it looks like normal-case prose punctuation
            // ("Hello-World." has 3 classes but is clearly text).
            let wordlikeChunks = trimmed.split(whereSeparator: { !$0.isLetter })
                .filter { $0.count >= 4 }
                .count
            if wordlikeChunks <= 1 {
                return true
            }
        }
    }

    return false
}

// gitleaks-derived prefixes, narrowed to the most common ones. Kept private
// to this file; the file-private name avoids collisions with any future
// secret-scanner module.
private let Self_secretPrefixes: [String] = [
    #"sk-[A-Za-z0-9_-]{20,}"#,                          // OpenAI / Anthropic
    #"sk-ant-[A-Za-z0-9_-]{20,}"#,                      // Anthropic explicit
    #"sk_(live|test)_[A-Za-z0-9]{20,}"#,                // Stripe
    #"pk_(live|test)_[A-Za-z0-9]{20,}"#,                // Stripe publishable
    #"ghp_[A-Za-z0-9]{36,}"#,                           // GitHub personal token
    #"gho_[A-Za-z0-9]{36,}"#,                           // GitHub OAuth
    #"ghu_[A-Za-z0-9]{36,}"#,                           // GitHub user-to-server
    #"ghs_[A-Za-z0-9]{36,}"#,                           // GitHub server-to-server
    #"github_pat_[A-Za-z0-9_]{60,}"#,                   // GitHub fine-grained PAT
    #"xox[baprs]-[A-Za-z0-9-]{10,}"#,                   // Slack tokens
    #"AKIA[A-Z0-9]{16}"#,                               // AWS access key
    #"ASIA[A-Z0-9]{16}"#,                               // AWS temp access key
    #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, // JWT
    #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{20,}"#,           // Bearer <token>
    #"(?i)password\s*[:=]\s*\S{6,}"#,                   // password = ...
    #"(?i)api[_-]?key\s*[:=]\s*\S{10,}"#,               // api_key = ...
]
