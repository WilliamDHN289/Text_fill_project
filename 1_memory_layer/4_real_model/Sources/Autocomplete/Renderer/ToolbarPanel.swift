import AppKit
import CoreGraphics
import QuartzCore

/// macOS only lets the *active* app change the mouse cursor, so NSCursor.set() from our
/// background, non-activating badge panel is silently ignored. This private CoreGraphics
/// (SkyLight) connection property — "SetsCursorInBackground" — opts us in. Resolved via
/// dlsym so a missing/renamed symbol degrades gracefully (cursor just won't change) instead
/// of failing to launch. Runs once, lazily.
private enum BackgroundCursor {
    static let enable: Void = {
        typealias MainConnFn = @convention(c) () -> Int32
        typealias SetPropFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let mainSym = dlsym(rtldDefault, "CGSMainConnectionID"),
              let setSym = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            Log.debug("[Cursor] SetsCursorInBackground unavailable (symbols not found)")
            return
        }
        let mainConn = unsafeBitCast(mainSym, to: MainConnFn.self)
        let setProp = unsafeBitCast(setSym, to: SetPropFn.self)
        let cid = mainConn()
        _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()
}

/// NSVisualEffectView that accepts first mouse and tracks hover.
private class FirstMouseEffectView: NSVisualEffectView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}

/// NSPanel subclass that can become key so buttons respond to clicks.
private class ClickablePanel: NSPanel {
    /// Cleared during reply mode so clicking a chip can't pull keyboard focus off the
    /// host text field (which would make TextInserter resolve to this panel on Accept).
    var allowKey = true
    override var canBecomeKey: Bool { allowKey }
}

/// Button with hover tracking.
private class HoverButton: NSButton {
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // The badge belongs to a background, non-activating app, so the window server keeps
    // resetting the cursor to the arrow as the pointer moves over our (inactive-app)
    // window. .cursorUpdate isn't delivered to inactive apps, so we re-assert the
    // pointing-hand on every move (.activeAlways enter/moved fire even while inactive).
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
        onHoverEnter?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        onHoverExit?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reply chip: pads its title so the selected fill (painted over the whole button) has
/// breathing room around the text instead of hugging it. Inherits first-mouse handling.
private class ReplyChipButton: HoverButton {
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 18    // 9pt horizontal padding each side
        s.height += 8    // 4pt vertical padding each side
        return s
    }
}

/// Thin vertical separator view.
private class SeparatorView: NSView {
    /// Dynamic color so it adapts to the badge's light/dark backdrop. Defaults to the
    /// system hairline; the reply divider overrides it with a more visible tone.
    var color: NSColor = .separatorColor
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let rect = NSRect(x: 0, y: 2, width: 1, height: bounds.height - 4)
        rect.fill()
    }
}

enum DisableDuration {
    case minutes15
    case minutes60
    case indefinitely
}

/// Standard clipboard edits for the custom-intent field, routed from InputMonitor because
/// these Cmd-key shortcuts are otherwise claimed by the host app's menu (our panel is key
/// but not the active app).
enum CustomFieldEdit {
    case paste, copy, cut, selectAll
}

@MainActor
protocol ToolbarPanelDelegate: AnyObject {
    func toolbarDidDisableForCurrentApp(_ toolbar: ToolbarPanel, duration: DisableDuration)
    func toolbarDidEnableForCurrentApp(_ toolbar: ToolbarPanel)
    func toolbarDidDisableGlobally(_ toolbar: ToolbarPanel, duration: DisableDuration)
    func toolbarDidEnableGlobally(_ toolbar: ToolbarPanel)
    func toolbarDidRequestSettings(_ toolbar: ToolbarPanel)
}

@MainActor
final class ToolbarPanel {
    private let panel: ClickablePanel
    private let coordinator: ToolbarCoordinator
    private let brandButton: HoverButton        // HoverButton → pointing-hand cursor on hover
    private let brandNameButton: HoverButton
    private let replySeparator: SeparatorView   // thin divider between "FlowIn" and the reply chips
    private let backgroundView: NSVisualEffectView
    private let mainStack: NSStackView

    // Reply preview (stage 2): below the chip row; the badge grows downward to show it.
    private let previewLabel: NSTextField
    private let acceptButton: NSButton
    private let customField: NSTextField        // stage-1 custom-intent input (opened by the ✎ chip)
    private let customSubmitButton: NSButton    // inline ↑ submit at the right of the field
    private let customRow: NSStackView          // [customField | customSubmitButton]
    private let previewStack: NSStackView
    private var customRowWidthConstraint: NSLayoutConstraint!

    // App toggle + inline durations
    private let appToggle: HoverButton
    private let appSeparator: SeparatorView
    private let appDuration15: NSButton
    private let appDuration60: NSButton
    private let appDurationIndef: NSButton

    // Global toggle + inline durations
    private let globalToggle: HoverButton
    private let globalSeparator: SeparatorView
    private let globalDuration15: NSButton
    private let globalDuration60: NSButton
    private let globalDurationIndef: NSButton

    weak var delegate: ToolbarPanelDelegate?

    private var hideTimer: DispatchWorkItem?
    private var collapseTimer: DispatchWorkItem?
    private(set) var currentAppBundleId: String = ""
    private var isExpanded = false
    private var currentAppEnabled = true
    private var currentGlobalEnabled = true

    // Reply-chips mode: the badge expands into [feather + chips] instead of toggles.
    private var replyChipButtons: [NSButton] = []
    private var replyHighlightedIndex = 0
    private var isReplyMode = false
    // The badge is "armed" as a reply offer (idle-in-a-reply-box): shown but not yet
    // generating. A brand-tap in this state runs the first-stage draft instead of the
    // enable/disable UI. Cleared the moment generation starts or autocomplete reclaims
    // the badge.
    private var isReplyOffer = false
    // Bumped on every show / hide-start. A fade-out's completion only orders the panel
    // out if the epoch is unchanged — so a show that lands mid-fade isn't clobbered by
    // the trailing orderOut. Guards against the panel getting stuck ordered-in-but-
    // transparent (alpha 0), which silently makes the reply badge invisible.
    private var visibilityEpoch = 0
    var onReplyChipSelected: ((Int) -> Void)?
    var onReplyOfferTap: (() -> Void)?
    var onReplyAccept: (() -> Void)?
    var onCustomIntentSubmit: ((String) -> Void)?
    var onCustomIntentCancel: (() -> Void)?

