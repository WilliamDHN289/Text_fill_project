import AppKit

/// The "Contact Support" action, shared by the menu-bar and Settings buttons.
/// Shows a small dialog so support is always reachable: "Open Email" composes a
/// pre-addressed draft in the user's mail app via `mailto:`; "Copy Address" puts
/// the address on the clipboard for anyone whose mail routing doesn't actually
/// compose (e.g. a browser registered as the `mailto:` handler).
enum SupportContact {
    static let address = "leo@flowin.so"
    static let subject = "FlowIn Support"

    @MainActor
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Contact Support"
        alert.informativeText = "Email \(address) and we'll reply within a day."
        alert.addButton(withTitle: "Open Email")
        alert.addButton(withTitle: "Copy Address")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            compose()
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        default:
            break
        }
    }

    /// Open the user's mail app with a pre-addressed, versioned draft.
    private static func compose() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body()),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Blank space to type in, then a signature line carrying the versions.
    private static func body() -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let app = appVersion.map { "FlowIn v\($0)" } ?? "FlowIn"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return "\n\n\nSent from \(app) · macOS \(os)"
    }
}
