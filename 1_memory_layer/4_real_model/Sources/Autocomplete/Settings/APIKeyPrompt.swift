import AppKit

@MainActor
final class APIKeyPrompt {
    private var window: NSWindow?

    struct ProviderKey {
        let label: String
        let keychainKey: String
        let placeholder: String
        let helpText: String
    }

    static let providers: [ProviderKey] = [
        ProviderKey(
            label: "OpenAI",
            keychainKey: "openai_api_key",
            placeholder: "sk-...",
            helpText: "platform.openai.com/api-keys"
        ),
        ProviderKey(
            label: "OpenRouter",
            keychainKey: "openrouter_api_key",
            placeholder: "sk-or-...",
            helpText: "openrouter.ai/keys"
        ),
    ]

    func show(onSave: @escaping () -> Void) {
        let width: CGFloat = 420
        let rowHeight: CGFloat = 70
        let height: CGFloat = CGFloat(Self.providers.count) * rowHeight + 90

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "API Keys"
        window.center()
        window.isReleasedWhenClosed = false

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

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var textFields: [(ProviderKey, NSTextField)] = []

        for (index, provider) in Self.providers.enumerated() {
            let yOffset = height - CGFloat(index + 1) * rowHeight

            // Provider label
            let label = NSTextField(labelWithString: "\(provider.label)  (\(provider.helpText))")
            label.frame = NSRect(x: 20, y: yOffset + 28, width: width - 40, height: 16)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            contentView.addSubview(label)

            // Text field
            let textField = NSSecureTextField()
            textField.frame = NSRect(x: 20, y: yOffset + 2, width: width - 40, height: 24)
            textField.placeholderString = provider.placeholder
            if let existing = KeychainManager.read(key: provider.keychainKey), !existing.isEmpty {
                textField.stringValue = existing
            }
            contentView.addSubview(textField)

            textFields.append((provider, textField))
        }

        // Buttons
        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: width - 100, y: 16, width: 80, height: 28)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: width - 190, y: 16, width: 80, height: 28)

        contentView.addSubview(saveButton)
        contentView.addSubview(cancelButton)

        window.contentView = contentView
        self.window = window

        let coordinator = PromptCoordinator()
        coordinator.onSave = { [weak self] in
            for (provider, textField) in textFields {
                let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    _ = KeychainManager.save(key: provider.keychainKey, value: value)
                }
            }
            onSave()
            self?.window?.close()
            self?.window = nil
        }
        coordinator.onCancel = { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        saveButton.target = coordinator
        saveButton.action = #selector(PromptCoordinator.saveTapped)
        cancelButton.target = coordinator
        cancelButton.action = #selector(PromptCoordinator.cancelTapped)

        // Keep coordinator alive while window is open
        objc_setAssociatedObject(window, "coordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private class PromptCoordinator: NSObject {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    @objc func saveTapped() { onSave?() }
    @objc func cancelTapped() { onCancel?() }
}
