import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation

/// Detects macOS session-wide secure input and surfaces a one-shot, user-facing
/// hint when it's blocking Tab-to-accept.
///
/// Why this exists: when another app calls `EnableSecureEventInput()` (Terminal
/// with Secure Keyboard Entry, 1Password's menubar, VPN clients, password
/// fields, etc.), macOS routes keyboard events directly to the frontmost app
/// and bypasses CGEventTap entirely. Our event tap stops receiving keyDown,
/// so users see ghost text appear but pressing Tab does nothing — silently.
///
/// We can't bypass secure input (that's its whole point). The best we can do
/// is detect it at the moment we're about to render a suggestion and tell the
/// user *which* app is holding it, so they can fix it themselves.
///
/// Detection: `IsSecureEventInputEnabled()` is a sub-microsecond shared-state
/// read against WindowServer — free to call inline before every render.
///
/// Attribution: when secure input is on, we shell out to `ioreg` once and look
/// for the `kCGSSessionSecureInputPID` property in the registry, then map that
/// PID to a process name via `NSRunningApplication`. This is slow (~50-100ms)
/// but only runs in the already-degraded state, and only once per contiguous
/// secure-input session (see dedupe below).
///
/// Dedupe: we show the hint at most once per contiguous secure-input session.
/// "Contiguous" means we keep the flag set until a check observes secure input
/// being off — at which point we reset, so the hint can fire again the next
/// time it activates. This avoids spamming the user while still being useful
/// across multiple distinct incidents in a session.
@MainActor
final class SecureInputNotifier {
    static let shared = SecureInputNotifier()

    /// True after we've surfaced the hint for the current contiguous period of
    /// secure input. Cleared the next time we observe secure input being off.
    private var hasShownForCurrentSession = false

    /// Lazy so we don't pay panel construction cost in the (common) case where
    /// secure input is never observed during the session.
    private lazy var hintPanel = BrowserHintPanel()

    private init() {
        hintPanel.onDismissTap = { [weak self] in
            // User explicitly dismissed — keep `hasShownForCurrentSession` set
            // so we don't immediately re-show on the next render.
            self?.hintPanel.hide()
        }
    }

    /// Check whether secure input is currently blocking Tab acceptance.
    /// If yes, surface the hint (deduped) and return `true` so the caller
    /// suppresses ghost text rendering. If no, reset the dedupe flag and
    /// return `false` so rendering proceeds normally.
    ///
    /// `caretRect` is the AX-coordinate caret rectangle (same one the ghost
    /// text uses) and is the preferred anchor — it's accurate down to the
    /// cursor position. `elementFrame` is the surrounding text field frame,
    /// used as a fallback if the caret rect is unavailable. If both are
    /// degenerate we anchor near the screen origin as a last resort.
    @discardableResult
    func checkAndNotify(caretRect: CGRect, elementFrame: CGRect) -> Bool {
        guard IsSecureEventInputEnabled() else {
            // Secure input is off — allow the hint to re-fire next time it
            // activates (user closed Terminal, then reopens it later).
            hasShownForCurrentSession = false
            return false
        }

        guard !hasShownForCurrentSession else {
            // Already shown for this contiguous secure-input session — stay
            // suppressed but still report blocked so the caller bails.
            return true
        }
        hasShownForCurrentSession = true

        let culprit = Self.findCulprit()
        let pidStr = culprit.map { "\($0.pid)" } ?? "?"
        Log.info("SecureInput: detected, culprit=\(culprit?.name ?? "unknown") pid=\(pidStr)")

        // Anchor priority: caretRect (most accurate, used by ghost text) →
        // elementFrame (whole field) → screen origin fallback. The hint panel
        // expects an AX-coordinate rect and positions itself just above its
        // top edge.
        let anchor: CGRect
        if caretRect.height > 0 {
            anchor = caretRect
        } else if elementFrame.height > 0 {
            anchor = elementFrame
        } else {
            anchor = CGRect(x: 100, y: 100, width: 0, height: 0)
        }

        // User-facing message: deliberately avoids the term "secure input"
        // (developer jargon) in favor of "protecting your keystrokes", which
        // explains the behavior in plain English. Always names the culprit
        // explicitly when known to avoid pronoun ambiguity ("Quit Terminal"
        // not "Quit it").
        //
        // The unknown-culprit fallback recommends log out / restart instead
        // of listing common culprits to quit. Listing apps like Terminal,
        // 1Password, or VPN clients is counterproductive because users
        // actively need those apps — telling them to quit means giving up
        // something they're using. We say "log out of your Mac" (not just
        // "log out") to disambiguate from logging out of an app.
        let message: String
        if let culprit = culprit {
            message = "FlowIn can't accept Tab — \(culprit.name) is protecting your keystrokes. Quit \(culprit.name), log out of your Mac, or restart."
        } else {
            message = "FlowIn can't accept Tab — an app is protecting your keystrokes. Log out of your Mac or restart."
        }
        hintPanel.show(message: message, linkText: nil, linkURL: nil, elementFrame: anchor)

        return true
    }

    // MARK: - Culprit Attribution

    private struct Culprit {
        let pid: pid_t
        let name: String
    }

    /// Resolve the PID currently holding secure input via the IORegistry's
    /// `kCGSSessionSecureInputPID` property. Returns nil if the property is
    /// missing (e.g., loginwindow holding it, or the registry layout changed).
    ///
    /// We shell out to `ioreg` rather than calling `IORegistryEntryCreateCFProperty`
    /// directly because the property lives at session scope under WindowServer,
    /// and walking to the right registry entry from Swift is more code than the
    /// shell-out is worth — especially since this only runs once per secure-input
    /// session.
    private static func findCulprit() -> Culprit? {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-l", "-w", "0"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            Log.error("SecureInput: failed to launch ioreg: \(error)")
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Lines look like: `    "kCGSSessionSecureInputPID" = 1234`
        for line in output.split(separator: "\n") where line.contains("kCGSSessionSecureInputPID") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let after = line[line.index(after: eq)...]
            let trimmed = after.trimmingCharacters(in: .whitespaces)
            // First whitespace-delimited token is the integer PID.
            guard let pidToken = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let pid = pid_t(pidToken) else { continue }
            // PID 0 means "no holder" — secure input is on but registry hasn't
            // been updated, or it's held at a level we can't introspect.
            guard pid > 0 else { continue }

            // Resolve PID to a human-readable name. NSRunningApplication gives
            // nice localized names for GUI apps with bundles (Terminal,
            // 1Password, Safari). Fall back to libproc for CLI tools and
            // daemons that aren't in the GUI app registry.
            if let app = NSRunningApplication(processIdentifier: pid),
               let name = app.localizedName {
                return Culprit(pid: pid, name: name)
            }
            if let name = procName(for: pid) {
                return Culprit(pid: pid, name: name)
            }
            return Culprit(pid: pid, name: "PID \(pid)")
        }
        return nil
    }

    /// Resolve a PID to its short executable name via libproc. Works for any
    /// process the user has permission to introspect, including CLI tools
    /// that NSRunningApplication doesn't know about.
    private static func procName(for pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 1024)
        let written = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard written > 0 else { return nil }
        let bytes = Array(buf.prefix(Int(written)))
        return String(decoding: bytes, as: UTF8.self)
    }
}
