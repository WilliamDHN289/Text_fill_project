import Foundation
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenContextManager {
    private(set) var currentContext: String?
    private(set) var currentAppBundleId: String?
    private var lastWindowTitle: String?
    private var needsRecapture = false
    private var isCapturing = false
    private let settings: SettingsManager

    /// Called when screen context becomes available after being nil (e.g., first OCR completes).
    var onContextReady: (() -> Void)?

    init(settings: SettingsManager) {
        self.settings = settings
    }

    /// Called by Engine on every suggestion request. Triggers async capture if needed.
    func captureIfNeeded(pid: pid_t, appBundleId: String, inputBandFrame: CGRect, windowTitle: String = "") {
        guard settings.isScreenContextEnabled else { return }

        let appChanged = appBundleId != currentAppBundleId
        if appChanged {
            Log.debug("[ScreenContext] App changed: '\(currentAppBundleId ?? "nil")' → '\(appBundleId)' — invalidating")
            currentAppBundleId = appBundleId
            currentContext = nil
            needsRecapture = true
        }

        // Detect conversation switch: window title changed within the same app
        if !appChanged, let lastTitle = lastWindowTitle, !lastTitle.isEmpty,
           !windowTitle.isEmpty, windowTitle != lastTitle {
            Log.debug("[ScreenContext] Window title changed: '\(lastTitle.prefix(30))' → '\(windowTitle.prefix(30))' — invalidating")
            currentContext = nil
            needsRecapture = true
        }

        guard needsRecapture || appChanged else { return }
        if isCapturing {
            Log.debug("[ScreenContext] Skipped: previous capture still in flight (needsRecapture=\(needsRecapture) appChanged=\(appChanged))")
            return
        }
        needsRecapture = false
        lastWindowTitle = windowTitle
        performCapture(pid: pid, inputBandFrame: inputBandFrame, appBundleId: appBundleId)
    }

    /// Recapture screen context when user clicks into an empty text field (likely a conversation switch).
    func onClickDetected(pid: pid_t, appBundleId: String, inputBandFrame: CGRect, windowTitle: String) {
        guard settings.isScreenContextEnabled else { return }
        guard !isCapturing else { return }
        Log.debug("[ScreenContext] Click into empty text field — recapturing")
        // Do NOT nil currentContext here: performCapture compares new OCR against the
        // real previous context, so onContextReady fires only on a genuine change. (Nilling
        // made OCRSimilarity.contextChanged(nil,_) always true → fired every recapture.)
        lastWindowTitle = windowTitle
        performCapture(pid: pid, inputBandFrame: inputBandFrame, appBundleId: appBundleId)
    }

    /// Mark that a recapture is needed (e.g., user pressed Return to send a message).
    func onReturnPressed() {
        guard settings.isScreenContextEnabled else { return }
        needsRecapture = true
    }

    /// User just typed the first character in a previously-empty field.
    /// Strong signal of either a new conversation (sidebar switch in apps with
    /// stable window titles — WhatsApp, iMessage, Telegram) or a fresh draft
    /// in the same one. Force-recapture so the new OCR can be compared with
    /// the current snapshot; Jaccard decides whether to fire onContextReady.
    func onFirstCharTyped(pid: pid_t, appBundleId: String, inputBandFrame: CGRect, windowTitle: String) {
        guard settings.isScreenContextEnabled else { return }
        guard !isCapturing else {
            Log.debug("[ScreenContext] First-char trigger skipped: capture still in flight")
            return
        }
        Log.debug("[ScreenContext] First char in empty field — recapturing")
        lastWindowTitle = windowTitle
        performCapture(pid: pid, inputBandFrame: inputBandFrame, appBundleId: appBundleId)
    }

    /// Force a fresh capture and return the recognized conversation text
    /// (or nil if empty). Unlike `captureIfNeeded`, this always runs and
    /// awaits the result — used by reply drafting, which needs the latest
    /// on-screen conversation at the moment the hotkey is pressed.
    func captureNow(pid: pid_t, appBundleId: String, inputBandFrame: CGRect, windowTitle: String = "") async -> String? {
        let text = await Self.runCapturePipeline(pid: pid, inputBandFrame: inputBandFrame, appBundleId: appBundleId)
        let result = text.isEmpty ? nil : text
        self.currentContext = result
        if result != nil { self.currentAppBundleId = appBundleId }
        return result
    }

    /// Clear context (e.g., when feature is disabled).
    func invalidate() {
        currentContext = nil
        currentAppBundleId = nil
        lastWindowTitle = nil
        needsRecapture = false
    }

    // MARK: - Private

    private func performCapture(pid: pid_t, inputBandFrame: CGRect, appBundleId: String) {
        isCapturing = true

        Task {
            let text = await Self.runCapturePipeline(pid: pid, inputBandFrame: inputBandFrame, appBundleId: appBundleId)
            let previousContext = self.currentContext
            self.currentContext = text.isEmpty ? nil : text
            if !text.isEmpty {
                // Claim ownership of the fresh context. captureIfNeeded's
                // app-change check compares against currentAppBundleId, and a
                // click/focus-triggered capture bypasses captureIfNeeded — so
                // without this update the PREVIOUS app stays recorded and the
                // first keystroke "discovers" an app change, invalidating the
                // screen context just captured (and possibly prefill-warmed)
                // for the new app. On failure keep the old value: the stale-id
                // mismatch is exactly what makes captureIfNeeded retry on the
                // next request.
                self.currentAppBundleId = appBundleId
            }
            self.isCapturing = false

            // Fire only when the new context is meaningfully different. Vision OCR
            // jitter (one glyph flipped, slightly different line splits) would
            // otherwise cause constant re-fires on a static screen.
            if OCRSimilarity.contextChanged(old: previousContext, new: self.currentContext) {
                Log.debug("[ScreenContext] context changed → onContextReady")
                self.onContextReady?()
            }
        }
    }

    /// Runs capture + crop + OCR off the main actor. All inputs are value types.
    private nonisolated static func runCapturePipeline(pid: pid_t, inputBandFrame: CGRect, appBundleId: String) async -> String {
        let start = CFAbsoluteTimeGetCurrent()

        guard let windowImage = WindowCapturer.capture(pid: pid) else { return "" }
        let captureMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let windowFrame = WindowCapturer.windowBounds(forPid: pid)
        if let wf = windowFrame {
            let relativeY = inputBandFrame.origin.y - wf.origin.y
            if relativeY < 100 || inputBandFrame.origin.y < wf.origin.y || inputBandFrame.maxX < wf.minX || inputBandFrame.minX > wf.maxX {
                Log.debug("[ScreenContext] anomalous geometry: imageSize=\(windowImage.width)x\(windowImage.height) windowFrame=\(wf) inputBandFrame=\(inputBandFrame) relativeY=\(relativeY)")
            }
        }
        let croppedImage: CGImage?
        if let wf = windowFrame {
            croppedImage = ImageCropper.cropAboveInput(
                image: windowImage,
                inputBandFrame: inputBandFrame,
                windowFrame: wf
            )
        } else {
            croppedImage = windowImage
        }

        guard let finalImage = croppedImage else { return "" }

        // Save debug screenshot (development only)
        var saveMs: Double = 0
        #if DEBUG
        let saveStart = CFAbsoluteTimeGetCurrent()
        saveDebugImage(finalImage)
        saveMs = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
        #endif

        let ocrStart = CFAbsoluteTimeGetCurrent()
        let lines = await OCREngine.recognizeLines(in: finalImage)
        let ocrMs = (CFAbsoluteTimeGetCurrent() - ocrStart) * 1000

        // WeChat SPIKE: WeChat gives no AX geometry, so we capture the full window and
        // drop the left conversation-list column here. We also tag each line with its
        // bubble color (green = self) sampled from the screenshot — Attribution uses it
        // for a robust me/other split that geometry alone gets wrong on wide bubbles.
        let usableLines: [OCRLine]
        if appBundleId == "com.tencent.xinWeChat" {
            let tagged = lines.map {
                OCRLine(text: $0.text, bbox: $0.bbox,
                        bubbleIsGreen: bubbleIsGreen(in: finalImage, normBBox: $0.bbox))
            }
            usableLines = weChatChatColumnOnly(tagged)
        } else {
            usableLines = lines
        }

        let style = AttributionStyle.forBundle(appBundleId)
        let text = Attribution.format(lines: usableLines, style: style)

        let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Log.debug("[ScreenContext] screenshot: \(Int(captureMs))ms | save: \(Int(saveMs))ms | OCR: \(Int(ocrMs))ms | total: \(Int(totalMs))ms (\(text.count) chars, style=\(style))")
        let raw = usableLines.map { $0.text }.joined(separator: "\n")
        Log.debug("[ScreenContext OCR]\n\(raw.isEmpty ? "(empty)" : raw)\n[/ScreenContext OCR]")
        if case .bubbleAligned = style {
            Log.debug("[ScreenContext Attributed]\n\(text.isEmpty ? "(empty)" : text)\n[/ScreenContext Attributed]")
        }
        return text
    }

    /// WeChat SPIKE — keep only the chat column, dropping the left conversation-list
    /// sidebar. Each sidebar row carries a right-aligned timestamp (23:48 / 06/06 /
    /// Sunday / Yesterday / 昨天 …); together they form a vertical column at the
    /// sidebar's right edge. The MEDIAN of those timestamps' right edges (maxX) marks
    /// the sidebar↔chat boundary — resize-robust (the column moves with the sidebar)
    /// and stable against the few centered chat timestamps (median ignores outliers).
    /// Keeps lines whose center is to its right. Falls back to all lines if too few
    /// timestamps are found. WeChat-only; remove with the spike.
    private nonisolated static func weChatChatColumnOnly(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count >= 4 else { return lines }

        func looksLikeTimestamp(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true }
            if t.range(of: #"\d{1,2}/\d{1,2}"#, options: .regularExpression) != nil { return true }
            // Prefixes ("Yester", "Toda") catch truncated forms — a narrow sidebar shows "Yester…".
            let markers = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
                           "Yester", "Today", "Toda", "昨天", "今天", "星期", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            return markers.contains { t.contains($0) }
        }

        func splitAt(_ divider: CGFloat, _ why: String) -> [OCRLine] {
            let kept = lines.filter { $0.bbox.midX > divider }
            Log.debug("[WeChatSpike] x-filter: \(why) divider=\(String(format: "%.2f", divider)) kept \(kept.count)/\(lines.count)")
            guard kept.count >= 2 else { return lines }
            // OCR ran on the FULL window, so kept bboxes are full-window-normalized — every
            // chat bubble reads too far right, breaking Attribution's chat-relative Me/Friend
            // split (0.45/0.55). Re-normalize x into the chat area [divider, 1] so that split
            // works unchanged. (A fixed threshold can't: `divider` moves with sidebar width.)
            let scale = 1 - divider
            guard scale > 0.05 else { return kept }
            return kept.map { line in
                let b = line.bbox
                return OCRLine(text: line.text,
                               bbox: CGRect(x: (b.minX - divider) / scale, y: b.minY,
                                            width: b.width / scale, height: b.height),
                               bubbleIsGreen: line.bubbleIsGreen)
            }
        }

        // Primary: each sidebar row's right-aligned timestamp forms a vertical column;
        // the median of their right edges is the sidebar↔chat boundary. Resize-following.
        let stampX = lines.filter { looksLikeTimestamp($0.text) }.map { $0.bbox.maxX }.sorted()
        if stampX.count >= 3 {
            let d = stampX[stampX.count / 2]
            let list = stampX.map { String(format: "%.2f", $0) }.joined(separator: " ")
            // Guard: the chat's centered time-separators ("Yesterday 23:39") also match the
            // timestamp pattern. If the sidebar stamps OCR poorly and only separators are
            // found, the median lands deep in the chat (> ~0.65) and over-crops. A real
            // sidebar boundary never gets that far right (chat would be <35%), so reject it
            // and fall through to the gap method.
            if d <= 0.65 {
                return splitAt(d, "stampMaxX=[\(list)]")
            }
            Log.debug("[WeChatSpike] x-filter: stamp divider=\(String(format: "%.2f", d)) >0.65 (chat separators?) — trying gap; stampMaxX=[\(list)]")
        }

        // Fallback (narrow sidebar truncates timestamps so none match): the sidebar is a
        // thin left column, leaving a clean center gap before the chat. Take the largest
        // midX gap whose midpoint is left-of-center (avoids the right-aligned-bubble gap).
        let mids = lines.map { $0.bbox.midX }.sorted()
        var splitX: CGFloat = -1, bestGap: CGFloat = 0
        for i in 1..<mids.count {
            let mid = (mids[i - 1] + mids[i]) / 2
            guard mid >= 0.10, mid <= 0.60 else { continue }
            if mids[i] - mids[i - 1] > bestGap { bestGap = mids[i] - mids[i - 1]; splitX = mid }
        }
        guard splitX > 0, bestGap >= 0.05 else {
            Log.debug("[WeChatSpike] x-filter: \(stampX.count) stamps, no left gap — keeping all \(lines.count)")
            return lines
        }
        return splitAt(splitX, "gap=\(String(format: "%.2f", bestGap))")
    }

    /// WeChat SPIKE — does the bubble behind this text region read as WeChat's self-green?
    /// Samples a grid of pixels across the text bbox (plus a little vertical padding, which
    /// is pure bubble fill) of the ORIGINAL screenshot and reports whether green-dominant
    /// pixels are common. Tests green DOMINANCE (G clearly above R and B), not a fixed RGB,
    /// so it works in both light (pastel green vs white) and dark (saturated green vs gray)
    /// mode. The green channel is the middle byte for both RGBA and BGRA and we compare it
    /// to both neighbors, so this is byte-order-agnostic. nil if the image can't be read.
    /// WeChat-only; remove with the spike.
    private nonisolated static func bubbleIsGreen(in image: CGImage, normBBox: CGRect) -> Bool? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8
        let bpr = image.bytesPerRow
        guard bpp >= 3, image.width > 0, image.height > 0 else { return nil }
        let W = image.width, H = image.height
        let pad = Int(normBBox.height * CGFloat(H) * 0.4)   // reach into the bubble's vertical padding
        let x0 = max(0, Int(normBBox.minX * CGFloat(W)))
        let x1 = min(W - 1, Int(normBBox.maxX * CGFloat(W)))
        let y0 = max(0, Int(normBBox.minY * CGFloat(H)) - pad)
        let y1 = min(H - 1, Int(normBBox.maxY * CGFloat(H)) + pad)
        guard x1 > x0, y1 > y0 else { return nil }
        let stepX = max(1, (x1 - x0) / 24)
        let stepY = max(1, (y1 - y0) / 16)
        var green = 0, total = 0
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let off = y * bpr + x * bpp
                let g = Int(ptr[off + 1]), c0 = Int(ptr[off]), c2 = Int(ptr[off + 2])
                if g - c0 > 25 && g - c2 > 25 { green += 1 }
                total += 1
                x += stepX
            }
            y += stepY
        }
        guard total > 0 else { return nil }
        return Double(green) / Double(total) >= 0.18
    }

    /// Save the cropped image to disk for debugging
    private nonisolated static func saveDebugImage(_ image: CGImage) {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "screenshot-\(timestamp).png"
        let directory = "/Users/leojing/Documents/autocomplete debug screenshots"
        let path = "\(directory)/\(filename)"
        
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            Log.debug("Failed to create image destination")
            return
        }
        
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            Log.debug("Saved debug screenshot: \(filename)")
        } else {
            Log.debug("Failed to save debug screenshot")
        }
    }
}
