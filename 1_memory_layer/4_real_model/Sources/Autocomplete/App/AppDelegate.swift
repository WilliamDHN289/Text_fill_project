import AppKit
import Sparkle
import DPHMemory

extension Notification.Name {
    static let providerDidChange = Notification.Name("autocomplete.providerDidChange")
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var engine: Engine?
    private var inputMonitor: InputMonitor?
    private var contextReader: ContextReader?
    private var renderer: Renderer?
    private var textInserter: TextInserter?
    private var settingsManager: SettingsManager?
    private var screenContextManager: ScreenContextManager?
    private var focusMonitor: FocusMonitor?
    private var llamaProvider: LlamaProvider?
    private var modelManager: ModelManager?
    private var downloadProgressWindow: DownloadProgressWindowController?
    private var cloudProvider: CloudProvider?
    private var clipboardHistory: ClipboardHistory?
    private var messageHistory: MessageHistory?
    private let apiKeyPrompt = APIKeyPrompt()
    private var replyController: ReplyController?
    private var usageStatsUploader: UsageStatsUploader?
    private var accessibilityPollTimer: Timer?
    private var onboardingWindow: OnboardingWindowController?

    private var appNapActivity: NSObjectProtocol?
    private let dockPresence = DockPresence()
    private lazy var updaterDelegate = UpdaterDelegate(dockPresence: dockPresence)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: updaterDelegate,
        userDriverDelegate: updaterDelegate
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install death logger first — captures signal-induced exits to ~/.autocomplete-death.log
        DeathLogger.install()

        #if DEBUG
        MailReplyAdapter.runSelfChecks()
        #endif

