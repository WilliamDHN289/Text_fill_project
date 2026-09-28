import AppKit

enum EditMenuSupport {
    /// `LSUIElement` apps have no default menu bar, so the standard Cut / Copy /
    /// Paste / Select-All keyboard shortcuts don't reach text fields until an Edit
    /// menu exists in the main menu. Installs one if missing. Idempotent.
    @MainActor
    static func ensureEditMenu() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
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