    // Adaptive appearance: sampled backdrop luminance, re-sampled only when the
    // context (app + field position) changes.
    private var backdropIsLight: Bool?
    private var lastLumKey = ""

    private static let collapsedWidth: CGFloat = 28
    private static let panelHeight: CGFloat = 28
    /// Right-side breathing room added to the expanded pill (the feather's own
    /// centering already gives matching padding on the left).
    private static let expandedTrailingPadding: CGFloat = 8
    private static let minPreviewWidth: CGFloat = 280   // floor for the stage-2 preview width
    /// Gap between the badge's bottom and the caret/input top. Lifting the badge to sit
    /// just above the input line keeps its rightward expansion (chips) off the text being
    /// typed, without riding far up over the line above. Tunable.
    private static let badgeCaretGap: CGFloat = 3

    init() {
        coordinator = ToolbarCoordinator()

        _ = BackgroundCursor.enable   // allow this non-activating panel to set the cursor on hover

        panel = ClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.collapsedWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: 200)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true   // lets HoverButton re-assert the pointing-hand cursor
        // Let the user reposition the panel by dragging its frosted background; buttons still
        // handle their own clicks (only drags on non-control areas move the window).
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]

        // Background — a material that follows the light/dark appearance, so the
        // circle is light over light environments and dark over dark ones.
        backgroundView = FirstMouseEffectView()
        backgroundView.material = .popover
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        // Half the height → perfect circle when collapsed (28×28), rounded pill when expanded.
        backgroundView.layer?.cornerRadius = Self.panelHeight / 2
        backgroundView.layer?.masksToBounds = true

        // Brand button — the FlowIn feather mark, sized smaller than the badge
        // so the translucent circle shows around it (Cotypist-style).
        brandButton = HoverButton()
        brandButton.isBordered = false
        brandButton.bezelStyle = .recessed
        brandButton.setButtonType(.momentaryPushIn)
        let logo = FeatherLogo.image
        let logoHeight: CGFloat = 18
        logo.size = NSSize(width: logoHeight * logo.size.width / logo.size.height, height: logoHeight)
        // Template image → AppKit tints the feather to labelColor: dark in Light
        // appearance, light in Dark appearance. One asset, auto-adapts (no need
        // for separate black/white versions). Pairs with the adaptive material.
        logo.isTemplate = true
        brandButton.image = logo
        brandButton.imagePosition = .imageOnly
        brandButton.imageScaling = .scaleProportionallyDown
        brandButton.contentTintColor = .labelColor
        brandButton.target = coordinator
        brandButton.action = #selector(ToolbarCoordinator.brandTapped)

        // Brand name — shown only when expanded so the user knows which app the
        // badge belongs to, and doubles as the Settings entry point (replacing the
        // separate Settings button). labelColor tracks the adaptive appearance.
        brandNameButton = HoverButton()
        brandNameButton.isBordered = false
        brandNameButton.setButtonType(.momentaryPushIn)
        brandNameButton.attributedTitle = NSAttributedString(string: "FlowIn", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        brandNameButton.target = coordinator
        brandNameButton.action = #selector(ToolbarCoordinator.settingsTapped)
        brandNameButton.isHidden = true

        // --- App toggle + durations ---
        appToggle = HoverButton()
        appToggle.bezelStyle = .recessed
        appToggle.setButtonType(.momentaryPushIn)
        appToggle.font = .systemFont(ofSize: 10)
        appToggle.controlSize = .small
        appToggle.target = coordinator
        appToggle.action = #selector(ToolbarCoordinator.appToggleTapped)
        appToggle.isHidden = true

        appSeparator = SeparatorView()
        appSeparator.isHidden = true
        replySeparator = SeparatorView()
        replySeparator.color = .tertiaryLabelColor   // more visible than the faint system hairline
        replySeparator.isHidden = true

        appDuration15 = Self.makeDurationButton(title: "15m", target: coordinator, action: #selector(ToolbarCoordinator.appDisable15))
        appDuration60 = Self.makeDurationButton(title: "60m", target: coordinator, action: #selector(ToolbarCoordinator.appDisable60))
        appDurationIndef = Self.makeDurationButton(title: "∞", target: coordinator, action: #selector(ToolbarCoordinator.appDisableIndef))
        appDuration15.isHidden = true
        appDuration60.isHidden = true
        appDurationIndef.isHidden = true

        // --- Global toggle + durations ---
        globalToggle = HoverButton()
        globalToggle.bezelStyle = .recessed
        globalToggle.setButtonType(.momentaryPushIn)
        globalToggle.font = .systemFont(ofSize: 10)
        globalToggle.controlSize = .small
        globalToggle.target = coordinator
        globalToggle.action = #selector(ToolbarCoordinator.globalToggleTapped)
        globalToggle.isHidden = true

        globalSeparator = SeparatorView()
        globalSeparator.isHidden = true

        globalDuration15 = Self.makeDurationButton(title: "15m", target: coordinator, action: #selector(ToolbarCoordinator.globalDisable15))
        globalDuration60 = Self.makeDurationButton(title: "60m", target: coordinator, action: #selector(ToolbarCoordinator.globalDisable60))
        globalDurationIndef = Self.makeDurationButton(title: "∞", target: coordinator, action: #selector(ToolbarCoordinator.globalDisableIndef))
        globalDuration15.isHidden = true
        globalDuration60.isHidden = true
        globalDurationIndef.isHidden = true

        // Main stack — all inline
        mainStack = NSStackView(views: [
            brandButton, brandNameButton, replySeparator,
            appToggle, appSeparator, appDuration15, appDuration60, appDurationIndef,
            globalToggle, globalSeparator, globalDuration15, globalDuration60, globalDurationIndef,
        ])
        mainStack.orientation = .horizontal
        mainStack.spacing = 8
        // No edge insets: the collapsed brand button must fill the whole 28×28
        // circle so the entire badge is clickable (not just the centered glyph).
        // Visual padding comes from the feather being smaller than its button.
        mainStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Reply preview (stage 2) — sits below the chip row; the panel grows downward to
        // reveal it so the whole reply (feather + chips + preview + Accept) is one surface.
        previewLabel = NSTextField(wrappingLabelWithString: "")
        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.isHidden = true
        acceptButton = HoverButton()                 // HoverButton accepts first mouse → fires while non-key
        acceptButton.title = "Accept  ⏎"
        acceptButton.bezelStyle = .rounded
        acceptButton.setButtonType(.momentaryPushIn)
        acceptButton.controlSize = .small
        acceptButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        acceptButton.target = coordinator
        acceptButton.action = #selector(ToolbarCoordinator.replyAccept)
        acceptButton.isHidden = true
        // Custom-intent input (stage 1): a borderless field that matches the frosted panel.
        customField = NSTextField()
        customField.placeholderString = "Type your own reply intent…"
        customField.font = .systemFont(ofSize: 13)
        customField.isBezeled = false
        customField.drawsBackground = false
        customField.focusRingType = .none
        customField.usesSingleLineMode = true
        customField.lineBreakMode = .byClipping
        customField.cell?.isScrollable = true
        customField.delegate = coordinator
        customField.setContentHuggingPriority(.defaultLow, for: .horizontal)   // stretch; button hugs the right
        // Inline submit affordance at the right of the field (Enter also submits). Minimal,
        // monochrome, borderless — a muted up-arrow that mirrors the pencil chip's glyph style.
        customSubmitButton = HoverButton()
        customSubmitButton.isBordered = false
        customSubmitButton.setButtonType(.momentaryChange)
        customSubmitButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Submit custom reply")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        customSubmitButton.imagePosition = .imageOnly
        customSubmitButton.imageScaling = .scaleProportionallyDown
        customSubmitButton.contentTintColor = .secondaryLabelColor
        customSubmitButton.setContentHuggingPriority(.required, for: .horizontal)
        customSubmitButton.target = coordinator
        customSubmitButton.action = #selector(ToolbarCoordinator.customSubmitTapped)
        customRow = NSStackView(views: [customField, customSubmitButton])
        customRow.orientation = .horizontal
        customRow.spacing = 6
        customRow.alignment = .centerY
        customRow.distribution = .fill
        customRow.isHidden = true
        previewStack = NSStackView(views: [customRow, previewLabel, acceptButton])
        previewStack.orientation = .vertical
        previewStack.spacing = 8
        previewStack.alignment = .leading
        previewStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
        previewStack.isHidden = true
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        // The row needs an explicit width (the field's intrinsic width is just the
        // placeholder); set to the grown-down width minus the previewStack insets.
        customRowWidthConstraint = customRow.widthAnchor.constraint(equalToConstant: Self.minPreviewWidth - 24)
        customRowWidthConstraint.isActive = true

        backgroundView.addSubview(mainStack)
        backgroundView.addSubview(previewStack)
        NSLayoutConstraint.activate([
            // Pinned leading only (not trailing) so the expanded panel can be a
            // touch wider than the content — fitPanelToContent adds the right pad.
            mainStack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            mainStack.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            // Fixed chip-row height; the preview grows the panel below this row.
            mainStack.heightAnchor.constraint(equalToConstant: Self.panelHeight),
            // Brand button fills the badge height (a perfect circle when collapsed),
            // making the whole chip a click target.
            brandButton.widthAnchor.constraint(equalToConstant: Self.panelHeight),
            brandButton.heightAnchor.constraint(equalToConstant: Self.panelHeight),
            previewStack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            previewStack.topAnchor.constraint(equalTo: mainStack.bottomAnchor),
        ])

        panel.contentView = backgroundView

        // Pause timers on hover
        (backgroundView as? FirstMouseEffectView)?.onMouseEntered = { [weak self] in
            self?.hideTimer?.cancel()
            self?.collapseTimer?.cancel()
        }
        (backgroundView as? FirstMouseEffectView)?.onMouseExited = { [weak self] in
            guard let self else { return }
            // Ignore spurious exits fired while the panel resizes under a
            // stationary cursor — only act when the mouse truly left the badge.
            // Otherwise the shrink-on-exit fights the hover expand (oscillation).
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.hideAppDurations()
            self.hideGlobalDurations()
            if self.isExpanded { self.fitPanelToContent() }  // shrink back, no durations
            self.resetHideTimer()
            if self.isExpanded { self.resetCollapseTimer() }
        }

        // Hover on app toggle → show its durations, hide global's
        // Durations only hide when mouse leaves entire toolbar or hovers the other toggle
        appToggle.onHoverEnter = { [weak self] in
            guard let self, self.currentAppEnabled else { return }
            self.hideGlobalDurations()
            self.showAppDurations()
        }

        // Hover on global toggle → show its durations, hide app's
        globalToggle.onHoverEnter = { [weak self] in
            guard let self, self.currentGlobalEnabled else { return }
            self.hideAppDurations()
            self.showGlobalDurations()
        }

        // Wire coordinator
        coordinator.onBrandTap = { [weak self] in
            guard let self else { return }
            // Armed reply offer → run the first-stage draft. Otherwise the badge is the
            // autocomplete badge: expand into the enable/disable UI (toggleExpand is inert
            // while an actual reply is on screen).
            if self.isReplyOffer { self.onReplyOfferTap?() }
            else { self.toggleExpand() }
        }
        coordinator.onAppToggle = { [weak self] in
            guard let self else { return }
            // When enabled, this label is only the hover target for the 15m/60m/∞
            // durations — a bare click would be an ambiguous "disable for how
            // long?", so do nothing. When disabled, it re-enables (no ambiguity).
            guard !self.currentAppEnabled else { return }
            self.delegate?.toolbarDidEnableForCurrentApp(self)
        }
        coordinator.onGlobalToggle = { [weak self] in
            guard let self else { return }
            guard !self.currentGlobalEnabled else { return }
            self.delegate?.toolbarDidEnableGlobally(self)
        }
        coordinator.onAppDisableDuration = { [weak self] duration in
            guard let self else { return }
            self.delegate?.toolbarDidDisableForCurrentApp(self, duration: duration)
        }
        coordinator.onGlobalDisableDuration = { [weak self] duration in
            guard let self else { return }
            self.delegate?.toolbarDidDisableGlobally(self, duration: duration)
        }
        coordinator.onSettings = { [weak self] in
            guard let self else { return }
            self.delegate?.toolbarDidRequestSettings(self)
        }
        coordinator.onReplyChip = { [weak self] idx in
            guard let self else { return }
            self.highlightReplyChip(index: idx)
            self.onReplyChipSelected?(idx)
        }
        coordinator.onReplyAccept = { [weak self] in self?.onReplyAccept?() }
        coordinator.onCustomSubmit = { [weak self] in
            guard let self else { return }
            // Live editor text covers both Enter (field is first responder) and a click on the
            // submit button (focus may not have moved, so stringValue could lag the editor).
            let live = self.customField.currentEditor()?.string ?? self.customField.stringValue
            let text = live.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }   // empty submit: stay in the field
            self.onCustomIntentSubmit?(text)      // preview path ends focus + defers key handoff
        }
        coordinator.onCustomCancel = { [weak self] in
            guard let self else { return }
            self.cancelCustomIntent()
            self.onCustomIntentCancel?()
        }
        coordinator.onCustomBackToChips = { [weak self] in self?.customIntentBackToChips() }
    }

    private static func makeDurationButton(title: String, target: AnyObject, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.setButtonType(.momentaryPushIn)
        btn.title = title
        btn.font = .systemFont(ofSize: 9)
        btn.controlSize = .mini
        btn.showsBorderOnlyWhileMouseInside = true
        btn.target = target
        btn.action = action
        return btn
    }

    func show(near caretRect: CGRect, elementFrame: CGRect, appName: String, appBundleId: String, isAppEnabled: Bool, isGloballyEnabled: Bool) {
        guard !isReplyMode else { return }   // don't let the autocomplete badge clobber the reply pill
        isReplyOffer = false                 // autocomplete reclaims the badge → click shows enable/disable UI
        panel.allowKey = true                // ... and may become key again for the toggle UI
        currentAppBundleId = appBundleId
        currentAppEnabled = isAppEnabled
        currentGlobalEnabled = isGloballyEnabled

        let shortName = appName.count > 10 ? String(appName.prefix(10)) + "…" : appName
        appToggle.title = isAppEnabled ? "Disable for \(shortName)" : "Enable for \(shortName)"
        globalToggle.title = isGloballyEnabled ? "Disable Globally" : "Enable Globally"

        hideAppDurations()
        hideGlobalDurations()

        updateBackdropAppearance(near: caretRect, elementFrame: elementFrame, appBundleId: appBundleId)

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let elemAppKitPoint = NSPoint(x: elementFrame.origin.x, y: primaryScreenHeight - elementFrame.origin.y)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(elemAppKitPoint) })?.frame
            ?? NSScreen.main?.frame ?? .zero

        let currentWidth = isExpanded ? panel.frame.width : Self.collapsedWidth
        let toolbarSize = NSSize(width: currentWidth, height: Self.panelHeight)

        // Horizontal: hang the chip on the field's left outline (right edge flush
        // against the field's left edge; expansion grows rightward — see resizePanel).
        // Vertical: anchor to the caret line, not the element top. In terminals (e.g.
        // Claude Code) the focused element is the whole scrollback, so its top is the
        // window top while the input/caret sits far lower; the caret degrades to the
        // element frame when its reading is unreliable, so normal fields are unaffected.
        let caretTopAppKit = primaryScreenHeight - caretRect.origin.y
        // Sit just ABOVE the input line (bottom a hair above the caret top) so the chips
        // don't cover the text being typed when the badge expands rightward.
        let origin = NSPoint(
            x: elementFrame.origin.x - Self.collapsedWidth,
            y: caretTopAppKit + Self.badgeCaretGap
        )

        let clampedX = min(max(screenFrame.minX, origin.x), screenFrame.maxX - toolbarSize.width - 10)
        let clampedY = min(max(screenFrame.minY + 10, origin.y), screenFrame.maxY - toolbarSize.height - 10)

        panel.setFrame(NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: toolbarSize), display: true)

        // Fade in when genuinely appearing (ordered out OR left transparent by a prior
        // fade); otherwise just ensure it's front and opaque. Bumping the epoch aborts
        // any in-flight hide-fade so it can't orderOut this freshly-shown badge.
        visibilityEpoch &+= 1
        if !panel.isVisible || panel.alphaValue == 0 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1.0
            }
        } else {
            panel.orderFrontRegardless()
        }

        resetHideTimer()
    }

    func hide() {
        guard !isReplyMode else { return }   // reply dismissal goes through endReplyMode
        hideTimer?.cancel()
        hideTimer = nil
        collapseTimer?.cancel()
        collapseTimer = nil

        guard panel.isVisible else { return }

        isExpanded = false
        setAllTogglesHidden(true)

        visibilityEpoch &+= 1
        let epoch = visibilityEpoch
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.visibilityEpoch == epoch else { return }  // re-shown mid-fade → keep it
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1   // never leave it ordered-in-but-transparent
        })
    }

    var isVisible: Bool {
        panel.isVisible && panel.alphaValue > 0
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        guard panel.isVisible else { return false }
        return panel.frame.contains(point)
    }

    // MARK: - Expand / Collapse

    private func toggleExpand() {
        guard !isReplyMode else { return }   // the feather is inert while showing reply chips
        if isExpanded { collapse() } else { expand() }
    }

    private func expand() {
        isExpanded = true
        brandNameButton.isHidden = false
        appToggle.isHidden = false
        globalToggle.isHidden = false

        fitPanelToContent()
        resetCollapseTimer()
    }

    private func collapse() {
        isExpanded = false
        collapseTimer?.cancel()
        collapseTimer = nil

        setAllTogglesHidden(true)
        resizePanel(width: Self.collapsedWidth)
    }

    private func setAllTogglesHidden(_ hidden: Bool) {
        brandNameButton.isHidden = hidden
        appToggle.isHidden = hidden
        globalToggle.isHidden = hidden
        if hidden { replySeparator.isHidden = true }   // reply-only; never revealed by the toggle UI
        hideAppDurations()
        hideGlobalDurations()
    }

    // MARK: - Duration Buttons

    private func showAppDurations() {
        guard appDuration15.isHidden else { return }  // idempotent — already showing
        appSeparator.isHidden = false
        appDuration15.isHidden = false
        appDuration60.isHidden = false
        appDurationIndef.isHidden = false
        refreshTrackingAreas()
        fitPanelToContent()
    }

    private func hideAppDurations() {
        guard !appDuration15.isHidden else { return }  // already hidden — nothing to do
        appSeparator.isHidden = true
        appDuration15.isHidden = true
        appDuration60.isHidden = true
        appDurationIndef.isHidden = true
        refreshTrackingAreas()
    }

    private func showGlobalDurations() {
        guard globalDuration15.isHidden else { return }
        globalSeparator.isHidden = false
        globalDuration15.isHidden = false
        globalDuration60.isHidden = false
        globalDurationIndef.isHidden = false
        refreshTrackingAreas()
        fitPanelToContent()
    }

    private func hideGlobalDurations() {
        guard !globalDuration15.isHidden else { return }
        globalSeparator.isHidden = true
        globalDuration15.isHidden = true
        globalDuration60.isHidden = true
        globalDurationIndef.isHidden = true
        refreshTrackingAreas()
    }

    /// Force layout and update tracking areas after visibility changes.
    private func refreshTrackingAreas() {
        mainStack.layoutSubtreeIfNeeded()
        appToggle.updateTrackingAreas()
        globalToggle.updateTrackingAreas()
    }



    /// Size the expanded panel to exactly fit its visible content (no trailing
    /// gap). Driven off the stack's content width, which varies with the app-name
    /// length and whether the hover durations are showing.
    private func fitPanelToContent() {
        mainStack.layoutSubtreeIfNeeded()
        resizePanel(width: mainStack.fittingSize.width + Self.expandedTrailingPadding)
    }

    private func resizePanel(width: CGFloat) {
        var frame = panel.frame
        frame.size.width = width
        let screenFrame = NSScreen.main?.frame ?? .zero
        if frame.origin.x + frame.width > screenFrame.maxX - 10 {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Timers

    private func resetHideTimer() {
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    private func resetCollapseTimer() {
        collapseTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        collapseTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    // MARK: - Reply loading pulse

    private static let loadingPulseKey = "replyLoadingPulse"

    /// Show the collapsed badge at the field and pulse the feather to signal that a
    /// reply draft is generating (first stage), before the reply card appears. The
    /// card later drops over the badge at this same anchor, so the pulse reads as the
    /// badge "thinking" and then expanding into options.
    /// Show the collapsed badge at the field without pulsing (used for reply errors that
    /// have no generation step). Keeps the badge up by cancelling the idle-hide timer.
    /// Show the collapsed badge as an armed reply offer (idle-in-a-reply-box). No
    /// generation happens until the badge is clicked (→ onReplyOfferTap). Visually
    /// identical to the autocomplete badge; only the click behavior differs.
    func showReplyOffer(near elementFrame: CGRect, caret caretRect: CGRect, appBundleId: String) {
        guard !isReplyMode else { return }   // a real reply is already on screen
        isReplyOffer = true
        // Clicking the offer runs trigger() → readContextForReply(); the panel must NOT
        // become key, or it steals focus and the read resolves to the panel, not the field.
        panel.allowKey = false
        showCollapsed(near: elementFrame, caret: caretRect, appBundleId: appBundleId)
    }

    /// Tear down an un-clicked reply offer (the user typed / clicked away / switched
    /// apps). Instant hide — the autocomplete badge re-shows itself on the next
    /// keystroke. No-op if the badge isn't an armed offer.
    func dismissReplyOffer() {
        guard isReplyOffer else { return }
        isReplyOffer = false
        panel.allowKey = true                // restore for the autocomplete badge's toggle UI
        hideTimer?.cancel(); hideTimer = nil
        collapseTimer?.cancel(); collapseTimer = nil
        panel.orderOut(nil)
    }

    func showCollapsed(near elementFrame: CGRect, caret caretRect: CGRect, appBundleId: String) {
        // Match the autocomplete badge: sample the backdrop so the reply badge/pill
        // renders light or dark to match what's behind it (not always dark).
        updateBackdropAppearance(near: caretRect, elementFrame: elementFrame, appBundleId: appBundleId)
        hideTimer?.cancel(); hideTimer = nil          // keep the badge up for the whole generation
        collapseTimer?.cancel(); collapseTimer = nil
        if isExpanded { isExpanded = false; setAllTogglesHidden(true) }
        let frame = collapsedFrame(near: elementFrame, caret: caretRect)
        panel.setFrame(frame, display: true)
        // Force visible unconditionally — AppKit's panel.isVisible is true even for an
        // alpha-0 (transparent) or mid-fade-out panel, so gating on it can leave the
        // badge ordered-in but invisible. Bumping the epoch aborts any in-flight fade.
        visibilityEpoch &+= 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func startLoadingPulse(near elementFrame: CGRect, caret caretRect: CGRect, appBundleId: String) {
        isReplyOffer = false                 // generation started — no longer a bare offer
        showCollapsed(near: elementFrame, caret: caretRect, appBundleId: appBundleId)
        brandButton.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        brandButton.layer?.add(pulse, forKey: Self.loadingPulseKey)
    }

    /// Stop the loading pulse but keep the badge pinned in place — while the reply card
    /// is open the badge stays put as the leading feather (the card grows to its right).
    func stopLoadingPulse() {
        brandButton.layer?.removeAnimation(forKey: Self.loadingPulseKey)
    }

    /// End reply mode: tear down the chips + preview, stop any pulse, and resume the
    /// badge's normal idle-hide behavior. Called when the reply is dismissed.
    func endReplyMode() {
        stopLoadingPulse()
        previewLabel.isHidden = true; acceptButton.isHidden = true; customRow.isHidden = true; previewStack.isHidden = true
        panel.makeFirstResponder(nil)
        replyChipButtons.forEach { mainStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        replyChipButtons = []
        guard isReplyMode else {
            if panel.isVisible { resetHideTimer() }
            return
        }
        isReplyMode = false
        panel.allowKey = true
        isExpanded = false
        collapseTimer?.cancel(); collapseTimer = nil
        setAllTogglesHidden(true)
        // Shrink back to the collapsed circle (width AND height), keeping the top fixed,
        // then fade the badge out so dismissing the reply fully clears it (the Engine
        // re-shows the badge normally on the next keystroke).
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: Self.collapsedWidth, height: Self.panelHeight)
        frame.origin.y = top - Self.panelHeight
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.dismissAfterReply()
        })
    }

    /// Fade the badge out after the reply pill has shrunk back to the circle, so
    /// dismissing the reply leaves nothing behind.
    private func dismissAfterReply() {
        guard !isReplyMode else { return }   // a new reply started during the shrink — keep it
        hideTimer?.cancel(); hideTimer = nil
        visibilityEpoch &+= 1
        let epoch = visibilityEpoch
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new reply / badge shown during the fade bumps the epoch → keep it visible.
            guard let self, self.visibilityEpoch == epoch, !self.isReplyMode else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1   // reset for the next show
        })
    }

    /// Show the expanded reply (or "…") below the chips, growing the panel downward so
    /// the chips and preview share one continuous surface. With an Accept button.
    func showReplyPreview(_ text: String) { presentReplyPreview(text, showAccept: true) }

    /// Show an error/info message below the chips (no Accept), growing downward.
    func setReplyPreviewError(_ text: String) {
        // An error is a dismissable reply surface too: mark reply mode so endReplyMode()
        // shrinks-and-fades it out on Esc / click-away instead of leaving it parked until
        // the idle-hide timer. (Harmless when already in reply mode, e.g. an expand error.)
        isReplyMode = true
        presentReplyPreview(text, showAccept: false)
    }

    private func presentReplyPreview(_ text: String, showAccept: Bool) {
        endFieldFocus()                       // stop typing now; key handoff happens post-animation
        customRow.isHidden = true
        // Keep a readable width even with no chips (an error before stage 1); otherwise
        // the preview wraps to the chip-pill width so the surface stays continuous.
        let targetWidth = max(panel.frame.width, Self.minPreviewWidth)
        previewLabel.preferredMaxLayoutWidth = targetWidth - 24   // previewStack left+right insets
        previewLabel.stringValue = text
        previewLabel.isHidden = false
        acceptButton.isHidden = !showAccept
        growDown(targetWidth: targetWidth)   // panel stays key; key is dropped once, at Accept
    }

    /// Grow the panel downward to fit whatever is currently visible in previewStack,
    /// keeping the top edge fixed so the chip row stays put. `completion` runs when the
    /// grow animation finishes (used to hand keyboard focus back after the field closes).
    private func growDown(targetWidth: CGFloat, completion: (() -> Void)? = nil) {
        previewStack.isHidden = false
        previewStack.layoutSubtreeIfNeeded()
        let newHeight = Self.panelHeight + previewStack.fittingSize.height
        var frame = panel.frame
        let top = frame.maxY                  // keep the top edge fixed; grow downward
        frame.size = NSSize(width: targetWidth, height: newHeight)
        frame.origin.y = top - newHeight
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.minX, y: top)) })?.frame
            ?? NSScreen.main?.frame ?? .zero
        if frame.origin.x + frame.width > screenFrame.maxX - 10 { frame.origin.x = screenFrame.maxX - frame.width - 10 }
        if frame.origin.y < screenFrame.minY + 10 { frame.origin.y = screenFrame.minY + 10 }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.14; panel.animator().setFrame(frame, display: true) },
                                             completionHandler: completion)
    }

    // MARK: - Custom intent (✎)

    /// Open the custom-intent input: reveal the field in the grown-down area and make the
    /// panel key so the field can receive typing (a nonactivating panel takes the keyboard
    /// without activating our app). dropKeyForInsertion() flips it back to non-key at Accept,
    /// so the insert still resolves to the host's field.
    func beginCustomIntent() {
        previewLabel.isHidden = true
        acceptButton.isHidden = true
        customField.stringValue = ""
        customRow.isHidden = false
        let targetWidth = max(panel.frame.width, Self.minPreviewWidth)
        customRowWidthConstraint.constant = targetWidth - 24
        panel.allowKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(customField)
        growDown(targetWidth: targetWidth)
    }

    /// Run a standard clipboard edit on the custom-intent field's editor (respects caret /
    /// selection). Driven from InputMonitor because these Cmd-key shortcuts are otherwise
    /// claimed by the host app's menu.
    func performCustomFieldEdit(_ edit: CustomFieldEdit) {
        guard let editor = customField.currentEditor() else { return }
        switch edit {
        case .paste: editor.paste(nil)
        case .copy: editor.copy(nil)
        case .cut: editor.cut(nil)
        case .selectAll: editor.selectAll(nil)
        }
    }

    /// Esc in the field: tear down the input and shrink back up to the chip row.
    private func cancelCustomIntent() {
        endFieldFocus()
        customRow.isHidden = true
        previewStack.isHidden = true
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = Self.panelHeight
        frame.origin.y = top - Self.panelHeight
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; panel.animator().setFrame(frame, display: true) }
    }

    /// Left arrow in an empty custom field: close it and highlight the chip just left of the
    /// ✎, so the user lands back on the intent options (chips stage).
    private func customIntentBackToChips() {
        let target = replyHighlightedIndex - 1
        guard target >= 0 else { return }     // ✎ is the only chip — nothing to step back to
        cancelCustomIntent()
        highlightReplyChip(index: target)
        onCustomIntentCancel?()               // ReplyController: clear editing flag, return to chips stage
    }

    /// Stop typing in the field (drop the caret) and bar the panel from re-keying on clicks.
    /// The panel stays the key window until Accept (or dismissal) — no mid-flow orderOut.
    private func endFieldFocus() {
        panel.makeFirstResponder(nil)
        panel.allowKey = false
    }

    /// Hand the key window — and thus keyboard focus / the AX focused application — back to
    /// the host, called once right before Accept inserts. Keeping the panel key for the whole
    /// reply means no mid-flow orderOut, so switching between the custom field and the chips
    /// never blinks. This single orderOut drops key as the panel is dismissing anyway, and
    /// blocks until the host re-keys so the AX insert resolves to the host's field, not us.
    func dropKeyForInsertion() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.allowKey = false
        panel.orderOut(nil)
    }

    // MARK: - Reply chips (badge expands into the stage-1 strip)

    var replyChipCount: Int { replyChipButtons.count }
    var highlightedReplyChip: Int { replyHighlightedIndex }

    /// Expand the badge into a pill of reply chips (feather + chips), reusing the same
    /// width-grow animation as the enable/disable toggles. Replaces the loading pulse.
    func showReplyChips(_ texts: [String]) {
        stopLoadingPulse()
        previewLabel.isHidden = true; acceptButton.isHidden = true; customRow.isHidden = true; previewStack.isHidden = true
        isReplyMode = true
        panel.allowKey = false               // chip clicks must not steal the field's focus
        hideTimer?.cancel(); hideTimer = nil
        collapseTimer?.cancel(); collapseTimer = nil
        isExpanded = false
        setAllTogglesHidden(true)            // hide the toggle UI; chips take its place
        brandNameButton.isHidden = false     // ...but keep "FlowIn" as a brand + settings entry point
        replySeparator.isHidden = false      // thin divider between "FlowIn" and the chips

        replyChipButtons.forEach { mainStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        replyChipButtons = []
        for (i, text) in texts.enumerated() {
            let chip = makeReplyChip(text: text, index: i)
            mainStack.insertArrangedSubview(chip, at: 3 + i)   // after feather (0) + "FlowIn" (1) + separator (2)
            replyChipButtons.append(chip)
        }
        // Trailing ✎ chip → opens the custom-intent input. Index past the last intent so
        // ReplyController can tell it apart; it joins replyChipButtons for arrow nav + styling.
        let customChip = makeCustomChip(index: texts.count)
        mainStack.insertArrangedSubview(customChip, at: 3 + texts.count)
        replyChipButtons.append(customChip)
        replyHighlightedIndex = 0
        applyReplyHighlight()
        fitPanelToContent()                  // animated grow → chips reveal as the pill widens
    }

    func highlightReplyChip(index: Int) {
        guard !replyChipButtons.isEmpty else { return }
        replyHighlightedIndex = (index + replyChipButtons.count) % replyChipButtons.count
        applyReplyHighlight()
    }

    private func applyReplyHighlight() {
        for (i, chip) in replyChipButtons.enumerated() {
            let selected = (i == replyHighlightedIndex)
            // Monochrome selection that adapts to the backdrop (no system-accent blue):
            // a solid label-colored pill with inverted text — dark-on-light over a light
            // backdrop, light-on-dark over a dark one.
            chip.contentTintColor = selected ? .textBackgroundColor : .labelColor
            chip.layer?.backgroundColor = selected ? resolvedFill(.labelColor) : nil
            chip.needsDisplay = true
        }
    }

    /// Resolve a dynamic NSColor against the panel's current backdrop appearance and
    /// return a CGColor — the chip's layer fill can't hold a dynamic color directly.
    private func resolvedFill(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        panel.effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }

    private func makeReplyChip(text: String, index: Int) -> NSButton {
        let chip = ReplyChipButton()         // padded; accepts first mouse → clicks fire while non-key
        chip.isBordered = false
        chip.bezelStyle = .rounded
        chip.font = .systemFont(ofSize: 12)
        chip.title = text
        chip.tag = index
        chip.alignment = .center             // center the title within the padded bounds
        chip.contentTintColor = .labelColor
        chip.lineBreakMode = .byTruncatingTail
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.masksToBounds = true
        chip.target = coordinator
        chip.action = #selector(ToolbarCoordinator.replyChip(_:))
        chip.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return chip
    }

    /// The trailing ✎ chip that opens the custom-intent input — styled like an intent chip
    /// (padded, highlightable) but shows a pencil glyph instead of a label.
    private func makeCustomChip(index: Int) -> NSButton {
        let chip = ReplyChipButton()         // padded; accepts first mouse → fires while non-key
        chip.isBordered = false
        chip.bezelStyle = .rounded
        chip.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Write a custom reply")
        chip.imagePosition = .imageOnly
        chip.imageScaling = .scaleProportionallyDown
        chip.tag = index
        chip.contentTintColor = .labelColor
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.masksToBounds = true
        chip.target = coordinator
        chip.action = #selector(ToolbarCoordinator.replyChip(_:))
        return chip
    }

    /// Collapsed-badge frame anchored to the field — mirrors `show()`'s placement
    /// (right edge against the field's left edge, top aligned to the field top).
    private func collapsedFrame(near elementFrame: CGRect, caret caretRect: CGRect) -> NSRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let elemAppKitPoint = NSPoint(x: elementFrame.origin.x, y: primaryScreenHeight - elementFrame.origin.y)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(elemAppKitPoint) })?.frame
            ?? NSScreen.main?.frame ?? .zero
        // Vertical: anchor just above the caret line (see show()) so terminals place the
        // badge at the input row, and expanding doesn't cover the input.
        let caretTopAppKit = primaryScreenHeight - caretRect.origin.y
        let origin = NSPoint(x: elementFrame.origin.x - Self.collapsedWidth, y: caretTopAppKit + Self.badgeCaretGap)
        let size = NSSize(width: Self.collapsedWidth, height: Self.panelHeight)
        let clampedX = min(max(screenFrame.minX, origin.x), screenFrame.maxX - size.width - 10)
        let clampedY = min(max(screenFrame.minY + 10, origin.y), screenFrame.maxY - size.height - 10)
        return NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: size)
    }

    // MARK: - Adaptive appearance (follow the real backdrop, not system mode)

    /// Sample the screen behind where the badge sits and flip the panel between
    /// light/dark appearance, so the translucent circle and the template feather
    /// both match the actual backdrop luminance — independent of the system
    /// Light/Dark setting. Re-sampled only when the app/field context changes.
    private func updateBackdropAppearance(near caretRect: CGRect, elementFrame: CGRect, appBundleId: String) {
        // Requires Screen Recording permission; without it (the common case,
        // ScreenContext is opt-in) we leave the appearance to follow system mode.
        guard CGPreflightScreenCaptureAccess() else { return }

        // Degenerate AX geometry — e.g. Chrome's AXWebArea strategy-4 fallback can report a
        // caret y of ~1.8e20 — would overflow the Int() casts below (a hard SIGTRAP) and
        // produce a garbage sample rect. Bail; leave the appearance to system mode this frame.
        guard caretRect.origin.y.isFinite, elementFrame.origin.x.isFinite,
              abs(caretRect.origin.y) < 1e9, abs(elementFrame.origin.x) < 1e9 else { return }

        // Re-sample only when the context changes: the same field row in the same
        // app keeps its result (the backdrop there doesn't move as you type along it).
        // Key on the caret row (where the badge anchors), not the element top.
        // Rounded to 8 pt so sub-pixel field jitter doesn't re-trigger.
        let key = "\(appBundleId)@\(Int(elementFrame.origin.x / 8))x\(Int(caretRect.origin.y / 8))"
        if key == lastLumKey { return }
        lastLumKey = key

        // Read window state on the main thread (NSWindow isn't thread-safe), then
        // run the ~20ms screen capture off-main so show() stays snappy. The
        // appearance flips a frame later, when the sample returns. Sample the caret
        // row (where the badge sits), not the element top — in terminals the focused
        // element is the whole scrollback, so its top is the window top.
        let belowWindow: CGWindowID? = (panel.isVisible && panel.windowNumber > 0) ? CGWindowID(panel.windowNumber) : nil
        let rect = CGRect(x: elementFrame.origin.x - Self.collapsedWidth,
                          y: caretRect.origin.y,
                          width: Self.collapsedWidth, height: Self.panelHeight)
        Task {
            guard let lum = await Self.backdropLuminance(rect: rect, belowWindow: belowWindow) else { return }
            applyBackdrop(luminance: lum)
        }
    }

    /// Apply a sampled backdrop luminance to the badge appearance (on MainActor).
    /// Hysteresis keeps a near-mid-gray backdrop from flip-flopping.
    private func applyBackdrop(luminance lum: Double) {
        let light: Bool
        switch backdropIsLight {
        case .some(true): light = lum > 0.42
        case .some(false): light = lum > 0.58
        case .none: light = lum > 0.5
        }
        guard light != backdropIsLight else { return }
        backdropIsLight = light
        panel.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        if isReplyMode { applyReplyHighlight() }   // re-resolve the selected chip fill for the new appearance
    }

    /// Average luminance (0–1) of the screen region below the badge window, or
    /// nil if capture fails. `nonisolated async` so the blocking capture runs off
    /// the main actor. Draws the region into a 1×1 context — that pixel is the mean.
    private nonisolated static func backdropLuminance(rect: CGRect, belowWindow: CGWindowID?) async -> Double? {
        let image: CGImage?
        if let belowWindow {
            image = CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, belowWindow, [.nominalResolution])
        } else {
            image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.nominalResolution])
        }
        guard let cg = image else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

