import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    enum Page: Equatable { case permissions, tutorial, reply, profile }

    private let onCompletion: () -> Void
    private let dockPresence: DockPresence
    private var closeObserver: NSObjectProtocol?
    private var dockBumped = false
    private var didComplete = false

    init(startPage: Page = .permissions, settings: SettingsManager, includeProfile: Bool = true, dockPresence: DockPresence, onCompletion: @escaping () -> Void) {
        self.onCompletion = onCompletion
        self.dockPresence = dockPresence

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to FlowIn"
        window.isReleasedWhenClosed = false
        window.center()
        // Glass look: content extends behind a transparent title bar with the
        // material backdrop showing through. Traffic lights stay overlaid.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear

        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingRootView(
            startPage: startPage,
            settings: settings,
            includeProfile: includeProfile,
            onContinue: { [weak self] in
                guard let self else { return }
                self.complete()
                self.close()
            },
            onQuit: { NSApp.terminate(nil) }
        ))

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.dockBumped {
                    self.dockBumped = false
                    self.dockPresence.windowDisappeared()
                }
                // Closing the window (red X / Cmd-W) at any step counts as
                // finishing onboarding, so the app still starts normally
                // instead of leaving the user with no autocomplete.
                self.complete()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // LSUIElement app has no default menu bar; install an Edit menu so the
        // profile page's text editor supports Cmd+V / Cmd+C / Cmd+A.
        EditMenuSupport.ensureEditMenu()
        if !dockBumped {
            dockBumped = true
            dockPresence.windowAppeared()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Runs the completion callback exactly once, whether the user clicked
    /// Done/Skip (via onContinue) or simply closed the window (red X / Cmd-W).
    /// Guarantees the app starts normally on any exit path.
    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        onCompletion()
    }
}

// MARK: - Root: page switcher

private struct OnboardingRootView: View {
    let settings: SettingsManager
    let includeProfile: Bool
    let onContinue: () -> Void
    let onQuit: () -> Void
    let startPage: OnboardingWindowController.Page

    @State private var currentPage: OnboardingWindowController.Page

    init(
        startPage: OnboardingWindowController.Page,
        settings: SettingsManager,
        includeProfile: Bool,
        onContinue: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.settings = settings
        self.includeProfile = includeProfile
        self.onContinue = onContinue
        self.onQuit = onQuit
        self.startPage = startPage
        self._currentPage = State(initialValue: startPage)
    }

    var body: some View {
        Group {
            switch currentPage {
            case .permissions:
                PermissionsPage(
                    onContinue: { currentPage = .tutorial },
                    onQuit: onQuit
                )
            case .tutorial:
                TutorialPage(
                    onComplete: { currentPage = .reply },
                    onBack: startPage == .tutorial ? nil : { currentPage = .permissions },
                    onQuit: onQuit
                )
            case .reply:
                ReplyTutorialPage(
                    onContinue: { if includeProfile { currentPage = .profile } else { onContinue() } },
                    onBack: { currentPage = .tutorial }
                )
            case .profile:
                ProfilePage(
                    settings: settings,
                    onComplete: onContinue,
                    onBack: { currentPage = .reply }
                )
            }
        }
        .frame(width: 520, height: 580, alignment: .topLeading)
        .background(.thinMaterial)
        .animation(.easeInOut(duration: 0.25), value: currentPage)
    }
}

// MARK: - Page 1: permissions

private struct PermissionsPage: View {
    let onContinue: () -> Void
    let onQuit: () -> Void

    @State private var accessibilityGranted = AXIsProcessTrustedWithOptions(nil)
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @State private var pollTimer: Timer?

    private var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up FlowIn")
                .font(.system(size: 24, weight: .semibold))
            Text("Two quick permissions to get started.")
                .foregroundStyle(.secondary)

            Divider()

