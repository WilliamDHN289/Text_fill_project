import AppKit
import Foundation

/// Global ring buffer of the last 3 messages the user appears to have sent —
/// detected by a Return keystroke followed within ~250 ms by either the
/// focused field clearing (chat send) or the focused app switching (user
/// moved on after sending). Each entry includes the screen context that was
/// available at submit time so the model sees recent outgoing messages with
/// their original surrounding context, not the current screen state.
///
/// In-memory only; lost on app restart. Captured by `Engine` and snapshotted
/// when building cloud + local prompts. Mirrors `ClipboardHistory`'s shape.
@MainActor
final class MessageHistory {
    struct SentMessage {
        let text: String
        let screenContext: String?
        let appName: String
        let windowTitle: String
        let timestamp: Date
    }

    private(set) var items: [SentMessage] = []

    /// Fired after a new message is actually committed to the buffer — NOT on
    /// dedup-skips (①), which leave the history unchanged. Callers can't tell
    /// from outside whether record() changed anything, so the commit point
    /// itself signals. Engine uses this to warm the local KV cache with the
    /// updated history during the natural post-send pause.
    var onRecord: (() -> Void)?

    private static let maxItems = 3
    /// Per-component (prefix OR suffix) char cap applied at capture time.
    /// Combined captured text can be up to 2× this value. Prefix is sliced
    /// to its tail (last N chars — the most recent typing); suffix is sliced
    /// to its head (first N chars — what's right after the cursor).
    static let perComponentCharCap = 1000
    /// Total char cap applied at snapshot time, so the prompt never gets
    /// flooded by three near-cap items.
    private static let totalCharCap = 3000

    /// Build the stored text from a captured field's prefix + suffix.
    /// - Each component is normalized (`TextNormalize.collapseToSingleLine`)
    ///   first so caps apply to dense content, not whitespace bloat.
    /// - Prefix is sliced to its TAIL (`.suffix(cap)`) — the most recent
    ///   typing is what matters; if the user typed a 5k-char draft, we keep
    ///   the last 1000 chars.
    /// - Suffix is sliced to its HEAD (`.prefix(cap)`) — the text right
    ///   after the cursor (e.g., quoted email history's first lines) is
    ///   more relevant than what's far below.
    /// - Joined with a single space if both halves non-empty so the prefix
    ///   and suffix don't fuse into a single word.
    static func captureText(prefix: String, suffix: String) -> String {
        let p = String(TextNormalize.collapseToSingleLine(prefix).suffix(perComponentCharCap))
        let s = String(TextNormalize.collapseToSingleLine(suffix).prefix(perComponentCharCap))
        return [p, s].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func record(_ message: SentMessage) {
        // Log buffer state on every record call (skip or insert) so the
        // capture pipeline's correctness can be eyeballed from logs.
        defer { logState() }

        // ① Skip if some existing entry already covers this text — either an
        //    exact duplicate or a longer superset. The capture path fires on
        //    every transition (app/window/empty-field), so without this we'd
        //    pile up shorter prefixes of the same in-progress draft as the
        //    user keeps typing.
        if items.contains(where: { $0.text.hasPrefix(message.text) }) {
            Log.debug("[MsgHistory] record skipped (already covered by longer entry): '\(message.text)'")
            return
        }
        // ② If the new message is a strict superset of any existing entries
        //    (user kept typing past what we previously captured), drop the
        //    shorter ones — the new entry replaces them.
        let removed = items.filter { message.text.hasPrefix($0.text) }
        items.removeAll(where: { message.text.hasPrefix($0.text) })
        if !removed.isEmpty {
            Log.debug("[MsgHistory] record replaced \(removed.count) shorter entry(ies) — new is superset")
        }
        // ③ Insert at front; evict oldest beyond `maxItems`.
        items.insert(message, at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
        onRecord?()
    }

    private func logState() {
        if items.isEmpty {
            Log.debug("[MsgHistory] buffer: (empty)")
            return
        }
        var lines = ["[MsgHistory] buffer: \(items.count) item(s)"]
        for (i, item) in items.enumerated() {
            lines.append("  [\(i)] (\(item.text.count) chars, app=\(item.appName)): '\(item.text)'")
        }
        Log.debug(lines.joined(separator: "\n"))
    }

    /// Snapshot of items, applying the total char cap so callers don't have
    /// to track it themselves. Per-item cap is already enforced at record().
    func snapshot() -> [SentMessage] {
        var out: [SentMessage] = []
        var total = 0
        for item in items {
            if total + item.text.count > Self.totalCharCap { break }
            out.append(item)
            total += item.text.count
        }
        return out
    }
}