// MARK: - Coordinator

@MainActor
private class ToolbarCoordinator: NSObject, NSTextFieldDelegate {
    var onBrandTap: (() -> Void)?
    var onAppToggle: (() -> Void)?
    var onGlobalToggle: (() -> Void)?
    var onAppDisableDuration: ((DisableDuration) -> Void)?
    var onGlobalDisableDuration: ((DisableDuration) -> Void)?
    var onSettings: (() -> Void)?
    var onReplyChip: ((Int) -> Void)?
    var onReplyAccept: (() -> Void)?
    var onCustomSubmit: (() -> Void)?
    var onCustomCancel: (() -> Void)?
    var onCustomBackToChips: (() -> Void)?

    @objc func brandTapped() { onBrandTap?() }
    @objc func replyChip(_ sender: NSButton) { onReplyChip?(sender.tag) }
    @objc func replyAccept() { onReplyAccept?() }
    @objc func customSubmitTapped() { onCustomSubmit?() }

    // Custom-intent field: Enter submits, Esc cancels (swallowed so neither beeps).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onCustomSubmit?(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCustomCancel?(); return true
        case #selector(NSResponder.moveLeft(_:)):
            // Left arrow in an empty field steps back to the chips; once text is typed it's a
            // normal caret move (return false so the field editor handles it).
            guard textView.string.isEmpty else { return false }
            onCustomBackToChips?(); return true
        default:
            return false
        }
    }
    @objc func appToggleTapped() { onAppToggle?() }
    @objc func globalToggleTapped() { onGlobalToggle?() }
    @objc func settingsTapped() { onSettings?() }

    @objc func appDisable15() { onAppDisableDuration?(.minutes15) }
    @objc func appDisable60() { onAppDisableDuration?(.minutes60) }
    @objc func appDisableIndef() { onAppDisableDuration?(.indefinitely) }

    @objc func globalDisable15() { onGlobalDisableDuration?(.minutes15) }
    @objc func globalDisable60() { onGlobalDisableDuration?(.minutes60) }
    @objc func globalDisableIndef() { onGlobalDisableDuration?(.indefinitely) }
}