            stepRow(
                number: "1",
                title: "Grant Accessibility",
                body: "Required so FlowIn can suggest completions inline.",
                done: accessibilityGranted,
                action: {
                    openSystemPrefs("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            )

            if accessibilityGranted || screenRecordingGranted {
                stepRow(
                    number: "2",
                    title: "Grant Screen Recording",
                    body: "FlowIn uses on-screen context for better suggestions. Data stays on your Mac.",
                    done: screenRecordingGranted,
                    action: {
                        // First call triggers the macOS permission popup AND registers
                        // the app in System Settings → Screen Recording. Subsequent calls
                        // are silent. Without this, the user must add FlowIn manually
                        // via the "+" button.
                        _ = CGRequestScreenCaptureAccess()
                        openSystemPrefs("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            HStack {
                Button("Quit", action: onQuit)
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allGranted)
            }
        }
        .padding(32)
        .animation(.easeInOut(duration: 0.3), value: accessibilityGranted)
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
    }

    @ViewBuilder
    private func stepRow(
        number: String,
        title: String,
        body: String,
        done: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Text(number)
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary)
                Button(action: action) {
                    Label(done ? "Done" : "Open System Settings",
                          systemImage: done ? "checkmark" : "gear")
                }
                .buttonStyle(SoftPillButtonStyle())
                .disabled(done)
                .padding(.top, 6)
            }
        }
    }

    private func openSystemPrefs(_ url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // Poll every 250ms so post-relaunch state is picked up quickly.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                accessibilityGranted = AXIsProcessTrustedWithOptions(nil)
                screenRecordingGranted = CGPreflightScreenCaptureAccess()
            }
        }
    }
}

// MARK: - Page 2: tutorial

private struct TutorialPage: View {
    let onComplete: () -> Void
    let onBack: (() -> Void)?
    let onQuit: () -> Void

    @State private var step1WordsAccepted = 0
    @State private var step2Revealed = false
    @State private var step2Done = false
    @State private var step3Revealed = false
    @State private var step3CycleIndex = 0
    @State private var step3CyclePresses = 0
    @State private var step4EscPressed = false
    @State private var keyMonitor: Any?

    private let step1Ghost = "quick brown fox"
    private var step1WordCount: Int { step1Ghost.split(separator: " ").count }
    private var step1Done: Bool { step1WordsAccepted >= step1WordCount }

    private var step3Done: Bool { step3CyclePresses >= step3Alternates.count }

    // Step 4 reveals once steps 1–3 are complete; presses Esc once to mark
    // complete, which also dismisses the mock ghost text.
    private var step4Revealed: Bool { step1Done && step2Done && step3Done }
    private var step4Done: Bool { step4EscPressed }

    // Tutorial complete = all four interactive rows done. Gates Done button.
    private var allDone: Bool { step1Done && step2Done && step3Done && step4Done }

    private var isStep1Active: Bool { !step1Done }
    private var isStep2Active: Bool { step2Revealed && !step2Done }
    private var isStep3Active: Bool { step3Revealed && !step3Done }
    private var isStep4Active: Bool { step4Revealed && !step4Done }

