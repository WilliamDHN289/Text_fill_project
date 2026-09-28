import CoreGraphics
import Carbon.HIToolbox
import Foundation
import os

@MainActor
protocol InputMonitorDelegate: AnyObject {
    func inputMonitor(_ monitor: InputMonitor, didReceiveKeystroke event: KeystrokeEvent)
    func inputMonitorDidDetectClick(_ monitor: InputMonitor)
    func inputMonitorDidDetectMouseUp(_ monitor: InputMonitor)
    func inputMonitorDidDetectScroll(_ monitor: InputMonitor)
}

final class InputMonitor: @unchecked Sendable {
    weak var delegate: (any InputMonitorDelegate)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    /// Thread-safe flag: set by Engine when a suggestion is visible.
    /// Read synchronously in the event tap callback to consume Tab/Escape/RightArrow.
    private var _lock = os_unfair_lock()
    private var _suggestionVisible = false
    private var _replyActive = false
    private var _customEditing = false

    /// Fired when the user taps (press + release, nothing in between) the
    /// RIGHT Option key — the reply-drafting trigger.
    var onReplyHotkey: (() -> Void)?

    /// Set by AppDelegate after the ReplyController is created.
    weak var replyController: ReplyController?

    // Right-Option tap tracking. A "tap" = Right-Option down, then up, with
    // no other key pressed in between and within a short window. Bare modifier
    // presses arrive as flagsChanged (not keyDown), so we track them here.
    // These two vars are touched only on the serialized CGEvent tap thread —
    // no lock needed, unlike the lock-guarded _replyActive/_suggestionVisible.
    private var rightOptionDownAt: CFTimeInterval?
    private var sawKeyWhileRightOptionDown = false

    func setSuggestionVisible(_ visible: Bool) {
        os_unfair_lock_lock(&_lock)
        _suggestionVisible = visible
        os_unfair_lock_unlock(&_lock)
    }

    private var isSuggestionVisible: Bool {
        os_unfair_lock_lock(&_lock)
        let val = _suggestionVisible
        os_unfair_lock_unlock(&_lock)
        return val
    }

    /// Called by ReplyController when the card shows or hides, so the event
    /// tap callback (non-isolated) can gate card-key routing without touching
    /// a @MainActor property.
    func setReplyActive(_ active: Bool) {
        os_unfair_lock_lock(&_lock)
        _replyActive = active
        os_unfair_lock_unlock(&_lock)
    }

    private var isReplyActive: Bool {
        os_unfair_lock_lock(&_lock)
        let val = _replyActive
        os_unfair_lock_unlock(&_lock)
        return val
    }

    /// Set by ReplyController while the custom-intent text field is being edited. When
    /// true, every keydown passes straight through to the (key) reply panel's field and
    /// is NOT dispatched to the autocomplete Engine.
    func setCustomEditing(_ editing: Bool) {
        os_unfair_lock_lock(&_lock)
        _customEditing = editing
        os_unfair_lock_unlock(&_lock)
    }

    private var isCustomEditing: Bool {
        os_unfair_lock_lock(&_lock)
        let val = _customEditing
        os_unfair_lock_unlock(&_lock)
        return val
    }

    /// Map a Cmd-modified keyCode to the matching custom-field clipboard edit (QWERTY-position
    /// keys — the common case, including pinyin IME on QWERTY hardware).
    private static func customFieldEdit(forKeyCode keyCode: UInt16) -> CustomFieldEdit? {
        switch Int(keyCode) {
        case kVK_ANSI_V: return .paste
        case kVK_ANSI_C: return .copy
        case kVK_ANSI_X: return .cut
        case kVK_ANSI_A: return .selectAll
        default: return nil
        }
    }

