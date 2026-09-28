import AppKit

// LSUIElement apps can't reliably bring windows to front via NSApp.activate;
// flipping activation policy to .regular while a user-facing window is open
// (then back to .accessory when none remain) gets the system to treat us as a
// real foreground app for the duration — Dock icon, focus transfer, the works.
@MainActor
final class DockPresence {
    private var count = 0

    func windowAppeared() {
        count += 1
        if count == 1 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowDisappeared() {
        count = max(0, count - 1)
        if count == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