    private let step3Prefix = "Hi, "
    private let step3Alternates = [
        "how are you?",
        "got a minute?",
        "are you around?"
    ]
    private let step4Prefix = "Hi, "
    private let step4Ghost = "great to hear from you"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Try it out")
                .font(.system(size: 24, weight: .semibold))
            Text("Four keys to remember.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 40) {
                if step1Done {
                    // Compact done layout — graphic disappears once step 1
                    // is finished, recovering vertical space.
                    tutorialRow(
                        number: "1",
                        title: "Press Tab to accept word by word",
                        done: true,
                        trailing: AnyView(
                            MockField(
                                prefix: "The ",
                                ghost: step1Ghost,
                                accepted: acceptedStep1,
                                active: false,
                                keyHint: "Tab",
                                keyExplanation: nil
                            )
                        )
                    )
                } else {
                    // Active layout: title above, left-side keyboard graphic
                    // (with Tab highlighted) + mock field side by side beneath.
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 28, height: 28)
                            Text("1")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Press Tab to accept word by word")
                                .font(.headline)
                            HStack(alignment: .top, spacing: 12) {
                                KeyboardSliceGraphic(side: .left, highlighted: ["tab"])
                                MockField(
                                    prefix: "The ",
                                    ghost: step1Ghost,
                                    accepted: acceptedStep1,
                                    active: true,
                                    keyHint: "Tab",
                                    keyExplanation: nil
                                )
                            }
                        }
                        Spacer(minLength: 8)
                    }
                }

                if step2Revealed {
                    if step2Done {
                        // Compact done layout — graphic disappears once
                        // step 2 is finished, recovering vertical space.
                        tutorialRow(
                            number: "2",
                            title: "Press ` to accept the whole suggestion",
                            done: true,
                            trailing: AnyView(
                                MockField(
                                    prefix: "Hi, ",
                                    ghost: "how are you today?",
                                    accepted: "how are you today?",
                                    active: false,
                                    keyHint: "`",
                                    keyExplanation: "(backtick)"
                                )
                            )
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        // Active layout: title above, keyboard graphic +
                        // mock field side by side beneath.
                        HStack(alignment: .top, spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 28, height: 28)
                                Text("2")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Press ` to accept the whole suggestion")
                                    .font(.headline)
                                HStack(alignment: .top, spacing: 12) {
                                    KeyboardSliceGraphic(side: .left, highlighted: ["`"])
                                    MockField(
                                        prefix: "Hi, ",
                                        ghost: "how are you today?",
                                        accepted: "",
                                        active: true,
                                        keyHint: "`",
                                        keyExplanation: "(backtick)"
                                    )
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if step3Revealed {
                    if step3Done {
                        // Compact done layout — graphic disappears once
                        // step 3 is finished, recovering vertical space so
                        // step 4 has room to expand.
                        tutorialRow(
                            number: "3",
                            title: "Press right ⌘ + ↓ to cycle through alternative suggestions",
                            done: true,
                            trailing: AnyView(
                                CycleMockField(
                                    prefix: step3Prefix,
                                    ghost: step3Alternates[step3CycleIndex],
                                    active: false
                                )
                            )
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        // Active layout: title above, right-side keyboard
                        // graphic (with ⌘ and ↓ highlighted) + cycle mock
                        // field side by side beneath.
                        HStack(alignment: .top, spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 28, height: 28)
                                Text("3")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Press right ⌘ + ↓ to cycle through alternative suggestions")
                                    .font(.headline)
                                HStack(alignment: .top, spacing: 12) {
                                    KeyboardSliceGraphic(side: .right, highlighted: ["⌘", "↓"])
                                    CycleMockField(
                                        prefix: step3Prefix,
                                        ghost: step3Alternates[step3CycleIndex],
                                        active: true
                                    )
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if step4Revealed {
                    // Step 4 has no keyboard graphic, so it uses the compact
                    // tutorialRow layout — title on the left (wraps if long),
                    // mock field on the right. Ghost text disappears when
                    // step 4 is done, mirroring the real Esc dismissal.
                    tutorialRow(
                        number: "4",
                        title: "Press Esc to dismiss the suggestion",
                        done: step4Done,
                        trailing: AnyView(
                            MockField(
                                prefix: step4Prefix,
                                ghost: step4Done ? "" : step4Ghost,
                                accepted: "",
                                active: isStep4Active,
                                keyHint: "Esc",
                                keyExplanation: nil
                            )
                        )
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Skip", action: onComplete)
                if let onBack {
                    Button("Back", action: onBack)
                }
                Spacer()
                Button("Done", action: onComplete)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allDone)
            }
        }
        .padding(32)
        .animation(.easeInOut(duration: 0.25), value: step1Done)
        .animation(.easeInOut(duration: 0.25), value: step2Revealed)
        .animation(.easeInOut(duration: 0.25), value: step2Done)
        .animation(.easeInOut(duration: 0.25), value: step3Revealed)
        .animation(.easeInOut(duration: 0.25), value: step3Done)
        .animation(.easeInOut(duration: 0.25), value: step4Revealed)
        .animation(.easeInOut(duration: 0.25), value: step4Done)
        .animation(.easeInOut(duration: 0.25), value: allDone)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var acceptedStep1: String {
        let words = step1Ghost.split(separator: " ").map(String.init)
        return words.prefix(step1WordsAccepted).joined(separator: " ")
    }

    // Tab = keyCode 48, backtick = 50, Down = 125, Up = 126. Use a local
    // monitor so we can consume Tab (which would otherwise trigger SwiftUI
    // focus traversal) and backtick (which would otherwise type a literal `)
    // without needing macOS 14's `.onKeyPress`. Right-Command is detected via
    // the 0x10 raw modifier bit (NX_DEVICERCMDKEYMASK) — same gate the real
    // Engine uses, so the tutorial trains the actual gesture.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let isRightCommand = (event.modifierFlags.rawValue & 0x10) != 0
            let consumed: Bool = MainActor.assumeIsolated {
                // Step 1: Tab accepts one word per press.
                if keyCode == 48, isStep1Active {
                    step1WordsAccepted = min(step1WordsAccepted + 1, step1WordCount)
                    if step1WordsAccepted >= step1WordCount {
                        // Last word accepted — beat before step 2 appears so the
                        // user notices the checkmark before the next row.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            step2Revealed = true
                        }
                    }
                    return true
                }
                // Step 2: backtick accepts the whole suggestion in one press.
                if keyCode == 50, isStep2Active {
                    step2Done = true
                    // Beat before step 3 appears so the user notices the
                    // checkmark before the next row (mirrors step 1 → step 2).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        step3Revealed = true
                    }
                    return true
                }
                // Step 3 cycle: right ⌘↓ next, right ⌘↑ previous. Either
                // direction counts toward step3Done — the goal is "user
                // explored the alternates", not "user pressed the exact
                // key the title named".
                if step3Revealed, isRightCommand, keyCode == 125 {
                    step3CycleIndex = (step3CycleIndex + 1) % step3Alternates.count
                    step3CyclePresses += 1
                    return true
                }
                if step3Revealed, isRightCommand, keyCode == 126 {
                    step3CycleIndex = (step3CycleIndex - 1 + step3Alternates.count) % step3Alternates.count
                    step3CyclePresses += 1
                    return true
                }
                // Step 4 dismiss: Esc once revealed and not yet done.
                if isStep4Active, keyCode == 53 {
                    step4EscPressed = true
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    @ViewBuilder
    private func tutorialRow(
        number: String,
        title: String,
        done: Bool,
        trailing: AnyView
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Text(number)
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            trailing
        }
    }
}

// MARK: - Page 3: reply drafting

/// Interactive demo of the reply-draft feature. Shows a mock chat from "Sam",
/// prompts the user to tap the *real* right-Option key, then faithfully
/// reproduces the live badge → chips → preview → accept flow in SwiftUI. The
/// chips and drafts are scripted (no Engine, no cloud, no insertion), but the
/// gesture is the genuine article — the same right-⌥ tap, ← → to choose, ⏎ to
/// draft then accept, esc to dismiss — so it transfers 1:1 to the real feature.
/// Continue is always enabled; the demo is encouraged but optional.
private struct ReplyTutorialPage: View {
    let onContinue: () -> Void
    let onBack: () -> Void

    private enum Stage: Equatable { case idle, loading, chips, preview, accepted }

    @State private var stage: Stage = .idle
    @State private var highlight = 0            // 0..<chips.count = intent, == chips.count = ✎
    @State private var editingCustom = false
    @State private var customText = ""
    @State private var sentDraft: String?
    @State private var pulsing = false
    @State private var rightOptionArmed = false
    @State private var coachHeld = false        // hold the initial coachmark briefly after the ⌥ tap
    @State private var triggerToken = 0          // invalidates stale delayed transitions
    @State private var keyMonitor: Any?
    @FocusState private var customFocused: Bool

    // Scripted "reconnect / networking" conversation. Drafts are em-dash-free
    // and end on a question, mirroring the real stage-2 voice.
    private let contactName = "Sam"
    private let incoming = "Great meeting you today! Let's grab coffee soon."
    private let chips = ["I'd love to", "Suggest a time", "Keep in touch"]
    private let drafts = [
        "Likewise, I'd love to grab coffee. How's next week?",
        "I'd love to! Would Tuesday or Thursday afternoon work?",
        "Great meeting you too! I'll reach out once things settle."
    ]
    private let customDraft = "Of course, I'd really enjoy that! Want me to find a couple of times that work for us?"

    private var pencilIndex: Int { chips.count }
    private var onPencil: Bool { highlight == pencilIndex }
    private var currentDraft: String { onPencil ? customDraft : drafts[min(highlight, drafts.count - 1)] }

    // After the ⌥ tap the coachmark holds its initial state for 2s (coachHeld)
    // so the slice + copy don't change at the same instant the panel expands —
    // only one thing moves at a time, which is less confusing.
    private var effectiveCoachStage: Stage { coachHeld ? .idle : stage }

    // The slice highlights whatever gesture comes next; once the panel is up the
    // highlighted key alone carries it, so the copy drops away.
    private var hintKeys: Set<String> {
        switch effectiveCoachStage {
        case .idle, .loading: return ["⌥"]
        case .chips: return ["←", "→"]
        case .preview: return ["return"]
        case .accepted: return []
        }
    }

    private var instruction: String {
        switch effectiveCoachStage {
        case .idle, .loading: return "Tap the right ⌥ (Option) key."
        case .chips, .preview: return ""          // the highlighted arrows / return say it
        case .accepted: return "Done!"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft a reply anywhere")
                .font(.system(size: 24, weight: .semibold))

            Divider()

            // Coachmark: the right-side keyboard slice (slightly reduced to save
            // vertical room) beside a step instruction. The highlighted key
            // tracks the next gesture: ⌥ → ← → → ⏎.
            HStack(alignment: .center, spacing: 16) {
                KeyboardSliceGraphic(side: .right, highlighted: hintKeys)
                    .scaleEffect(0.80, anchor: .topLeading)
                    .frame(width: 148, height: 108, alignment: .topLeading)
                if !instruction.isEmpty {
                    Text(instruction)
                        .font(.system(size: 13))
                        .foregroundStyle(effectiveCoachStage == .accepted ? Color.green : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            chatPanel

            Spacer(minLength: 0)

            HStack {
                Button("Back", action: onBack)
                Spacer()
                // No .defaultAction: ⏎ drives the demo (draft / accept), so
                // binding Return to Continue would collide. Click to advance.
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .animation(.easeInOut(duration: 0.25), value: stage)
        .animation(.easeInOut(duration: 0.25), value: highlight)
        .animation(.easeInOut(duration: 0.25), value: editingCustom)
        .animation(.easeInOut(duration: 0.25), value: sentDraft)
        .animation(.easeInOut(duration: 0.25), value: coachHeld)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: chat + reproduced reply UI

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text(String(contactName.prefix(1)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
                Text(contactName).font(.system(size: 13, weight: .semibold))
            }

            bubble(incoming, incoming: true)

            if let sentDraft {
                bubble(sentDraft, incoming: false)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if stage == .accepted {
                Button(action: resetDemo) {
                    Label("Try again", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            } else {
                // Reply UI floats just above the field; only the badge triggers.
                VStack(alignment: .leading, spacing: 6) {
                    replyUI
                    fieldRow
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }

    /// The reply UI floats just above the text field, left-aligned. Idle shows
    /// the 28pt feather badge; tapping it expands *rightward* into the chips
    /// pill, which then grows *downward* into the fixed-width preview. Mirrors
    /// the real anchor: the badge sits just above the field and the card grows
    /// out of it (rightward, then down) rather than dropping in from above.
    @ViewBuilder
    private var replyUI: some View {
        if stage == .idle || stage == .loading {
            badgeCircle
        } else {
            replyPill
                .transition(.scale(scale: 0.15, anchor: .topLeading).combined(with: .opacity))
        }
    }

    private var badgeCircle: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            featherView(size: 18).opacity(pulsing ? 0.35 : 1.0)
        }
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .contentShape(Circle())
        .onTapGesture { if stage == .idle { trigger() } }   // only the badge triggers stage 1
    }

    /// Fixed panel width so the preview draft wraps to new lines instead of
    /// overflowing. Wide enough to hold the chip row on one line, narrow enough
    /// to sit inside the mock chat.
    private static let expandedPanelWidth: CGFloat = 392

    private var replyPill: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Chip row — grows rightward out of the leading feather.
            HStack(spacing: 8) {
                featherView(size: 16)
                ForEach(Array(chips.enumerated()), id: \.offset) { i, label in
                    chipView(label: label, index: i)
                }
                chipPencil
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Preview grows downward at the same fixed width; the draft wraps.
            if stage == .preview {
                Divider().padding(.horizontal, 8)
                if editingCustom {
                    customFieldRow
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(currentDraft)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(NSColor.labelColor))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Spacer()
                            Button(action: accept) {
                                Text("Accept ⏎").font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: Self.expandedPanelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    private var fieldRow: some View {
        HStack(spacing: 8) {
            Text("Reply to \(contactName)…")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private var customFieldRow: some View {
        HStack(spacing: 6) {
            TextField("Type your own reply direction…", text: $customText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($customFocused)
                .onSubmit { submitCustom() }
            Button(action: submitCustom) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func chipView(label: String, index: Int) -> some View {
        let selected = (highlight == index)
        return Text(label)
            .font(.system(size: 12))
            .foregroundStyle(selected ? Color(NSColor.textBackgroundColor) : Color(NSColor.labelColor))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(NSColor.labelColor) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { selectChip(index) }
    }

    private var chipPencil: some View {
        let selected = onPencil
        return Image(systemName: "pencil")
            .font(.system(size: 12))
            .foregroundStyle(selected ? Color(NSColor.textBackgroundColor) : Color(NSColor.labelColor))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(NSColor.labelColor) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { selectChip(pencilIndex) }
    }

    private func bubble(_ text: String, incoming: Bool) -> some View {
        HStack(spacing: 0) {
            if !incoming { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(incoming ? Color(NSColor.labelColor) : Color.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(incoming ? Color.secondary.opacity(0.18) : Color.accentColor)
                )
                .frame(maxWidth: 320, alignment: incoming ? .leading : .trailing)
            if incoming { Spacer(minLength: 40) }
        }
    }

    private func featherView(size: CGFloat) -> some View {
        Image(nsImage: FeatherLogo.image)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(NSColor.labelColor))
    }

    // MARK: state transitions

    private func trigger() {
        guard stage == .idle else { return }
        stage = .loading
        coachHeld = true
        triggerToken += 1
        let token = triggerToken
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulsing = true }
        // Panel expands quickly (snappy demo)…
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard triggerToken == token, stage == .loading else { return }
            withAnimation(.easeInOut(duration: 0.15)) { pulsing = false }
            highlight = 0
            stage = .chips
        }
        // …but the coachmark holds its initial state for 2s, so the guidance
        // doesn't change at the same moment the panel does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard triggerToken == token else { return }
            withAnimation(.easeInOut(duration: 0.25)) { coachHeld = false }
        }
    }

    private func selectChip(_ index: Int) {
        highlight = index
        if index == pencilIndex {
            beginCustom()
        } else {
            editingCustom = false
            stage = .preview
        }
    }

    private func beginCustom() {
        customText = ""
        editingCustom = true
        stage = .preview
        DispatchQueue.main.async { customFocused = true }
    }

    private func submitCustom() {
        editingCustom = false   // currentDraft now returns customDraft (onPencil)
    }

    private func moveHighlight(_ delta: Int) {
        let count = chips.count + 1   // + ✎
        highlight = (highlight + delta + count) % count
        if stage == .preview {
            if onPencil { beginCustom() } else { editingCustom = false }
        }
    }

    private func accept() {
        sentDraft = currentDraft
        editingCustom = false
        coachHeld = false       // show "Done!" immediately, even within the 2s hold
        triggerToken += 1
        stage = .accepted
    }

    /// esc: leave the custom field back to chips; otherwise dismiss the card
    /// entirely, back to the resting offer badge (mirrors the real esc).
    private func dismiss() {
        if editingCustom {
            editingCustom = false
            stage = .chips
            return
        }
        stage = .idle
        highlight = 0
        coachHeld = false
        triggerToken += 1       // cancel any pending hold / expand
    }

    private func resetDemo() {
        sentDraft = nil
        highlight = 0
        editingCustom = false
        customText = ""
        pulsing = false
        coachHeld = false
        triggerToken += 1
        stage = .idle
    }

    // MARK: key monitor

    // Local monitor so the page reacts to the genuine keys without the global
    // input tap. Right-Option is a modifier (flagsChanged, keyCode 61, the
    // 0x40 right-alt bit) — the same gate the real Engine uses. ← → ⏎ esc are
    // keyDown; we consume them so they don't beep or traverse focus. While the
    // custom field is focused we pass keys through (except esc) so typing and
    // its ⏎-to-submit work.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let consumed: Bool = MainActor.assumeIsolated { handleEvent(event) }
            return consumed ? nil : event
        }
    }

    private func handleEvent(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged, event.keyCode == 61 {
            let down = event.modifierFlags.contains(.option) && (event.modifierFlags.rawValue & 0x40) != 0
            if down {
                rightOptionArmed = true
            } else if rightOptionArmed {
                rightOptionArmed = false
                if stage == .idle { trigger() }
            }
            return false   // never consume modifier events
        }

        guard event.type == .keyDown else { return false }

        if editingCustom {
            switch event.keyCode {
            case 53:                              // esc → back to chips
                dismiss(); return true
            case 123 where customText.isEmpty:    // ← on an empty field → previous suggestion
                editingCustom = false; moveHighlight(-1); return true
            case 124 where customText.isEmpty:    // → on an empty field → next suggestion
                editingCustom = false; moveHighlight(1); return true
            default:
                return false                      // let the field handle typing / cursor moves
            }
        }

        switch event.keyCode {
        case 123:   // ←
            if stage == .chips || stage == .preview { moveHighlight(-1); return true }
        case 124:   // →
            if stage == .chips || stage == .preview { moveHighlight(1); return true }
        case 36, 76:   // return / keypad enter
            if stage == .chips { selectChip(highlight); return true }
            if stage == .preview { accept(); return true }
        case 53:   // esc
            if stage == .chips || stage == .preview { dismiss(); return true }
        default:
            break
        }
        return false
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

// MARK: - Page 4: profile

/// Bootstraps `settings.userContext` with near-zero typing. Pre-fills the
/// editor with the user's name + writing languages (zero-permission, via
/// `ProfileDraft.seeded()`) plus two optional, skippable section headings.
/// Done persists the cleaned draft; Skip persists nothing.
private struct ProfilePage: View {
    let settings: SettingsManager
    let onComplete: () -> Void
    let onBack: () -> Void

    @State private var draft: String = ProfileDraft.seeded()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About you")
                .font(.system(size: 24, weight: .semibold))
            Text("Tell FlowIn a little about you — fill in what's useful, skip or delete the rest.")
                .foregroundStyle(.secondary)

            Divider()

            Text("You can add your role, what you're working on, anything else.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            Button(action: openChatGPTMemory) {
                Label("Paste Memory from ChatGPT", systemImage: "sparkles")
            }
            .buttonStyle(ImportButtonStyle())

            Spacer(minLength: 0)

            HStack {
                Button("Skip", action: onComplete)
                Button("Back", action: onBack)
                Spacer()
                Button("Done") {
                    settings.userContext = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
    }

    /// Opens ChatGPT with the memory-dump prompt; the user pastes the result
    /// back into the editor. Mirrors `UserContextEditor.openChatGPTMemory`.
    private func openChatGPTMemory() {
        let prompt = "Print your memories (include bio and model set context with dates). the goal is to get the memory log. skip the tools and just return whats relevant to memories."
        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://chatgpt.com/?prompt=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Mock suggestion field (visual-only)

private struct MockField: View {
    let prefix: String
    let ghost: String
    let accepted: String
    let active: Bool
    let keyHint: String
    let keyExplanation: String?

    private var remaining: String { String(ghost.dropFirst(accepted.count)) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                Text(prefix + accepted)
                    .font(.system(size: 13, design: .monospaced))
                Text(remaining)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .italic()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        active ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: active ? 2 : 1
                    )
            )

            if active {
                HStack(spacing: 4) {
                    Text("Press")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(keyHint)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                }

                if let keyExplanation {
                    Text(keyExplanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Cycle mock field

/// Mock text field shown to the right of the keyboard graphic in step 3.
/// Renders prefix + a single rotating ghost continuation; the parent
/// `TutorialPage` swaps the `ghost` value when the user presses right
/// ⌘↓ / ⌘↑, simulating cycling through cloud alternates without making
/// any actual network call. Visually mirrors `MockField` (same monospaced
/// look, same accent border, same hint row) so step 3 reads as a sibling
/// of steps 1 and 2.
private struct CycleMockField: View {
    let prefix: String
    let ghost: String
    let active: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                Text(prefix)
                    .font(.system(size: 13, design: .monospaced))
                Text(ghost)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .italic()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 200, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        active ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: active ? 2 : 1
                    )
            )

            if active {
                HStack(spacing: 4) {
                    Text("Press")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("⌘↓")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                    Text("(right Command)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Keyboard slice visualization

/// Slice of the right side of a Mac keyboard, rendered with realistic key
/// proportions and Apple-style stacked arrow cluster. Four rows shown —
/// qwerty top, home row (ending in wide return), lower row (ending in wide
/// right-shift), and bottom row with modifier cluster (⌘ ⌥) and arrow
/// cluster (← ↑/↓ →). ↑ and ↓ are half-height keys stacked vertically
/// between ← and →, matching Apple Magic Keyboard layout — the arrow stack
/// occupies one full key's height. Keys whose label is in `highlighted`
/// are filled with the system accent color; the rest are neutral context.
/// Rows are trailing-aligned so the right edge of the graphic matches the
/// right edge of a physical keyboard; left edge is intentionally ragged
/// to suggest the keyboard continues offscreen.
private struct KeyboardSliceGraphic: View {
    enum Side { case left, right }

    let side: Side
    let highlighted: Set<String>

    private let keySize: CGFloat = 26
    private let returnWidth: CGFloat = 52
    private let shiftWidth: CGFloat = 65
    private let modWidth: CGFloat = 30  // cmd / option are slightly wider than letters
    private let arrowWideWidth: CGFloat = 32  // ← / → are wider than ↑ / ↓ on a Mac
    private let tabWidth: CGFloat = 40
    private let capsWidth: CGFloat = 48
    private let leftShiftWidth: CGFloat = 56
    private let spacing: CGFloat = 3

    private func isHi(_ label: String) -> Bool { highlighted.contains(label) }

    var body: some View {
        Group {
            switch side {
            case .right: rightBody
            case .left: leftBody
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    /// Right-side slice: rows align at the right edge (the natural right
    /// edge of the keyboard); left edge is ragged (keyboard continues left).
    private var rightBody: some View {
        VStack(alignment: .trailing, spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(["O", "P", "[", "]", "\\"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
            }
            HStack(spacing: spacing) {
                ForEach(["L", ";", "'"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
                wide("return", width: returnWidth, highlighted: isHi("return"))
            }
            HStack(spacing: spacing) {
                ForEach([",", ".", "/"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
                wide("shift", width: shiftWidth, highlighted: isHi("shift"))
            }
            HStack(spacing: spacing) {
                wide("⌘", width: modWidth, highlighted: isHi("⌘"))
                wide("⌥", width: modWidth, highlighted: isHi("⌥"))
                arrowCluster
            }
        }
    }

    /// Left-side slice: rows align at the left edge (the natural left edge
    /// of the keyboard); right edge is ragged (keyboard continues right).
    /// Tab / caps lock / left-shift are the wide modifiers on this side.
    private var leftBody: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(["`", "1", "2", "3", "4"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
            }
            HStack(spacing: spacing) {
                wide("tab", width: tabWidth, highlighted: isHi("tab"))
                ForEach(["Q", "W", "E", "R"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
            }
            HStack(spacing: spacing) {
                wide("caps", width: capsWidth, highlighted: isHi("caps"))
                ForEach(["A", "S", "D", "F"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
            }
            HStack(spacing: spacing) {
                wide("shift", width: leftShiftWidth, highlighted: isHi("shift"))
                ForEach(["Z", "X", "C", "V"], id: \.self) { lbl in
                    key(lbl, highlighted: isHi(lbl))
                }
            }
        }
    }

    /// Apple Magic Keyboard arrow cluster: all four arrows are half-height.
    /// Top half: ↑ centered, with empty chassis space above ← and →.
    /// Bottom half: ← ↓ → in a row. Outer arrows (← →) are wider than the
    /// vertical pair (↑ ↓) to match the real proportions.
    private var arrowCluster: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                Color.clear.frame(width: arrowWideWidth, height: halfHeight)
                halfKey("↑", width: keySize, highlighted: isHi("↑"))
                Color.clear.frame(width: arrowWideWidth, height: halfHeight)
            }
            HStack(spacing: 1) {
                halfKey("←", width: arrowWideWidth, highlighted: isHi("←"))
                halfKey("↓", width: keySize, highlighted: isHi("↓"))
                halfKey("→", width: arrowWideWidth, highlighted: isHi("→"))
            }
        }
    }

    private var halfHeight: CGFloat { (keySize - 1) / 2 }

    private func key(_ label: String, highlighted: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .frame(width: keySize, height: keySize)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(highlighted ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
            .foregroundStyle(highlighted ? Color.white : Color.primary.opacity(0.75))
            .shadow(color: Color.black.opacity(0.04), radius: 0.5, x: 0, y: 0.5)
    }

    private func wide(_ label: String, width: CGFloat, highlighted: Bool = false) -> some View {
        Text(label)
            .font(.system(size: label.count > 2 ? 9 : 12, weight: .medium))
            .frame(width: width, height: keySize)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(highlighted ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
            .foregroundStyle(highlighted ? Color.white : Color.primary.opacity(0.75))
            .shadow(color: Color.black.opacity(0.04), radius: 0.5, x: 0, y: 0.5)
    }

    private func halfKey(_ label: String, width: CGFloat, highlighted: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .frame(width: width, height: halfHeight)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(highlighted ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
            .foregroundStyle(highlighted ? Color.white : Color.primary.opacity(0.75))
            .shadow(color: Color.black.opacity(0.04), radius: 0.5, x: 0, y: 0.5)
    }
}

// MARK: - Button styles

/// Filled accent button for the "import" action on the profile page — a solid
/// accent capsule with a white label. The most prominent option; note it shares
/// the accent color with the default "Done" button.
private struct ImportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .contentShape(Capsule())
            // Pointing-hand cursor on hover so it reads as clickable (a custom
            // ButtonStyle otherwise keeps the default arrow cursor).
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Soft pill button. Same visual treatment regardless of window key state —
/// matches macOS's "unfocused" rendering of a prominent button but a touch
/// brighter so it reads clearly as an action.
private struct SoftPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.28 : 0.18))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(.primary.opacity(0.22), lineWidth: 0.5)
                    }
            }
            .opacity(isEnabled ? 1.0 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