    func start() throws {
        guard !isRunning else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            throw InputMonitorError.failedToCreateEventTap
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it was disabled due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle scroll: dismiss suggestion and pass through
        if type == .scrollWheel {
            if isSuggestionVisible {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.inputMonitorDidDetectScroll(self)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle mouse clicks: notify delegate and always pass through
        if type == .leftMouseDown {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.inputMonitorDidDetectClick(self)
                self.replyController?.handleOutsideClick()
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle mouse up: lets the engine detect drag-selection (selection only
        // becomes non-empty after the drag completes — too late for mouseDown).
        if type == .leftMouseUp {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.inputMonitorDidDetectMouseUp(self)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == KeystrokeEvent.rightOptionKeyCode {
                let flags = event.flags
                let rightOptionDown = flags.contains(.maskAlternate) && (flags.rawValue & 0x40) != 0
                if rightOptionDown {
                    rightOptionDownAt = ProcessInfo.processInfo.systemUptime
                    sawKeyWhileRightOptionDown = false
                } else {
                    // Right-Option released — fire if it was a clean, quick tap.
                    if let downAt = rightOptionDownAt,
                       !sawKeyWhileRightOptionDown,
                       ProcessInfo.processInfo.systemUptime - downAt < 0.4 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.onReplyHotkey?()
                        }
                    }
                    rightOptionDownAt = nil
                }
            }
            return Unmanaged.passUnretained(event)   // never consume flagsChanged
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // While the reply panel's custom-intent field is being edited, the panel is key
        // and owns the keyboard: let every key reach that field, and keep the Engine out.
        if isCustomEditing {
            // Exception: Cmd-V/C/X/A (paste/copy/cut/select-all) are menu key-equivalents, so
            // the FRONTMOST app claims them (our panel is key but not the active app) and they
            // never reach our field. Intercept them here, run the edit on the field ourselves,
            // and consume so the host doesn't act on them in its own field in the background.
            let f = event.flags
            let cmdOnly = f.contains(.maskCommand)
                && !f.contains(.maskControl) && !f.contains(.maskAlternate) && !f.contains(.maskShift)
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if cmdOnly, let edit = Self.customFieldEdit(forKeyCode: keyCode) {
                DispatchQueue.main.async { [weak self] in self?.replyController?.performCustomFieldEdit(edit) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Note: under session-wide secure input, this callback is never invoked
        // for keyDown events at all — macOS routes keyboard directly to the
        // frontmost app. So if we got here, secure input is by definition off.
        // No need to query `IsSecureEventInputEnabled()`. Detection of the
        // secure-input *failure* state happens in `SecureInputNotifier`,
        // checked at the moment we're about to render a suggestion.

        if rightOptionDownAt != nil { sawKeyWhileRightOptionDown = true }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Extract Unicode characters
        var length: Int = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let characters = String(utf16CodeUnits: chars, count: length)

        let keystrokeEvent = KeystrokeEvent(
            keyCode: keyCode,
            characters: characters,
            modifierFlags: event.flags,
            isRepeat: autorepeat,
            timestamp: ProcessInfo.processInfo.systemUptime
        )

        // Check if we should consume this event (Tab/Escape/backtick when suggestion visible)
        var shouldConsume = false
        if isSuggestionVisible {
            let flags = event.flags
            let isTab = keyCode == KeystrokeEvent.tabKeyCode
            let isEscape = keyCode == KeystrokeEvent.escapeKeyCode
            // Backtick accepts the full suggestion. It's a printable key, so only
            // swallow it when truly unmodified — otherwise Shift+` (~) and other
            // modified presses would be lost. Right Arrow is intentionally NOT
            // consumed anymore: it's plain caret navigation now, so the host must
            // receive it to move the cursor.
            let backtickNoMods = !flags.contains(.maskCommand) && !flags.contains(.maskControl)
                && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
            let isBacktick = keyCode == KeystrokeEvent.graveKeyCode && backtickNoMods
            if isTab || isEscape || isBacktick {
                shouldConsume = true
            }
            // Right-Command + ↓/↑ = cycle through 3-in-1 alternates. Consume
            // synchronously so the host app never sees the arrow keypress
            // (which would move caret instead). Right-Command flag bit:
            // NX_DEVICERCMDKEYMASK = 0x10. Left-Command (no 0x10 bit) keeps
            // its native shortcuts (Cmd+↑/↓ = document start/end).
            let isUpDown = keyCode == KeystrokeEvent.downArrowKeyCode
                || keyCode == KeystrokeEvent.upArrowKeyCode
            let isRightCommand = flags.contains(.maskCommand)
                && (flags.rawValue & 0x10) != 0
                && !flags.contains(.maskAlternate)
                && !flags.contains(.maskControl)
                && !flags.contains(.maskShift)
            if isUpDown && isRightCommand {
                shouldConsume = true
            }
        }

        // Card-key routing: when the reply card is visible, consume and dispatch
        // ←/→/Enter/Esc to ReplyController instead of forwarding to the host app.
        // This block is mutually exclusive with the isSuggestionVisible block above
        // because a suggestion is hidden before the reply card is shown (and vice versa).
        if !shouldConsume, isReplyActive {
            let isLeft = keyCode == KeystrokeEvent.leftArrowKeyCode
            let isRight = keyCode == KeystrokeEvent.rightArrowKeyCode
            let isReturn = keyCode == 36
            let isEsc = keyCode == KeystrokeEvent.escapeKeyCode
            if isLeft || isRight || isReturn || isEsc {
                shouldConsume = true
                DispatchQueue.main.async { [weak self] in
                    guard let rc = self?.replyController else { return }
                    if isEsc { rc.dismiss() }
                    else if isReturn { rc.choose() }
                    else { rc.handleArrow(left: isLeft) }
                }
            }
        }

        // Dispatch to delegate on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inputMonitor(self, didReceiveKeystroke: keystrokeEvent)
        }

        if shouldConsume {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

enum InputMonitorError: Error, LocalizedError {
    case failedToCreateEventTap

    var errorDescription: String? {
        switch self {
        case .failedToCreateEventTap:
            return "Failed to create event tap. Ensure Accessibility permission is granted."
        }
    }
}
