import CoreGraphics
import AppKit
import ApplicationServices

// Private AX SPI: maps an AXUIElement window to its CGWindowID.
// Linked against the same ApplicationServices that exports the public AX API;
// stable across all macOS versions we support.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowCapturer {
    /// Capture the window the user is currently interacting with for the given PID.
    static func capture(pid: pid_t) -> CGImage? {
        guard let windowID = resolveWindowID(forPid: pid) else { return nil }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    /// Return the bounds (in screen coords) of the window we'd capture for this PID.
    /// Used by ImageCropper to crop the band above the input field.
    static func windowBounds(forPid pid: pid_t) -> CGRect? {
        guard let windowID = resolveWindowID(forPid: pid) else { return nil }
        return bounds(forWindowID: windowID)
    }

    // MARK: - Private

    /// Prefer the AX-focused window (handles launcher-class overlays at non-zero layers
    /// and avoids capturing a same-PID main window when a higher-layer panel has focus).
    /// Falls back to the first on-screen layer-0 window if AX returns nothing usable.
    private static func resolveWindowID(forPid pid: pid_t) -> CGWindowID? {
        if let id = focusedWindowID(forPid: pid), id != 0 { return id }
        if let id = legacyFrontWindowID(forPid: pid) {
            Log.debug("[ScreenContext] resolveWindowID: AX failed, fell back to legacy layer-0 id=\(id)")
            return id
        }
        return nil
    }

    private static func focusedWindowID(forPid pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let cf = winRef,
              CFGetTypeID(cf) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = cf as! AXUIElement
        var windowID: CGWindowID = 0
        let err = _AXUIElementGetWindow(window, &windowID)
        return err == .success && windowID != 0 ? windowID : nil
    }

    private static func legacyFrontWindowID(forPid pid: pid_t) -> CGWindowID? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber] as? CGWindowID else { continue }
            return windowID
        }
        return nil
    }

    private static func bounds(forWindowID id: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[CFString: Any]],
              let info = infoList.first,
              let dict = info[kCGWindowBounds] as? [String: CGFloat] else {
            return nil
        }
        return CGRect(
            x: dict["X"] ?? 0,
            y: dict["Y"] ?? 0,
            width: dict["Width"] ?? 0,
            height: dict["Height"] ?? 0
        )
    }
}
