import CoreGraphics
import Foundation

struct KeystrokeEvent {
    let keyCode: UInt16
    let characters: String
    let modifierFlags: CGEventFlags
    let isRepeat: Bool
    let timestamp: TimeInterval

    // Common key codes
    static let tabKeyCode: UInt16 = 48
    static let escapeKeyCode: UInt16 = 53
    static let rightArrowKeyCode: UInt16 = 124
    static let leftArrowKeyCode: UInt16 = 123
    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125
    static let deleteKeyCode: UInt16 = 51
    static let forwardDeleteKeyCode: UInt16 = 117
    static let returnKeyCode: UInt16 = 36
    static let spaceKeyCode: UInt16 = 49
    static let graveKeyCode: UInt16 = 50
    static let rightOptionKeyCode: UInt16 = 61   // kVK_RightOption

    var isTab: Bool { keyCode == Self.tabKeyCode }
    var isEscape: Bool { keyCode == Self.escapeKeyCode }
    var isRightArrow: Bool { keyCode == Self.rightArrowKeyCode }
    var isLeftArrow: Bool { keyCode == Self.leftArrowKeyCode }
    var isUpArrow: Bool { keyCode == Self.upArrowKeyCode }
    var isDownArrow: Bool { keyCode == Self.downArrowKeyCode }
    var isDelete: Bool { keyCode == Self.deleteKeyCode }
    var isForwardDelete: Bool { keyCode == Self.forwardDeleteKeyCode }
    var isReturn: Bool { keyCode == Self.returnKeyCode }
    var isSpace: Bool { keyCode == Self.spaceKeyCode }
    /// Backtick / grave key (ANSI position, keyCode 50). Accepts the full suggestion.
    var isBacktick: Bool { keyCode == Self.graveKeyCode }

    var hasCommandModifier: Bool { modifierFlags.contains(.maskCommand) }
    var hasControlModifier: Bool { modifierFlags.contains(.maskControl) }
    var hasOptionModifier: Bool { modifierFlags.contains(.maskAlternate) }
    var hasShiftModifier: Bool { modifierFlags.contains(.maskShift) }

    /// True iff the RIGHT Command key is pressed (vs left). macOS distinguishes
    /// these via NX_DEVICERCMDKEYMASK = 0x10 in the raw event flags. Used so
    /// our cycle hotkey ⌘↓ / ⌘↑ doesn't conflict with the many existing
    /// left-Command shortcuts in host apps (Cmd+↑/↓ = document start/end,
    /// etc.).
    var hasRightCommandModifier: Bool {
        modifierFlags.contains(.maskCommand) && (modifierFlags.rawValue & 0x10) != 0
    }

    /// Right-Command + Down Arrow — cycle to next alternate completion.
    var isRightCommandDown: Bool {
        keyCode == Self.downArrowKeyCode
            && hasRightCommandModifier
            && !hasOptionModifier && !hasControlModifier && !hasShiftModifier
    }

    /// Right-Command + Up Arrow — cycle to previous alternate completion.
    var isRightCommandUp: Bool {
        keyCode == Self.upArrowKeyCode
            && hasRightCommandModifier
            && !hasOptionModifier && !hasControlModifier && !hasShiftModifier
    }

    /// No modifier keys held (Cmd, Ctrl, Option, Shift)
    var hasNoModifiers: Bool {
        !hasCommandModifier && !hasControlModifier && !hasOptionModifier && !hasShiftModifier
    }

    /// Whether this is a caret-moving key (arrows, Home/End style)
    var isCaretMovement: Bool {
        isLeftArrow || isRightArrow || isUpArrow || isDownArrow
    }

    /// Emacs-style navigation: Ctrl+F/B/N/P/A/E move the caret
    var isEmacsNavigation: Bool {
        guard hasControlModifier, !hasCommandModifier else { return false }
        let ch = characters.lowercased()
        return ch == "f" || ch == "b" || ch == "n" || ch == "p" || ch == "a" || ch == "e"
    }

    /// Emacs-style line kill (Ctrl+K) — destructive, removes text to end of line
    var isEmacsKillLine: Bool {
        hasControlModifier && !hasCommandModifier && characters.lowercased() == "k"
    }

    /// Emacs-style forward delete (Ctrl+D)
    var isEmacsForwardDelete: Bool {
        hasControlModifier && !hasCommandModifier && characters.lowercased() == "d"
    }

    /// Cmd+A (Select All)
    var isSelectAll: Bool {
        hasCommandModifier && characters.lowercased() == "a"
    }

    /// Cmd+V (Paste) — also matches Cmd+Shift+V (paste without formatting)
    var isPaste: Bool {
        hasCommandModifier && !hasControlModifier && characters.lowercased() == "v"
    }

    /// Cmd+X (Cut)
    var isCut: Bool {
        hasCommandModifier && !hasControlModifier && characters.lowercased() == "x"
    }

    /// Whether this is a regular character keystroke (no Cmd/Ctrl modifiers)
    var isCharacterKeystroke: Bool {
        !characters.isEmpty && !hasCommandModifier && !hasControlModifier
    }
}
