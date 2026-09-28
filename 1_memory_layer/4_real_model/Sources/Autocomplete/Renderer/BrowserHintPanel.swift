import AppKit

/// A small, half-transparent floating panel that attaches above an input field
/// to surface a one-line hint about browser compatibility (e.g. "Enable Text
/// Metrics in chrome://accessibility").
///
/// The message is rendered via NSTextView so we can embed a clickable link
/// (the chrome://accessibility URL) right inside the text. Clicking the link
/// is intercepted by the coordinator's `textView(_:clickedOnLink:at:)` and
/// routed to `onLinkClick` — the caller decides what to do (typically: run
/// AppleScript to `open location` in the target browser).
///
/// The panel stays visible until the user clicks ✕. No auto-hide.
@MainActor
final class BrowserHintPanel {
    private let panel: NSPanel
    private let backgroundView: NSVisualEffectView
    private let textView: NSTextView
    private let dismissButton: NSButton
    private let coordinator: HintCoordinator

    var onLinkClick: ((URL) -> Void)?
    var onDismissTap: (() -> Void)?

    private static let panelHeight: CGFloat = 28
    private static let maxPanelWidth: CGFloat = 820
    private static let textFont: NSFont = .systemFont(ofSize: 11)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.masksToBounds = true

        coordinator = HintCoordinator()

        // NSTextView configured to behave like a label with clickable links.
        // - drawsBackground=false → transparent so the visual effect shows through
        // - isEditable=false, isSelectable=true → required for link clicks
        // - lineFragmentPadding=0 → no extra horizontal inset
        textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isFieldEditor = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.delegate = coordinator
        textView.font = Self.textFont
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        dismissButton = NSButton()
        dismissButton.title = "✕"
        dismissButton.bezelStyle = .recessed
        dismissButton.setButtonType(.momentaryPushIn)
        dismissButton.controlSize = .small
        dismissButton.font = .systemFont(ofSize: 10)
        dismissButton.target = coordinator
        dismissButton.action = #selector(HintCoordinator.dismissTapped)

        let stack = NSStackView(views: [textView, dismissButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor)
        ])

        panel.contentView = backgroundView

        coordinator.onLinkClick = { [weak self] url in
            // Don't hide the panel — the user is opening the URL in another app
            // and likely needs to refer back to the instructions in the message
            // (e.g. "check 'Text Metrics'") while they navigate the browser's
            // accessibility page. They can dismiss explicitly via the ✕ button.
            self?.onLinkClick?(url)
        }
        coordinator.onDismiss = { [weak self] in
            self?.onDismissTap?()
            self?.hide()
        }
    }

    /// Show the hint above the given input element.
    ///
    /// `linkText` (optional): a substring of `message` that should render as a
    /// clickable hyperlink. When clicked, `linkURL` is delivered via `onLinkClick`.
    /// If `linkText` is nil or not found in the message, no link is rendered and
    /// the message is plain text.
    func show(message: String, linkText: String?, linkURL: URL?, elementFrame: CGRect) {
        // Build attributed string with optional link styling
        let attr = NSMutableAttributedString(string: message, attributes: [
            .font: Self.textFont,
            .foregroundColor: NSColor.labelColor
        ])
        if let linkText = linkText, let linkURL = linkURL {
            let nsMessage = message as NSString
            let range = nsMessage.range(of: linkText)
            if range.location != NSNotFound {
                attr.addAttribute(.link, value: linkURL, range: range)
            }
        }
        textView.textStorage?.setAttributedString(attr)

        // Force layout so we get an accurate fittingSize
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let textWidth = ceil(attr.size().width)
        let textHeight = ceil(attr.size().height)

        // Constrain text view width
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(textHeight, 16))

        // Compute panel width from content
        let dismissW = dismissButton.fittingSize.width
        let totalW = textWidth + dismissW + 28
        let width = min(max(totalW, 240), Self.maxPanelWidth)
        let size = NSSize(width: width, height: Self.panelHeight)

        // Position: bottom edge of panel just above the top edge of the input field
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let elementTopAppKit = primaryScreenHeight - elementFrame.origin.y
        var origin = NSPoint(
            x: elementFrame.origin.x,
            y: elementTopAppKit + 2
        )

        // Clamp to the screen containing the element
        let probePoint = NSPoint(x: elementFrame.origin.x, y: elementTopAppKit)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probePoint) }) ?? NSScreen.main {
            let f = screen.frame
            origin.x = min(max(f.minX + 6, origin.x), f.maxX - size.width - 6)
            origin.y = min(max(f.minY + 6, origin.y), f.maxY - size.height - 6)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0.95
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }
}

@MainActor
private final class HintCoordinator: NSObject, NSTextViewDelegate {
    var onLinkClick: ((URL) -> Void)?
    var onDismiss: (() -> Void)?

    @objc func dismissTapped() { onDismiss?() }

    nonisolated func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Resolve to URL — link attribute may be NSURL or NSString depending on how it was set
        let url: URL?
        if let u = link as? URL {
            url = u
        } else if let s = link as? String {
            url = URL(string: s)
        } else {
            url = nil
        }

        if let url = url {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onLinkClick?(url)
                }
            }
        }
        // Return true → we handled the click; suppress NSWorkspace.openURL fallback
        // (which wouldn't work for chrome:// schemes anyway).
        return true
    }
}
