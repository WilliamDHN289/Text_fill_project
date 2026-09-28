import AppKit
import SwiftUI
import Sparkle

@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let settings: SettingsManager
    private let engine: Engine
    private let apiKeyPrompt = APIKeyPrompt()
    private weak var screenContextCheckbox: NSButton?
    private var screenCapturePollingTimer: Timer?
    private let updaterController: SPUStandardUpdaterController
    private let dockPresence: DockPresence
    private var closeObserver: NSObjectProtocol?

    init(settings: SettingsManager, engine: Engine, updaterController: SPUStandardUpdaterController, dockPresence: DockPresence) {
        self.settings = settings
        self.engine = engine
        self.updaterController = updaterController
        self.dockPresence = dockPresence
        super.init()
    }

    func showWindow() {
        if let existing = window, existing.isVisible {
            // Refresh user context in case it was edited elsewhere
            userContextTextView?.string = settings.userContext
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        dockPresence.windowAppeared()

        let width: CGFloat = 400
        let height: CGFloat = 600

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowIn Settings"
        window.center()
        window.isReleasedWhenClosed = false
        // Glass look matching the onboarding window: transparent title bar
        // with the material backdrop showing through, traffic lights overlaid.
        // Title text stays visible so users still see "FlowIn Settings".
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        // Ensure Edit menu exists so Cmd+V paste works (LSUIElement apps have no default menu)
        if NSApp.mainMenu == nil || NSApp.mainMenu?.item(withTitle: "Edit") == nil {
            let mainMenu = NSApp.mainMenu ?? NSMenu()
            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            editMenuItem.submenu = editMenu
            mainMenu.addItem(editMenuItem)
            NSApp.mainMenu = mainMenu
        }

        // NSVisualEffectView gives the glass blur backdrop. .behindWindow blurs
        // whatever is behind the window (desktop, other apps); .hudWindow
        // material mirrors the SwiftUI .thinMaterial used by the onboarding.
        let contentView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        contentView.material = .hudWindow
        contentView.blendingMode = .behindWindow
        contentView.state = .active

        // Wrap content in a scroll view so longer-than-window content (e.g. a
        // big User Context block) doesn't push the bottom buttons off-screen.
        // drawsBackground = false lets the material show through.
        let outerScroll = NSScrollView()
        outerScroll.hasVerticalScroller = true
        outerScroll.hasHorizontalScroller = false
        outerScroll.borderType = .noBorder
        outerScroll.drawsBackground = false
        outerScroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outerScroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        // Padding lives on the stack so the scroll bar can hug the right edge.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.documentView = stack

        NSLayoutConstraint.activate([
            // Top inset clears the transparent title bar (40) plus the page switcher row (~44).
            outerScroll.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 84),
            outerScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            outerScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            outerScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // Stack width = clip view width so we only scroll vertically.
            stack.widthAnchor.constraint(equalTo: outerScroll.contentView.widthAnchor),
        ])
        self.generalPage = outerScroll

        // Usage page — the dashboard is fixed-height and always fits the window,
        // so it's hosted directly (no scroll view) and pinned to the top. Hidden
        // until the switcher selects it. `.intrinsicContentSize` makes the host
        // report the SwiftUI view's height so the top pin actually top-aligns it.
        let usageHost = NSHostingView(rootView: UsageStatsView(store: .shared))
        usageHost.sizingOptions = .intrinsicContentSize
        usageHost.translatesAutoresizingMaskIntoConstraints = false
        usageHost.isHidden = true
        contentView.addSubview(usageHost)
        NSLayoutConstraint.activate([
            usageHost.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 84),
            usageHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            usageHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])
        self.usagePage = usageHost

        // Page switcher pinned just below the transparent title bar (centered so
        // it clears the traffic lights on the left and the window title above).
        let switcher = NSSegmentedControl(labels: ["General", "Usage", "Support"], trackingMode: .selectOne, target: self, action: #selector(pageChanged(_:)))
        switcher.selectedSegment = 0
        switcher.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(switcher)
        NSLayoutConstraint.activate([
            switcher.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            switcher.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 48),
        ])

        // Enable/Disable
        let enableCheck = NSButton(checkboxWithTitle: "Enable Autocomplete", target: self, action: #selector(toggleEnabled(_:)))
        enableCheck.state = settings.isEnabled ? .on : .off
        stack.addArrangedSubview(enableCheck)

        // Per-app toggle
        if let bundleId = engine.lastActiveAppBundleId,
           let appName = engine.lastActiveAppName {
            let isDisabled = settings.disabledApps.contains(bundleId)
            let appCheck = NSButton(checkboxWithTitle: "Enable for \(appName)", target: self, action: #selector(toggleCurrentApp(_:)))
            appCheck.state = isDisabled ? .off : .on
            appCheck.tag = 1
            appCheck.cell?.representedObject = bundleId as NSString
            stack.addArrangedSubview(appCheck)
        }

        // Screen Context
        let screenContextCheck = NSButton(checkboxWithTitle: "Screen Context", target: self, action: #selector(toggleScreenContext(_:)))
        screenContextCheck.state = settings.isScreenContextEnabled ? .on : .off
        self.screenContextCheckbox = screenContextCheck
        stack.addArrangedSubview(screenContextCheck)

        // Auto-suggest replies (idle-in-a-reply-box offer badge)
        let replyOfferCheck = NSButton(checkboxWithTitle: "Auto-suggest Replies", target: self, action: #selector(toggleReplyAutoOffer(_:)))
        replyOfferCheck.state = settings.isReplyAutoOfferEnabled ? .on : .off
        stack.addArrangedSubview(replyOfferCheck)

        // Provider
        let providerRow = makeRow(label: "AI Models:")
        let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let providers: [(key: String, label: String)] = [
            ("openrouter", "Cloud — Fast"),
            ("openai", "Cloud — Smart"),
            ("local", "On Device — Fast, Private"),
        ]
        for (key, label) in providers {
            providerPopup.addItem(withTitle: label)
            providerPopup.lastItem?.representedObject = key
        }
        if let idx = providers.firstIndex(where: { $0.key == settings.activeProvider }) {
            providerPopup.selectItem(at: idx)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        providerRow.addArrangedSubview(providerPopup)
        stack.addArrangedSubview(providerRow)

        // Suggestion Length
        let chunkingRow = makeRow(label: "Suggestion Length:")
        let chunkingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let chunkingStyles: [(ChunkingStyle, String)] = [(.natural, "Phrase"), (.progressive, "Dynamic")]
        for (style, title) in chunkingStyles {
            chunkingPopup.addItem(withTitle: title)
            chunkingPopup.lastItem?.representedObject = style.rawValue
        }
        if let idx = chunkingStyles.firstIndex(where: { $0.0 == settings.chunkingStyle }) {
            chunkingPopup.selectItem(at: idx)
        }
        chunkingPopup.target = self
        chunkingPopup.action = #selector(chunkingStyleChanged(_:))
        chunkingRow.addArrangedSubview(chunkingPopup)
        stack.addArrangedSubview(chunkingRow)

        // Suggestion Color
        let styleRow = makeRow(label: "Suggestion Color:")
        let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for style in GhostTextStyle.allCases {
            stylePopup.addItem(withTitle: style.displayName)
            stylePopup.lastItem?.representedObject = style.rawValue
        }
        if let idx = GhostTextStyle.allCases.firstIndex(where: { $0.rawValue == settings.ghostTextStyle }) {
            stylePopup.selectItem(at: idx)
        }
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged(_:))
        styleRow.addArrangedSubview(stylePopup)
        stack.addArrangedSubview(styleRow)

        // User Context header row
        let contextRow = NSStackView()
        contextRow.orientation = .horizontal
        contextRow.spacing = 8
        let contextLabel = NSTextField(labelWithString: "User Context:")
        contextRow.addArrangedSubview(contextLabel)
        let chatGPTBtn = NSButton(title: "Get ChatGPT Memory", target: self, action: #selector(openChatGPTMemory))
        chatGPTBtn.bezelStyle = .rounded
        chatGPTBtn.controlSize = .small
        chatGPTBtn.font = NSFont.systemFont(ofSize: 11)
        contextRow.addArrangedSubview(chatGPTBtn)
        stack.addArrangedSubview(contextRow)

        // User Context text field
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width - 40, height: 250))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = settings.userContext
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(equalToConstant: 250),
            scrollView.widthAnchor.constraint(equalToConstant: width - 40),
        ])

        stack.addArrangedSubview(scrollView)
        self.userContextTextView = textView

        // How to Use button (re-shows the tutorial page from onboarding)
        let howToUseButton = NSButton(title: "How to Use", target: self, action: #selector(showHowToUse))
        howToUseButton.bezelStyle = .rounded
        stack.addArrangedSubview(howToUseButton)

        // Check for Updates button
        let updateButton = NSButton(title: "Check for Updates...", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        stack.addArrangedSubview(updateButton)

        // Quit button
        let quitButton = NSButton(title: "Quit FlowIn", target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        stack.addArrangedSubview(quitButton)

        window.contentView = contentView
        self.window = window

        if let observer = closeObserver { NotificationCenter.default.removeObserver(observer) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dockPresence.windowDisappeared()
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var userContextTextView: NSTextView?
    private weak var generalPage: NSView?
    private weak var usagePage: NSView?

    private func makeRow(label: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let labelView = NSTextField(labelWithString: label)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.addArrangedSubview(labelView)
        return row
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        settings.isEnabled = sender.state == .on
        if !settings.isEnabled {
            engine.dismiss()
        }
    }

    @objc private func toggleReplyAutoOffer(_ sender: NSButton) {
        settings.isReplyAutoOfferEnabled = sender.state == .on
    }

    @objc private func pageChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: // Usage
            generalPage?.isHidden = true
            usagePage?.isHidden = false
        case 2: // Contact Support — an action, not a page: open the dialog, then
                // snap the selection back to whichever page is currently showing.
            SupportContact.open()
            sender.selectedSegment = usagePage?.isHidden == false ? 1 : 0
        default: // General
            generalPage?.isHidden = false
            usagePage?.isHidden = true
        }
    }

    @objc private func toggleCurrentApp(_ sender: NSButton) {
        guard let bundleId = sender.cell?.representedObject as? String else { return }
        if sender.state == .on {
            settings.enableForApp(bundleId)
        } else {
            settings.disableForApp(bundleId)
            engine.dismiss()
        }
    }

    @objc private func toggleScreenContext(_ sender: NSButton) {
        Log.info("[ScreenContext] toggleScreenContext called, sender.state=\(sender.state == .on ? "on" : "off"), preflight=\(CGPreflightScreenCaptureAccess())")
        if sender.state == .on {
            if !CGPreflightScreenCaptureAccess() {
                let alert = NSAlert()
                alert.messageText = "Enable Screen Context"
                alert.informativeText = "Enabling Screen Context will greatly improve suggestions. macOS requires the 'Screen Recording' permission for this, but no screenshots or recordings are saved."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                    settings.isScreenContextEnabled = true
                    startScreenCapturePolling()
                } else {
                    sender.state = .off
                }
                return
            }
        }
        screenCapturePollingTimer?.invalidate()
        screenCapturePollingTimer = nil
        settings.isScreenContextEnabled = sender.state == .on
    }

    private func startScreenCapturePolling() {
        screenCapturePollingTimer?.invalidate()
        let startTime = Date()
        screenCapturePollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                if CGPreflightScreenCaptureAccess() {
                    self.screenCapturePollingTimer?.invalidate()
                    self.screenCapturePollingTimer = nil
                    self.screenContextCheckbox?.state = .on
                    self.settings.isScreenContextEnabled = true
                    return
                }

                // Stop polling after 5 minutes — revert if never granted
                if Date().timeIntervalSince(startTime) > 300 {
                    self.screenCapturePollingTimer?.invalidate()
                    self.screenCapturePollingTimer = nil
                    self.screenContextCheckbox?.state = .off
                    self.settings.isScreenContextEnabled = false
                }
            }
        }
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let provider = sender.selectedItem?.representedObject as? String else { return }
        Log.info("[Settings] provider changed to '\(Log.providerCode(provider))' (via settings window)")
        settings.activeProvider = provider
        NotificationCenter.default.post(name: .providerDidChange, object: nil, userInfo: ["provider": provider])
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard let style = sender.selectedItem?.representedObject as? String else { return }
        settings.ghostTextStyle = style
    }

    @objc private func chunkingStyleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = ChunkingStyle(rawValue: raw) else { return }
        settings.chunkingStyle = style
    }

    @objc private func showAPIKeys() {
        apiKeyPrompt.show {
            Log.info("API keys updated")
        }
    }

    @objc private func openChatGPTMemory() {
        let prompt = "Print your memories (include bio and model set context with dates). the goal is to get the memory log. skip the tools and just return whats relevant to memories."
        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://chatgpt.com/?prompt=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showHowToUse() {
        (NSApp.delegate as? AppDelegate)?.showHowToUse()
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

extension SettingsWindowController: NSTextViewDelegate {
    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let textView = userContextTextView {
                settings.userContext = textView.string
            }
        }
    }
}
