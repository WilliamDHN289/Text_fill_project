import AppKit
import ApplicationServices

@MainActor
protocol FocusMonitorDelegate: AnyObject {
    func focusMonitorDidDetectFocusChange(_ monitor: FocusMonitor)
}

/// Monitors for app activation changes and AX focused element changes.
/// Fires delegate callback when focus leaves the current text field.
@MainActor
final class FocusMonitor {
    weak var delegate: FocusMonitorDelegate?

    private var axObserver: AXObserver?
    private var observedPid: pid_t = 0
    private var workspaceObserver: NSObjectProtocol?

    // Identity of the last focused element — used to drop spurious same-element re-posts.
    private var lastFocusHash: CFHashCode?

    func start() {
        // 1. Observe app activation changes (covers app switch + desktop switch)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.focusMonitorDidDetectFocusChange(self!)
            }
        }

        // 2. Start observing AX focus for the current frontmost app
        if let app = NSWorkspace.shared.frontmostApplication {
            observeAXFocus(for: app.processIdentifier)
        }
    }

    func stop() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        removeAXObserver()
    }

    /// Call when the active app changes so we track focused element in the new app.
    func updateObservedApp(pid: pid_t) {
        guard pid != observedPid else { return }
        observeAXFocus(for: pid)
    }

    // Forward focus changes to the delegate, but DROP spurious same-element re-posts.
    // WebKit (e.g. Apple Mail's AXWebArea) re-posts AXFocusedUIElementChanged for the
    // SAME element whenever its accessibility tree is read/flushed; acting on those
    // re-reads + re-screenshots, which re-provokes WebKit and sustains an idle loop.
    // A real focus move carries a different element.
    func handleAXFocusNotification(hash: CFHashCode) {
        let same = (lastFocusHash == hash)
        lastFocusHash = hash
        if same { return }
        delegate?.focusMonitorDidDetectFocusChange(self)
    }

    // MARK: - AX Observer

    private func observeAXFocus(for pid: pid_t) {
        removeAXObserver()
        observedPid = pid

        var observer: AXObserver?
        let result = AXObserverCreate(pid, { (_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ userData: UnsafeMutableRawPointer?) in
            guard let userData else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(userData).takeUnretainedValue()
            // CFHash is computed from the element's bytes (no AX round-trip that could
            // itself provoke a notification) — used to drop same-element re-posts.
            let hash = CFHash(element)
            DispatchQueue.main.async {
                monitor.handleAXFocusNotification(hash: hash)
            }
        }, &observer)

        guard result == .success, let observer else { return }
        axObserver = observer

        let appElement = AXUIElementCreateApplication(pid)
        let userData = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, appElement, axFocusedUIElementChanged, userData)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeAXObserver() {
        guard let observer = axObserver else { return }
        let appElement = AXUIElementCreateApplication(observedPid)
        AXObserverRemoveNotification(observer, appElement, axFocusedUIElementChanged)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = nil
        observedPid = 0
    }
}
