import AppKit

/// Custom view that uses NSLayoutManager for pixel-precise text rendering.
/// Zero internal padding — glyphs render exactly at the specified offset.
private class GhostTextView: NSView {
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()

    /// Vertical offset to shift text within the view (for centering within caret rect)
    var textOriginY: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setAttributedText(_ attrStr: NSAttributedString, maxWidth: CGFloat) {
        textContainer.size = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        textStorage.setAttributedString(attrStr)
        layoutManager.ensureLayout(for: textContainer)
        needsDisplay = true
    }

    func textSize() -> NSSize {
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: ceil(usedRect.width), height: ceil(usedRect.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: NSPoint(x: 0, y: textOriginY))
    }
}

@MainActor
final class SuggestionPanel {
    private let panel: NSPanel
    private let ghostView: GhostTextView
    private var currentFont: NSFont = .systemFont(ofSize: 14)

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: 200)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]
        panel.hidesOnDeactivate = false

        ghostView = GhostTextView()
        ghostView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(ghostView)
        NSLayoutConstraint.activate([
            ghostView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            ghostView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ghostView.topAnchor.constraint(equalTo: contentView.topAnchor),
            ghostView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        panel.contentView = contentView
    }

    /// Cached state for `update` to reuse positioning info
    private var lastElementFrame: CGRect = .zero
    private var lastCaretRect: CGRect = .zero

    func show(text: String, at caretRect: CGRect, elementFrame: CGRect = .zero, font: NSFont?, currentLinePrefix: String = "", textAreaLeftEdge: CGFloat? = nil, focusedAppBundleId: String? = nil) {
        showingIntent = true
        visibilityIntentGen += 1
        let displayFont = font ?? .systemFont(ofSize: 14)
        currentFont = displayFont
        lastElementFrame = elementFrame
        lastCaretRect = caretRect

        // Use primary screen height for AX→AppKit Y conversion (AX origin = top-left of primary screen)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        // Find the screen containing the caret for clamping bounds
        let caretAppKitPoint = NSPoint(x: caretRect.origin.x, y: primaryScreenHeight - caretRect.origin.y)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(caretAppKitPoint) })?.frame
            ?? NSScreen.main?.frame ?? .zero
        let caretX = caretRect.origin.x + caretRect.width

        // Terminal emulators draw a block cursor (one cell wide) at the next-char
        // position — which is exactly where ghost text begins. We align the first
        // ghost glyph's left edge to the cursor cell's left edge, so the block
        // cursor sits *on* the first ghost character (fish-shell / inline-suggestion
        // style — the alignment users expect from Cotypist et al.).
        //
        // caretRect.origin.x is that left edge (correctTerminalCaretX derives it
        // geometrically from the line's display-column span). For non-terminal
        // hosts the caret is a thin I-beam, so we anchor to its right edge
        // (origin.x + width) instead — behavior there is unchanged.
        // Prefer the AX-detected app's bundle ID over NSWorkspace.frontmostApplication.
        // Non-activating overlays (ChatGPT Option+Space, Spotlight-like panels)
        // accept text input without becoming frontmost, so frontmostApplication
        // returns the underlying app (often a terminal in dev) — which would
        // wrongly apply the block-cursor alignment and mis-place ghost text.
        // Callers pass the AX bundle ID; fall back to frontmostApplication only
        // when unavailable.
        let focusedBundleId = focusedAppBundleId
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? ""
        let isBlockCursorHost = InsertionRouting.isCursorBlockHost(focusedBundleId)

        // Determine panel X origin and width
        var panelX: CGFloat
        var panelWidth: CGFloat
        var firstLineIndent: CGFloat = 0
        var headIndent: CGFloat = 0

        if elementFrame.width > 0 {
            // Panel spans from element's left edge to element's right edge
            let elementLeftEdge = elementFrame.origin.x
            let elementRightEdge = elementFrame.origin.x + elementFrame.width
            panelX = elementLeftEdge
            panelWidth = min(elementRightEdge - elementLeftEdge, screenFrame.maxX - elementLeftEdge - 10)
            // First line starts at the caret. Block-cursor hosts align to the
            // cursor cell's left edge (origin.x); I-beam hosts start just past
            // the thin caret (origin.x + width, +1).
            firstLineIndent = isBlockCursorHost
                ? max(0, caretRect.origin.x - elementLeftEdge)
                : max(0, caretX - elementLeftEdge + 1)

            // Compute headIndent: where wrapped ghost text lines should start.
            if let textLeftEdge = textAreaLeftEdge {
                // AX-based: exact left edge from AXLineForIndex/AXRangeForLine/AXBoundsForRange
                headIndent = max(0, textLeftEdge - elementLeftEdge)
                Log.debug("[HeadIndent] AX-based: textLeftEdge=\(Int(textLeftEdge)) elemLeft=\(Int(elementLeftEdge)) headIndent=\(Int(headIndent)) firstLineIndent=\(Int(firstLineIndent))")
            } else if !currentLinePrefix.isEmpty {
                // Fallback: measure visual line prefix width with NSLayoutManager
                let visualLineWidth = measureLastVisualLineWidth(
                    text: currentLinePrefix, font: displayFont, wrapWidth: panelWidth
                )
                headIndent = max(0, caretX - visualLineWidth - elementLeftEdge)
                Log.debug("[HeadIndent] prefix-based: caretX=\(Int(caretX)) elemLeft=\(Int(elementLeftEdge)) panelW=\(Int(panelWidth)) visualLineW=\(Int(visualLineWidth)) headIndent=\(Int(headIndent)) firstLineIndent=\(Int(firstLineIndent))")
            }
        } else {
            // No element frame — fall back to caret-anchored layout
            panelX = caretX + 1
            panelWidth = min(600, screenFrame.maxX - caretX - 20)
        }

        panelWidth = max(panelWidth, 100)

        // Build attributed string with first-line indent
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.firstLineHeadIndent = firstLineIndent
        paraStyle.headIndent = headIndent
        paraStyle.lineBreakMode = .byWordWrapping

        currentFirstLineIndent = firstLineIndent
        currentHeadIndent = headIndent

        // Determine display text — truncate if it would overflow the element frame
        let availableHeight: CGFloat? = elementFrame.height > 0
            ? elementFrame.origin.y + elementFrame.height - caretRect.origin.y
            : nil
        let displayText = truncateToFit(
            text: text, font: displayFont, maxWidth: panelWidth,
            availableHeight: availableHeight,
            firstLineIndent: firstLineIndent, headIndent: headIndent
        )

        let attrStr = buildAttributedString(
            text: displayText, font: displayFont,
            firstLineIndent: firstLineIndent, headIndent: headIndent
        )
        ghostView.setAttributedText(attrStr, maxWidth: panelWidth)

        // Measure text size
        let textSize = ghostView.textSize()
        // When using firstLineIndent, always use full panelWidth so the indent
        // doesn't cause clipping. Only shrink-to-fit when there's no indent.
        let effectiveWidth: CGFloat = firstLineIndent > 0
            ? panelWidth + 4
            : min(textSize.width + 4, panelWidth + 4)

        // Offset text within the panel to align with the app's text baseline.
        let textLineHeight = textSize.height
        let fontLineHeight = displayFont.ascender + abs(displayFont.descender) + displayFont.leading
        let fontMetricOffset = (caretRect.height - fontLineHeight) / 2
        if textLineHeight <= caretRect.height {
            ghostView.textOriginY = (caretRect.height - textLineHeight) / 2
        } else {
            // Multi-line: use font metrics to match CSS half-leading model.
            // Cap at 2px — larger values indicate inaccurate font detection
            // or native apps with large line spacing (e.g. WeChat), where 0 works better.
            let clampedOffset = fontMetricOffset > 0 && fontMetricOffset <= 2.0 ? fontMetricOffset : 0
            ghostView.textOriginY = clampedOffset
        }

        // Panel top always matches caret top — prevents background band overlap.
        // Panel height accounts for text size plus any vertical offset to avoid clipping descenders.
        let panelHeight = max(caretRect.height, textSize.height + ghostView.textOriginY)
        let panelSize = NSSize(width: effectiveWidth, height: panelHeight)

        // Convert AX coordinates (top-left origin) to AppKit (bottom-left origin)
        let appKitY = primaryScreenHeight - caretRect.origin.y - caretRect.height

        // Panel top = caret top (in AppKit: origin.y + panelHeight = caretTop)
        let origin = NSPoint(
            x: panelX,
            y: appKitY + caretRect.height - panelHeight
        )

        // Ensure we don't go off-screen (use actual screen bounds for multi-monitor)
        let clampedX = min(max(screenFrame.minX, origin.x), screenFrame.maxX - panelSize.width - 10)
        let clampedY = max(screenFrame.minY + 10, origin.y)
        let finalOrigin = NSPoint(x: clampedX, y: clampedY)

        let finalFrame = NSRect(origin: finalOrigin, size: panelSize)
        Log.debug("SuggestionPanel: panelW=\(Int(panelWidth)) indent=\(Int(firstLineIndent)) panelSize=\(Int(panelSize.width))x\(Int(panelSize.height)) text='\(text.prefix(30))'")
        panel.setFrame(finalFrame, display: true)

        // Belt-and-suspenders for Space membership: re-toggle .canJoinAllSpaces
        // every show. The primary fix is keeping the panel permanently ordered
        // front (see hide()), which avoids the hide→orderOut→show cycle that
        // strips the flag. This toggle handles the residual case where idle /
        // display sleep alone still drops the flag from a long-lived panel.
        // Re-assigning the same set is a no-op, so [] → full is required.
        // Cost: two CGS metadata IPCs, sub-millisecond.
        panel.collectionBehavior = []
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]

        // Fade in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
        Log.info("SuggestionPanel.show: frame=\(panel.frame) level=\(panel.level.rawValue) isVisible=\(panel.isVisible) alpha=\(panel.alphaValue) isOnActiveSpace=\(panel.isOnActiveSpace) occlusionState=\(panel.occlusionState.rawValue)")

        // Post-fade sanity check: 250ms after show() (fade is 150ms, +100ms buffer),
        // re-log panel state. If alpha is still 0 here despite showingIntent==true,
        // the NSAnimationContext fade-in didn't commit — that's the invisible-ghost-text bug.
        let showGen = visibilityIntentGen
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.visibilityIntentGen == showGen else { return }
            Log.info("SuggestionPanel.postFade: alpha=\(self.panel.alphaValue) isVisible=\(self.panel.isVisible) isOnActiveSpace=\(self.panel.isOnActiveSpace) occlusionState=\(self.panel.occlusionState.rawValue) frame=\(self.panel.frame)")
        }
    }

    /// Update text in place, keeping the current panel position and indent.
    func update(text: String) {
        updateGhostText(text: text, indentOffset: 0)
    }

    /// Update after a partial word accept: advance the indent by the accepted text's width.
    func updateAfterPartialAccept(remainingText: String, acceptedText: String) {
        let acceptedWidth = (acceptedText as NSString).size(withAttributes: [.font: currentFont]).width
        currentFirstLineIndent += acceptedWidth
        updateGhostText(text: remainingText, indentOffset: 0)
    }

    private var currentFirstLineIndent: CGFloat = 0
    private var currentHeadIndent: CGFloat = 0

    /// Counter incremented on every `show()` and `hide()` call. Used by the
    /// post-fade sanity check to skip its log when the visibility intent has flipped.
    private var visibilityIntentGen: Int = 0

    /// Synchronous "should this panel be visible?" flag. Flips the instant
    /// `show()`/`hide()` is called, before the 150 ms fade-in / 100 ms fade-out
    /// animations complete. Decouples `isVisible` from animation progress so
    /// rapid hide→show or show→hide sequences (e.g., quick Left+Right arrow
    /// toggling) see consistent state and don't fall into the wrong branch
    /// of the keystroke state machine.
    private var showingIntent: Bool = false

    private func updateGhostText(text: String, indentOffset: CGFloat) {
        let indent = currentFirstLineIndent + indentOffset

        let attrStr = buildAttributedString(
            text: text, font: currentFont,
            firstLineIndent: indent, headIndent: currentHeadIndent
        )
        ghostView.setAttributedText(attrStr, maxWidth: panel.frame.width)

        let textSize = ghostView.textSize()
        var frame = panel.frame
        let oldTop = frame.origin.y + frame.size.height  // preserve top edge
        frame.size.width = max(frame.size.width, indent + 100) // keep panel wide enough
        frame.size.height = textSize.height
        frame.origin.y = oldTop - frame.size.height  // keep top fixed, adjust bottom
        panel.setFrame(frame, display: true)
    }

    /// Measure the width of the text on the last visual line after wrapping at `wrapWidth`.
    private func measureLastVisualLineWidth(text: String, font: NSFont, wrapWidth: CGFloat) -> CGFloat {
        let textStorage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return 0 }

        var lastLineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: &lastLineRange)

        let charRange = layoutManager.characterRange(forGlyphRange: lastLineRange, actualGlyphRange: nil)
        let lastLineText = (text as NSString).substring(with: charRange)
        return (lastLineText as NSString).size(withAttributes: [.font: font]).width
    }

    func hide() {
        showingIntent = false
        visibilityIntentGen += 1
        // Hide via alpha only — never call panel.orderOut(nil). The hide→orderOut→show
        // cycle is what causes macOS Window Server to drop .canJoinAllSpaces on the
        // borderless panel after long sessions / display sleep, stranding ghost text
        // on whichever Space the panel last appeared on. Logged evidence with the
        // earlier collectionBehavior []→full toggle alone: isOnActiveSpace=false /
        // occlusionState=8192 persisted at postFade. Keeping the panel ordered
        // front permanently (just transparent when "hidden") removes the trigger
        // entirely. Cost: panel stays in CGS window list, negligible memory; it's
        // .nonactivatingPanel + ignoresMouseEvents so it doesn't intercept input.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }
    }

    var isVisible: Bool {
        showingIntent
    }

    // MARK: - Attributed String

    /// Build attributed string with per-paragraph indent: first paragraph starts at caret,
    /// subsequent paragraphs (after \n) start at text area left edge.
    private func buildAttributedString(text: String, font: NSFont, firstLineIndent: CGFloat, headIndent: CGFloat) -> NSAttributedString {
        let paragraphs = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        let style = GhostTextStyle.current
        let totalChars = max(1, text.count)
        var charOffset = 0

        for (i, paragraph) in paragraphs.enumerated() {
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.headIndent = headIndent
            paraStyle.lineBreakMode = .byWordWrapping
            if i == 0 {
                paraStyle.firstLineHeadIndent = firstLineIndent
            } else {
                paraStyle.firstLineHeadIndent = headIndent
            }

            let content = i < paragraphs.count - 1 ? paragraph + "\n" : paragraph

            if style == .gray {
                let attrStr = NSAttributedString(string: content, attributes: [
                    .font: font,
                    .foregroundColor: style.color(at: 0),
                    .paragraphStyle: paraStyle,
                ])
                result.append(attrStr)
            } else {
                let paraAttr = NSMutableAttributedString(string: content, attributes: [
                    .font: font,
                    .paragraphStyle: paraStyle,
                ])
                for (j, _) in content.enumerated() {
                    let progress = CGFloat(charOffset + j) / CGFloat(totalChars)
                    let color = style.color(at: progress)
                    paraAttr.addAttribute(.foregroundColor, value: color, range: NSRange(location: j, length: 1))
                }
                result.append(paraAttr)
            }

            charOffset += content.count
        }
        return result
    }

    // MARK: - Text Truncation

    /// Truncate text to fit within the available height, breaking at natural boundaries.
    ///
    /// `extraLinesBelow` adds slack beyond the input element's bottom edge:
    /// the ghost text is allowed to overflow downward by this many rendered
    /// lines. Default 1 — visually, if the suggestion wraps past the input
    /// box's bottom, one more line is shown spilling below the input. Set to
    /// 0 for the strict-fit behavior.
    private func truncateToFit(text: String, font: NSFont, maxWidth: CGFloat, availableHeight: CGFloat?, firstLineIndent: CGFloat, headIndent: CGFloat, extraLinesBelow: Int = 1) -> String {
        guard let availableHeight, availableHeight > 0, availableHeight.isFinite else { return text }

        // Lay out the full text with per-paragraph indentation
        let attrStr = buildAttributedString(text: text, font: font, firstLineIndent: firstLineIndent, headIndent: headIndent)
        let ts = NSTextStorage(attributedString: attrStr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        ts.addLayoutManager(lm)
        lm.ensureLayout(for: tc)

        let fullHeight = lm.usedRect(for: tc).height

        // Count actual rendered lines from NSLayoutManager
        var totalLines = 0
        var glyphIdx = 0
        let numGlyphs = lm.numberOfGlyphs
        while glyphIdx < numGlyphs {
            var lineRange = NSRange()
            lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &lineRange)
            totalLines += 1
            glyphIdx = NSMaxRange(lineRange)
        }

        // Use actual line height from layout (fullHeight / totalLines)
        let actualLineHeight = totalLines > 0 ? fullHeight / CGFloat(totalLines) : fullHeight
        guard actualLineHeight > 0, actualLineHeight.isFinite else { return text }

        // Effective budget = input-box's remaining height + slack for N lines
        // below the input. NSLayoutManager-computed line height keeps this
        // accurate even when font detection gives slightly off metrics.
        let effectiveAvailable = availableHeight + CGFloat(max(0, extraLinesBelow)) * actualLineHeight
        let rawFitting = floor(effectiveAvailable / actualLineHeight)
        let fittingLines = max(1, rawFitting.isFinite && rawFitting <= Double(Int.max) ? Int(rawFitting) : totalLines)

        let minAllowedLines = fittingLines
        guard totalLines > minAllowedLines else { return text }

        // Find the character index at the end of the last line that fits
        let maxCharIndex = lm.characterIndex(for: NSPoint(x: maxWidth, y: effectiveAvailable - 1), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        guard maxCharIndex > 0, maxCharIndex < text.count else { return text }

        let cutoff = text.index(text.startIndex, offsetBy: min(maxCharIndex, text.count))
        let fittingText = String(text[..<cutoff])

        // Search backward for the best natural break point
        var truncated = truncateAtNaturalBoundary(fittingText, minRatio: 0.4)

        // Re-verify the truncated text fits. With firstLineIndent, text may still wrap
        // beyond the available height. Trim word by word until it fits.
        while !truncated.isEmpty {
            let checkAttr = buildAttributedString(text: truncated, font: font, firstLineIndent: firstLineIndent, headIndent: headIndent)
            let checkTs = NSTextStorage(attributedString: checkAttr)
            let checkLm = NSLayoutManager()
            let checkTc = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
            checkTc.lineFragmentPadding = 0
            checkLm.addTextContainer(checkTc)
            checkTs.addLayoutManager(checkLm)
            checkLm.ensureLayout(for: checkTc)
            let truncatedHeight = checkLm.usedRect(for: checkTc).height
            if truncatedHeight <= effectiveAvailable { break }
            // Remove last word
            if let lastSpace = truncated.lastIndex(of: " ") {
                truncated = String(truncated[..<lastSpace])
            } else {
                truncated = ""
            }
        }

        Log.debug("[Truncate] availH=\(Int(availableHeight))+\(extraLinesBelow)L(=\(Int(effectiveAvailable))) fullH=\(Int(fullHeight)) chars=\(text.count)→\(truncated.count)")
        return truncated
    }

    /// Find the latest natural boundary in text: sentence end > clause end > word boundary.
    private func truncateAtNaturalBoundary(_ text: String, minRatio: Double) -> String {
        let minLength = Int(Double(text.count) * minRatio)

        // Priority 1: Sentence end (. ! ?)
        if let idx = findLastBreak(in: text, after: minLength, patterns: [". ", "! ", "? ", ".\n", "!\n", "?\n"]) {
            return String(text[...idx])
        }
        // Also check if text ends with sentence-ending punctuation
        if let last = text.last, ".!?".contains(last) {
            return text
        }

        // Priority 2: Clause end (, ; : —)
        if let idx = findLastBreak(in: text, after: minLength, patterns: [", ", "; ", ": ", " — "]) {
            return String(text[...idx])
        }

        // Priority 3: Word boundary (last space)
        if let idx = text[text.index(text.startIndex, offsetBy: minLength)...].lastIndex(of: " ") {
            return String(text[..<idx])
        }

        return text
    }

    /// Find the last occurrence of any pattern after minLength, returning the index of the last character to keep.
    private func findLastBreak(in text: String, after minLength: Int, patterns: [String]) -> String.Index? {
        let searchRange = text.index(text.startIndex, offsetBy: minLength)..<text.endIndex
        var bestIndex: String.Index?
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .backwards, range: searchRange) {
                // Keep up to and including the punctuation character (not the trailing space)
                let keepIndex = text.index(before: range.upperBound)
                if bestIndex == nil || keepIndex > bestIndex! {
                    bestIndex = keepIndex
                }
            }
        }
        return bestIndex
    }
}
