import AppKit
import Combine
import Sparkle

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: SettingsManager
    private let engine: Engine
    private let menu = NSMenu()
    private let apiKeyPrompt = APIKeyPrompt()
    private let userContextEditor = UserContextEditor()
    private weak var settingsWindowController: SettingsWindowController?
    private var screenCapturePollingTimer: Timer?
    private let updaterController: SPUStandardUpdaterController
    private var statsCancellable: AnyCancellable?

    init(settings: SettingsManager, engine: Engine, settingsWindowController: SettingsWindowController, updaterController: SPUStandardUpdaterController) {
        self.settings = settings
        self.engine = engine
        self.settingsWindowController = settingsWindowController
        self.updaterController = updaterController

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }

        // Show today's words-saved tally to the right of the title, updated live
        // as completions/replies are accepted (and on day rollover via the next save).
        statsCancellable = UsageStatsStore.shared.$days
            .sink { [weak self] days in
                self?.updateTitle(todayWords: days[UsageStatsStore.shared.currentDayKey]?.words ?? 0)
            }

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Render the menu-bar title: just the wordmark until the first word is
    /// saved today, then the wordmark plus the running word count.
    private func updateTitle(todayWords words: Int) {
        guard let button = statusItem.button else { return }
        button.title = words > 0 ? "FlowIn \(words)" : "FlowIn"
        button.toolTip = "\(words) \(words == 1 ? "word" : "words") saved today"
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            buildMenu()
        }
    }

    private func buildMenu() {
        menu.removeAllItems()

        // Status
        let statusTitle = settings.isEnabled ? "FlowIn: On" : "FlowIn: Off"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle global
        let toggleTitle = settings.isEnabled ? "Disable" : "Enable"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleEnabled), keyEquivalent: "e")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Per-app toggle for the last active app (not FlowIn itself)
        if let bundleId = engine.lastActiveAppBundleId,
           let appName = engine.lastActiveAppName {
            let isAppDisabled = settings.disabledApps.contains(bundleId)
            let appToggleTitle = isAppDisabled
                ? "Enable for \(appName)"
                : "Disable for \(appName)"
            let appToggleItem = NSMenuItem(title: appToggleTitle, action: #selector(toggleCurrentApp(_:)), keyEquivalent: "")
            appToggleItem.target = self
            appToggleItem.representedObject = bundleId
            menu.addItem(appToggleItem)
        }

        // Screen context toggle
        let screenContextTitle = settings.isScreenContextEnabled
            ? "Screen Context: On"
            : "Screen Context: Off"
        let screenContextItem = NSMenuItem(title: screenContextTitle, action: #selector(toggleScreenContext), keyEquivalent: "")
        screenContextItem.target = self
        menu.addItem(screenContextItem)

        menu.addItem(NSMenuItem.separator())

        // Provider submenu
        let providerMenu = NSMenu()
        let providers: [(key: String, label: String)] = [
            ("openrouter", "Cloud — Fast"),
            ("openai", "Cloud — Smart"),
            ("local", "On Device — Fast, Private"),
        ]
        for (key, label) in providers {
            let item = NSMenuItem(title: label, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            if key == settings.activeProvider {
                item.state = .on
            }
            providerMenu.addItem(item)
        }
        let providerItem = NSMenuItem(title: "AI Models", action: nil, keyEquivalent: "")
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        // Suggestion Length submenu
        let chunkingMenu = NSMenu()
        for style: ChunkingStyle in [.natural, .progressive] {
            let title = style == .progressive ? "Dynamic" : "Phrase"
            let item = NSMenuItem(title: title, action: #selector(selectChunkingStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            if style == settings.chunkingStyle {
                item.state = .on
            }
            chunkingMenu.addItem(item)
        }
        let chunkingItem = NSMenuItem(title: "Suggestion Length", action: nil, keyEquivalent: "")
        chunkingItem.submenu = chunkingMenu
        menu.addItem(chunkingItem)

        // User Context
        let userContextItem = NSMenuItem(title: "User Context...", action: #selector(showUserContextEditor), keyEquivalent: "")
        userContextItem.target = self
        menu.addItem(userContextItem)

        // Text Style submenu
        let styleMenu = NSMenu()
        for style in GhostTextStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectTextStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            if style.rawValue == settings.ghostTextStyle {
                item.state = .on
            }
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Suggestion Color", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(NSMenuItem.separator())

        // How to Use (re-shows the tutorial page from onboarding)
        let howToUseItem = NSMenuItem(title: "How to Use...", action: #selector(showHowToUse), keyEquivalent: "")
        howToUseItem.target = self
        menu.addItem(howToUseItem)

        // Contact Support (opens a pre-addressed support email)
        let contactItem = NSMenuItem(title: "Contact Support", action: #selector(contactSupport), keyEquivalent: "")
        contactItem.target = self
        menu.addItem(contactItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit FlowIn", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        if !settings.isEnabled {
            engine.dismiss()
        }
    }

    @objc private func toggleCurrentApp(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        if settings.disabledApps.contains(bundleId) {
            settings.enableForApp(bundleId)
        } else {
            settings.disableForApp(bundleId)
            engine.dismiss()
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        Log.info("[Settings] provider changed to '\(Log.providerCode(provider))' (via menubar)")
        settings.activeProvider = provider
        NotificationCenter.default.post(name: .providerDidChange, object: nil, userInfo: ["provider": provider])
    }

    @objc private func selectTextStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        settings.ghostTextStyle = style
    }

    @objc private func selectChunkingStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = ChunkingStyle(rawValue: raw) else { return }
        settings.chunkingStyle = style
    }

    @objc private func toggleScreenContext() {
        if !settings.isScreenContextEnabled {
            // Turning on — check permission first
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
                }
                return
            }
        }
        settings.isScreenContextEnabled.toggle()
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
                    return
                }

                // Stop polling after 5 minutes — revert if never granted
                if Date().timeIntervalSince(startTime) > 300 {
                    self.screenCapturePollingTimer?.invalidate()
                    self.screenCapturePollingTimer = nil
                    self.settings.isScreenContextEnabled = false
                }
            }
        }
    }

    @objc private func showUserContextEditor() {
        userContextEditor.show(settings: settings)
    }

    @objc private func showAPIKeyPrompt() {
        apiKeyPrompt.show {
            Log.info("API keys updated")
        }
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func showSettings() {
        settingsWindowController?.showWindow()
    }

    @objc private func showHowToUse() {
        (NSApp.delegate as? AppDelegate)?.showHowToUse()
    }

    @objc private func contactSupport() {
        SupportContact.open()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
