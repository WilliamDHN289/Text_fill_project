import AppKit

@MainActor
enum InviteCodePrompt {
    /// Blocks the calling thread (main actor) until either the user enters a valid
    /// invite code or quits. Returns when activation succeeds.
    static func runUntilActivated() {
        if InviteCodeManager.isActivated { return }

        NSApp.activate(ignoringOtherApps: true)
        installEditMenuIfNeeded()

        while !InviteCodeManager.isActivated {
            let alert = NSAlert()
            alert.messageText = "Welcome to FlowIn"
            alert.informativeText = "Please enter your invite code to activate."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Activate")
            alert.addButton(withTitle: "Quit")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            textField.placeholderString = "FLOW-XXXX-XXXX-XXXX"
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                Log.info("InviteCodePrompt: user quit at activation prompt")
                NSApplication.shared.terminate(nil)
                return
            }

            if InviteCodeManager.tryActivate(with: textField.stringValue) {
                Log.info("InviteCodePrompt: activation succeeded")
                return
            }

            let errorAlert = NSAlert()
            errorAlert.messageText = "Invalid Code"
            errorAlert.informativeText = "That invite code wasn't recognized. Please check and try again."
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    /// LSUIElement apps have no default menu, so Cmd+C/V/X/A don't reach the
    /// focused text field. Install a minimal Edit menu so paste works in the
    /// prompt's text field. Mirrors the helper in SettingsWindowController.
    private static func installEditMenuIfNeeded() {
        if NSApp.mainMenu?.item(withTitle: "Edit") != nil { return }
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
}
