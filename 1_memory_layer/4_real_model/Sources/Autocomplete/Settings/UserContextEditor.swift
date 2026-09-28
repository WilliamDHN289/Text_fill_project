import AppKit

@MainActor
final class UserContextEditor: NSObject {
    private var window: NSWindow?
    private var settings: SettingsManager?
    private var textView: NSTextView?

    func show(settings: SettingsManager) {
        let width: CGFloat = 480
        let height: CGFloat = 360

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "User Context"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)

        // Ensure Edit menu exists so Cmd+V paste works (LSUIElement apps have no default menu)
        EditMenuSupport.ensureEditMenu()

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        contentView.autoresizingMask = [.width, .height]

        // Instructions
        let label = NSTextField(wrappingLabelWithString: "Add your name, role, preferences, schedule, or any context to personalize completions.")
        label.frame = NSRect(x: 16, y: height - 50, width: width - 32, height: 34)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(label)

        // Text view in scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 52, width: width - 32, height: height - 110))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
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
        contentView.addSubview(scrollView)

        // Get ChatGPT Memory button (utility action, bottom-left)
        let chatGPTButton = NSButton(title: "Get ChatGPT Memory", target: self, action: #selector(openChatGPTMemory))
        chatGPTButton.bezelStyle = .rounded
        chatGPTButton.frame = NSRect(x: 16, y: 14, width: 170, height: 28)
        chatGPTButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(chatGPTButton)

        window.contentView = contentView
        self.window = window
        self.settings = settings
        self.textView = textView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openChatGPTMemory() {
        let prompt = "Print your memories (include bio and model set context with dates). the goal is to get the memory log. skip the tools and just return whats relevant to memories."
        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://chatgpt.com/?prompt=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension UserContextEditor: NSTextViewDelegate {
    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let textView, let settings else { return }
            settings.userContext = textView.string
        }
    }
}
