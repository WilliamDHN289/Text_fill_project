import Foundation
import CoreGraphics

/// How sender attribution should be applied to OCR output for a given app.
enum AttributionStyle {
    /// Bubble-aligned chat UI: sender is determined by horizontal position
    /// of each message block (right = me, left = other). The OCR text alone
    /// does not contain sender labels for "me".
    case bubbleAligned

    /// Author-prefixed UI: every message in the OCR text is already preceded
    /// by the sender's name (Slack, Discord, Teams). No bbox attribution needed.
    case textPrefixed

    /// Unknown / not a chat surface. Pass OCR through unchanged.
    case unknown

    static func forBundle(_ bundleId: String) -> AttributionStyle {
        switch bundleId {
        case "com.apple.MobileSMS",
             "com.tencent.xinWeChat",
             "net.whatsapp.WhatsApp",
             "ru.keepcoder.Telegram",
             "org.whispersystems.signal-desktop":
            return .bubbleAligned
        case "com.tinyspeck.slackmacgap",
             "com.hnc.Discord",
             "com.microsoft.teams2":
            return .textPrefixed
        default:
            return .unknown
        }
    }
}

enum Attribution {
    /// Convert structured OCR lines into a prompt-ready string. For bubble-aligned
    /// apps, message blocks are labeled `Me:` / `Friend:` / `[System]:` based on
    /// horizontal position within the cropped chat area. For other styles, lines
    /// are joined top-to-bottom unchanged.
    static func format(lines: [OCRLine], style: AttributionStyle) -> String {
        switch style {
        case .bubbleAligned:
            return formatBubbleAligned(lines: lines)
        case .textPrefixed, .unknown:
            return lines.map { $0.text }.joined(separator: "\n")
        }
    }

    // MARK: - Bubble-aligned

    private enum Sender { case me, other, system }

    private struct Block {
        let sender: Sender
        let text: String
    }

    private static func formatBubbleAligned(lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let blocks = clusterIntoBlocks(lines)
        guard let titleBlock = blocks.first else { return "" }

        // First block is almost always the conversation title bar (group/contact
        // name + menu icons), not a message. Emit it raw so it doesn't get
        // mis-attributed as Me/Friend/[System].
        var out: [String] = [titleBlock.text]
        for block in blocks.dropFirst() {
            let prefix: String
            switch block.sender {
            case .me:     prefix = "Me: "
            case .other:  prefix = "Friend: "
            case .system: prefix = "[System]: "
            }
            out.append(prefix + block.text)
        }
        return out.joined(separator: "\n")
    }

    /// Group adjacent OCR lines into message blocks by vertical proximity.
    /// Two lines belong to the same block when their vertical gap is less
    /// than 60% of the prior line's height — wraps within a single bubble
    /// stay attached, gaps between bubbles split.
    private static func clusterIntoBlocks(_ lines: [OCRLine]) -> [Block] {
        let sorted = lines.sorted { $0.bbox.minY < $1.bbox.minY }
        var blocks: [Block] = []
        var current: [OCRLine] = []

        for line in sorted {
            if let last = current.last {
                let gap = line.bbox.minY - last.bbox.maxY
                if gap < last.bbox.height * 0.6 {
                    current.append(line)
                    continue
                }
                blocks.append(makeBlock(current))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty {
            blocks.append(makeBlock(current))
        }
        return blocks
    }

    /// Compute a block's sender from which side its bubble HUGS, using the block's
    /// outer edges (not its center). A long/wrapped message has a center that drifts
    /// toward the middle, so center-based attribution mislabels wide bubbles; the edge
    /// a bubble hugs is invariant to width. Coordinates are normalized 0–1 relative to
    /// the chat area: a right-aligned (me) bubble's right edge sits near 1, a left-
    /// aligned (friend) bubble's left edge sits near 0, and a centered system line
    /// (timestamp / notice) has roughly equal margins on both sides.
    private static func makeBlock(_ lines: [OCRLine]) -> Block {
        let text = lines.map { $0.text }.joined(separator: " ")
        let leftMargin = lines.map { $0.bbox.minX }.min() ?? 0          // gap from chat-left
        let rightMargin = 1 - (lines.map { $0.bbox.maxX }.max() ?? 1)   // gap from chat-right
        // System detection (unchanged): a centered timestamp/notice hugs NEITHER side, so
        // both margins are large. Everything else is a real message (it hugs a side).
        let sender: Sender
        if min(leftMargin, rightMargin) <= 0.25 {
            // It's a message. Prefer the bubble COLOR (WeChat: green = self) — robust to
            // wide bubbles, which geometry mislabels. Fall back to geometry (smaller margin
            // = hugged side) when color is unsampled (non-WeChat).
            if let green = blockIsGreen(lines) {
                sender = green ? .me : .other
                Log.debug("[WeChatColor] \(green ? "me" : "friend") '\(text.prefix(12))'")
            } else {
                sender = rightMargin < leftMargin ? .me : .other
            }
        } else {
            sender = .system   // neither side hugged → centered timestamp / notice
        }
        return Block(sender: sender, text: text)
    }

    /// Majority vote of the block's lines' sampled bubble color (WeChat only). Returns
    /// nil when no line was sampled (non-WeChat) so the caller falls back to geometry.
    private static func blockIsGreen(_ lines: [OCRLine]) -> Bool? {
        let votes = lines.compactMap { $0.bubbleIsGreen }
        guard !votes.isEmpty else { return nil }
        return votes.filter { $0 }.count * 2 >= votes.count
    }
}