        // Prevent App Nap — the event tap must stay responsive to keystrokes
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Monitoring keyboard input for inline suggestions"
        )

        // Initialize components
        settingsManager = SettingsManager()
        contextReader = ContextReader()
        renderer = Renderer()
        textInserter = TextInserter()
        screenContextManager = ScreenContextManager(settings: settingsManager!)
        llamaProvider = LlamaProvider()
        modelManager = ModelManager()
        cloudProvider = CloudProvider()
        clipboardHistory = ClipboardHistory()
        clipboardHistory?.start()
        messageHistory = MessageHistory()

        // Activation gate — blocks until user enters a valid invite code or quits.
        InviteCodePrompt.runUntilActivated()

        engine = Engine(
            contextReader: contextReader!,
            renderer: renderer!,
            textInserter: textInserter!,
            cloudProvider: cloudProvider!,
            settings: settingsManager!,
            screenContextManager: screenContextManager!,
            clipboardHistory: clipboardHistory!,
            messageHistory: messageHistory!,
            llamaProvider: llamaProvider
        )

        inputMonitor = InputMonitor()
        inputMonitor?.delegate = engine
        engine?.inputMonitor = inputMonitor

        replyController = ReplyController(
            contextReader: contextReader!,
            screenContext: screenContextManager!,
            cloud: cloudProvider!,
            inserter: textInserter!,
            settings: settingsManager!,
            messageHistory: messageHistory!,
            clipboardHistory: clipboardHistory!,
            toolbar: renderer!.toolbarPanel,
            inputMonitor: inputMonitor
        )
        inputMonitor?.replyController = replyController
        inputMonitor?.onReplyHotkey = { [weak self] in self?.replyController?.trigger() }
        engine?.replyController = replyController
        // Clicking the auto-offered badge runs the normal first-stage draft.
        renderer!.toolbarPanel.onReplyOfferTap = { [weak self] in self?.replyController?.trigger() }

        focusMonitor = FocusMonitor()
        focusMonitor?.delegate = engine
        engine?.focusMonitor = focusMonitor

        settingsWindowController = SettingsWindowController(
            settings: settingsManager!,
            engine: engine!,
            updaterController: updaterController,
            dockPresence: dockPresence
        )
        engine?.onRequestSettings = { [weak self] in
            self?.settingsWindowController?.showWindow()
        }
        menuBarController = MenuBarController(
            settings: settingsManager!,
            engine: engine!,
            settingsWindowController: settingsWindowController!,
            updaterController: updaterController
        )

        usageStatsUploader = UsageStatsUploader(cloud: cloudProvider!)
        usageStatsUploader?.start()

        // Start services
        focusMonitor?.start()

        // First-launch onboarding gates the rest of startup. If the user has
        // already completed it, fall through to the existing per-launch
        // permission check (handles the case where they revoked perms later).
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            startMonitoringIfPermitted()
        }

        // Only load local model if provider is "local"
        if settingsManager?.activeProvider == "local" {
            loadAndWarmupLocalModel()
        }

        // Listen for provider changes to trigger model load/warmup
        NotificationCenter.default.addObserver(
            forName: .providerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let provider = notification.userInfo?["provider"] as? String else { return }
            Task { @MainActor in
                self?.onProviderChanged(to: provider)
            }
        }

        // Re-create event tap after sleep/wake (Mach port can become invalid)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let monitor = self.inputMonitor, monitor.isRunning else { return }
                Log.info("System woke — restarting event tap")
                monitor.stop()
                do {
                    try monitor.start()
                    Log.info("Event tap restarted after wake")
                } catch {
                    Log.error("Failed to restart event tap after wake: \(error)")
                }
            }
        }

        // Dismiss the reply card when the user switches to a different app.
        // Also fires once at launch (before any card exists); harmless — dismiss() is idempotent.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.replyController?.dismiss()
            }
        }

        Log.info("App launched successfully")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController?.showWindow()
        return false
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(settings: settingsManager!, dockPresence: dockPresence) { [weak self] in
            guard let self else { return }
            self.onboardingWindow = nil
            // This fires whether the user clicked Done/Skip or just closed the
            // window mid-flow. Only mark onboarding complete + start monitoring
            // once Accessibility is actually granted; if they bailed before
            // granting it (e.g. closed during the permissions page), leave the
            // flag unset so the next launch re-shows onboarding to finish.
            let trusted = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": false] as CFDictionary
            )
            guard trusted else { return }
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            // Screen Recording was granted during onboarding — turn the feature
            // on by default so the grant has a visible effect.
            self.settingsManager?.isScreenContextEnabled = true
            self.startMonitoringIfPermitted()
        }
        self.onboardingWindow = controller
        controller.show()
    }

    /// Re-shows just the tutorial page (Tab/backtick/Esc lesson) for users
    /// who've already finished onboarding. Done/Skip closes without re-running
    /// permission/monitor side effects.
    func showHowToUse() {
        self.onboardingWindow?.close()
        let controller = OnboardingWindowController(startPage: .tutorial, settings: settingsManager!, includeProfile: false, dockPresence: dockPresence) { [weak self] in
            self?.onboardingWindow = nil
        }
        self.onboardingWindow = controller
        controller.show()
    }

    private func startMonitoringIfPermitted() {
        // Check accessibility silently — don't trigger the system prompt
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        )
        if trusted {
            do {
                try inputMonitor?.start()
                Log.info("InputMonitor started")
            } catch {
                Log.error("Failed to start InputMonitor: \(error)")
            }
            checkScreenCapturePermission()
        } else {
            // Permissions are handled by the formal onboarding window. If AX
            // is missing post-onboarding (e.g., release-bundle signature
            // changed), the user can clear `hasCompletedOnboarding` in
            // UserDefaults to re-show the welcome flow.
            Log.error("Accessibility not granted post-onboarding; InputMonitor disabled.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputMonitor?.stop()
        focusMonitor?.stop()
        // DPHM: flush the habit-memory snapshot before _exit(0) skips
        // everything (the periodic background save may be up to
        // save_interval_s stale).
        DPHMMemory.shared.saveNow()
        llamaProvider?.unloadModel()
        DeathLogger.logNormalExit()
        Log.info("App terminated")
        // Bypass C++ static destructors — llama.cpp's global ggml-metal device
        // vector destructor races with its own background init blocks and crashes
        // with SIGBUS during exit(). _exit(0) skips destructors entirely; the OS
        // reclaims everything cleanly. macOS no longer shows a Problem Report.
        _exit(0)
    }

    /// Warm the local KV cache with the same user-section inputs Engine
    /// attaches to real requests: per-line-normalized user context plus
    /// current clipboard/message snapshots (normalization mirrors
    /// Engine.requestSuggestion). The cache matches by exact tokens, so
    /// inputs that differ from the first real request's waste the warmup.
    private func warmupKVCache(_ llamaProvider: LlamaProvider) async {
        let normalizedUC = TextNormalize.collapsePerLine(settingsManager?.userContext ?? "")
        let clipboardItems = clipboardHistory?.snapshot() ?? []
        let recentMessages = messageHistory?.snapshot().map { $0.text } ?? []
        await llamaProvider.warmup(
            userContext: normalizedUC.isEmpty ? nil : normalizedUC,
            clipboardItems: clipboardItems.isEmpty ? nil : clipboardItems,
            recentMessages: recentMessages.isEmpty ? nil : recentMessages
        )
        // Warmup done — let Engine enable speculative prefills, which share the
        // KV cache and must not race the warmup's memory clear.
        engine?.notifyWarmupComplete()
    }

    /// Load the native llama.cpp model and warmup KV cache with user context.
    /// Called when provider is "local" at startup or when switching to "local".
    private func loadAndWarmupLocalModel() {
        guard let llamaProvider = llamaProvider, let modelManager = modelManager else { return }
        guard !llamaProvider.isModelLoaded else {
            // Already loaded — just warmup with latest user-section inputs
            Task {
                await warmupKVCache(llamaProvider)
            }
            return
        }

        if let path = modelManager.modelPath {
            do {
                try llamaProvider.loadModel(path: path)
                Log.info("Local model loaded")
                Task {
                    await warmupKVCache(llamaProvider)
                }
                #if DEBUG
                // Opt-in mid-decode-cancel stress harness (DEBUG only). Enable via:
                //   defaults write Autocomplete autocomplete.stressMidDecodeCancel -bool true
                let stressEnabled = UserDefaults.standard.bool(forKey: "autocomplete.stressMidDecodeCancel")
                Log.info("[Stress] launch-trigger reached, flag=\(stressEnabled)")
                if stressEnabled {
                    Task { @MainActor in
                        await MidDecodeCancelStress(provider: llamaProvider).run()
                    }
                }
                #endif
            } catch {
                Log.error("Failed to load local model: \(error)")
            }
        } else {
            promptAndDownloadModel(llamaProvider: llamaProvider, modelManager: modelManager)
        }
    }

    private func promptAndDownloadModel(llamaProvider: LlamaProvider, modelManager: ModelManager) {
        let alert = NSAlert()
        alert.messageText = "Download Local AI Model"
        alert.informativeText = "The local provider requires a one-time download of an AI model (~3.4 GB). This model runs entirely on your Mac for fast, private autocomplete.\n\nDownload now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Log.info("User approved local model download")

            let progressWindow = DownloadProgressWindowController(modelManager: modelManager) { [weak modelManager] in
                modelManager?.cancelDownload()
                Log.info("User cancelled local model download mid-flight, reverting to A")
                self.settingsManager?.activeProvider = "openai"
            }
            self.downloadProgressWindow = progressWindow
            progressWindow.show()

            Task {
                do {
                    try await modelManager.downloadModel()
                    if let path = modelManager.modelPath {
                        try llamaProvider.loadModel(path: path)
                        Log.info("Local model downloaded and loaded")
                        await self.warmupKVCache(llamaProvider)
                    }
                } catch {
                    Log.error("Failed to download/load local model: \(error)")
                }
                self.downloadProgressWindow?.close()
                self.downloadProgressWindow = nil
            }
        } else {
            Log.info("User cancelled local model download, reverting to A")
            settingsManager?.activeProvider = "openai"
        }
    }

    /// Called when the user changes the provider selection.
    func onProviderChanged(to provider: String) {
        if provider == "local" {
            loadAndWarmupLocalModel()
        } else {
            llamaProvider?.unloadModel()
        }
    }

    private func checkScreenCapturePermission() {
        guard let settings = settingsManager else { return }
        guard settings.isScreenContextEnabled else { return }

        if !CGPreflightScreenCaptureAccess() {
            Log.info("Screen recording not yet granted — showing alert")
            showScreenRecordingAlert()
        }
    }

    private func showScreenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "Enable Screen Context"
        alert.informativeText = "Enabling Screen Context will greatly improve suggestions. macOS requires the 'Screen Recording' permission for this, but no screenshots or recordings are saved."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Disable Screen Context")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            settingsManager?.isScreenContextEnabled = false
            screenContextManager?.invalidate()
            Log.info("User disabled Screen Context")
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "FlowIn needs Accessibility permission to provide inline suggestions as you type."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func startAccessibilityPolling() {
        let startTime = Date()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                let trusted = AXIsProcessTrustedWithOptions(
                    ["AXTrustedCheckOptionPrompt": false] as CFDictionary
                )

                if trusted {
                    self.accessibilityPollTimer?.invalidate()
                    self.accessibilityPollTimer = nil
                    Log.info("Accessibility granted — starting InputMonitor")
                    do {
                        try self.inputMonitor?.start()
                        Log.info("InputMonitor started after permission grant")
                    } catch {
                        Log.error("Failed to start InputMonitor: \(error)")
                    }
                    self.checkScreenCapturePermission()
                    return
                }

                // Stop polling after 5 minutes — tell user to restart
                if Date().timeIntervalSince(startTime) > 300 {
                    self.accessibilityPollTimer?.invalidate()
                    self.accessibilityPollTimer = nil
                    Log.info("Accessibility polling timed out after 5 minutes")
                    self.showRestartAlert()
                }
            }
        }
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "If you've granted Accessibility permission, please restart Autocomplete for it to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", Bundle.main.bundlePath]
            try? task.run()
            NSApp.terminate(nil)
        }
    }
}
