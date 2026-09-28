import AppKit
import ApplicationServices

extension NSPasteboard.PasteboardType {
    /// Private marker written onto the pasteboard item created by our own
    /// clipboard-paste insertion (`insertViaClipboard`). `ClipboardHistory`
    /// checks for it and skips capturing — otherwise the app records its own
    /// pasted suggestions into clipboard history, polluting it and churning the
    /// `clipboard` context section (which invalidates the KV cache on every
    /// accept). It is a separate pasteboard *type*, never part of the inserted
    /// string, so paste targets (which read only `.string`) never see it.
    static let flowinSelfPaste = NSPasteboard.PasteboardType("com.astrabreeze.autocomplete.self-paste")
}

/// Which insertion path was used by the most recent successful `TextInserter.insert(...)` call.
/// Different paths have different downstream consequences:
/// - `.ax` is fastest and the host's AX state is fully coherent immediately afterward.
/// - `.synthesis` routes through the host's normal input pipeline; AX caret rect updates
///   within ~50ms but `AXValue`/`AXStringForRange` may lag ~150-200ms (verified for Chrome).
/// - `.clipboard` is the legacy fallback. Reliable for plain text input but corrupts the AX
///   text marker in some hosts (notably Gmail expanded-history compose; see
///   `bug_gmail_expanded_history_blockquote.md`).
enum InsertionMethod {
    case m1
    case m2
    case m3
}

@MainActor
final class TextInserter {
    private var pendingRestore: DispatchWorkItem?
    /// Original clipboard saved at the start of a multi-insertion session.
    /// Preserved across rapid Tab presses so the final restore returns the user's real clipboard.
    private var savedBoard: [[String: Data]]?

    /// Set by `insert(...)` to indicate which path was used. Read by callers (e.g. Engine)
    /// to decide how long to wait before re-reading AX context for the next chunk.
    private(set) var lastMethod: InsertionMethod?

    /// Wall-clock instant before which the clipboard must not be overwritten — a
    /// previous paste's async Cmd-V may still be in flight. Zero = idle.
    private var clipboardBusyUntil: CFAbsoluteTime = 0
    /// Words accepted while a paste was still settling, concatenated in order and
    /// flushed as ONE coalesced paste once the window elapses.
    private var coalescedPaste: String = ""
    /// The pending coalesced-flush work item; doubles as the "is a flush scheduled" flag.
    private var coalescedFlush: DispatchWorkItem?

    /// Minimum time the clipboard is left untouched after a paste so the target can
    /// drain the async Cmd-V (delivered via postToPid) and read OUR text before the
    /// next paste overwrites the single-slot pasteboard. 70ms is well above the few
    /// ms a terminal needs to process one keystroke event, yet imperceptible
    /// (~14 accepts/sec). The one tunable knob for the rapid-Tab paste race.
    private static let pasteSettleSeconds: CFAbsoluteTime = 0.07

    /// Insert text at the current cursor position. Returns true on success.
    /// On success, `lastMethod` is set to the path that was used.
    ///
    /// The tier order is resolved per-host via `InsertionRouting`. Default is
    /// `AX → synthesis → clipboard` (fixes Safari/Chrome Gmail blockquote bug).
    /// Terminal emulators override to `clipboard → synthesis` (bracketed paste is
    /// the correct primitive for shells and TUI apps). See InsertionRouting.swift
    /// for the full policy table.
    func insert(_ text: String) -> Bool {
        // [InsertLatency] diagnostic: wall-clock of the whole tier walk (includes any
        // failed-tier fallthrough cost). Temporary — remove once the stutter is pinned.
        let insertStart = CFAbsoluteTimeGetCurrent()
        // Resolve the focused app's bundle ID and look up its routing policy.
        // This is a single AX call + NSRunningApplication lookup + dictionary read
        // — total ~10-20μs, invisible compared to the tier call itself.
        let bundleId = focusedAppBundleId() ?? ""
        let policy = InsertionRouting.policy(for: bundleId)
        Log.debug("Insert policy for \(bundleId.isEmpty ? "unknown" : bundleId): \(policy.tiers)")

        for tier in policy.tiers {
            let succeeded: Bool
            switch tier {
            case .m1:
                succeeded = insertViaAccessibility(text)
                if succeeded { Log.debug("Inserted via m1") }
            case .m2:
                succeeded = insertViaSynthesis(text, newlineDelayMs: policy.newlineDelayMs)
                if succeeded { Log.debug("Inserted via m2") }
            case .m3:
                succeeded = insertViaClipboard(text)
                if succeeded { Log.debug("Inserted via m3") }
            }
            if succeeded {
                lastMethod = tier
                let ms = (CFAbsoluteTimeGetCurrent() - insertStart) * 1000
                Log.debug("[InsertLatency] \(tier) total=\(String(format: "%.1f", ms))ms app=\(bundleId.isEmpty ? "?" : bundleId) chars=\(text.count)")
                return true
            }
            Log.debug("Method \(tier) failed, trying next")
        }

        let ms = (CFAbsoluteTimeGetCurrent() - insertStart) * 1000
        Log.debug("[InsertLatency] FAILED total=\(String(format: "%.1f", ms))ms app=\(bundleId.isEmpty ? "?" : bundleId)")
        lastMethod = nil
        return false
    }

    /// Resolve the bundle identifier of the focused application, if any.
    /// Used by `insert(...)` to look up the per-host insertion policy.
    private func focusedAppBundleId() -> String? {
        guard let pid = focusedAppPid() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    // MARK: - Focused App Resolution

    /// Resolves the PID of the application that currently owns keyboard focus.
    /// Used by both clipboard and synthesis paths to target CGEventPostToPid delivery
    /// and cursor-flush events at the correct process.
    private func focusedAppPid() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, axFocusedApplication, &appRef) == .success,
           let appRef {
            var pid: pid_t = 0
            AXUIElementGetPid(appRef as! AXUIElement, &pid)
            if pid > 0 { return pid }
        }
        // AX focused-application is nil for fully AX-blind apps (WeChat); fall back to the
        // frontmost app so the synthesis / clipboard insertion tiers still target the right
        // process. Mirrors ContextReader's readContext frontmost fallback — only triggers when
        // AX yields nothing, where frontmost is the correct target.
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: - AX Insertion

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var appRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            axFocusedApplication,
            &appRef
        ) == .success else { return false }

        var elemRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appRef as! AXUIElement,
            axFocusedUIElement,
            &elemRef
        ) == .success else { return false }

        let element = elemRef as! AXUIElement

        // Check if the element supports setting selected text
        var settable: DarwinBoolean = false
        let canSet = AXUIElementIsAttributeSettable(
            element,
            axSelectedText,
            &settable
        )
        guard canSet == .success, settable.boolValue else {
            Log.debug("M1: attribute not settable")
            return false
        }

        // Read current text to verify insertion later
        let beforeReadStart = CFAbsoluteTimeGetCurrent()
        var beforeRef: AnyObject?
        AXUIElementCopyAttributeValue(element, axValue, &beforeRef)
        let textBefore = beforeRef as? String
        let beforeReadMs = (CFAbsoluteTimeGetCurrent() - beforeReadStart) * 1000

        // Try setting selected text (inserts at cursor)
        let setStart = CFAbsoluteTimeGetCurrent()
        let result = AXUIElementSetAttributeValue(
            element,
            axSelectedText,
            text as CFTypeRef
        )
        let setMs = (CFAbsoluteTimeGetCurrent() - setStart) * 1000

        guard result == .success else { return false }

        // Verify the text was actually inserted by re-reading
        let afterReadStart = CFAbsoluteTimeGetCurrent()
        var afterRef: AnyObject?
        AXUIElementCopyAttributeValue(element, axValue, &afterRef)
        let textAfter = afterRef as? String
        let afterReadMs = (CFAbsoluteTimeGetCurrent() - afterReadStart) * 1000

        // [InsertLatency] diagnostic: the two full-text axValue reads are the prime suspect
        // for the accept stutter — they scale with field size. Temporary.
        Log.debug("[InsertLatency] m1 steps: beforeRead=\(String(format: "%.1f", beforeReadMs))ms set=\(String(format: "%.1f", setMs))ms afterRead=\(String(format: "%.1f", afterReadMs))ms fieldChars=\(textBefore?.count ?? -1)")

        if let before = textBefore, let after = textAfter {
            if after.count > before.count && after.contains(text) {
                return true
            }
            // Text didn't change — AX returned success but didn't actually insert
            Log.debug("M1: set returned success but text unchanged")
            return false
        }

        // If we can't read text to verify, trust the success result
        return true
    }

    // MARK: - Synthesized Keystrokes

    private func insertViaSynthesis(_ text: String, newlineDelayMs: Int) -> Bool {
        guard let pid = focusedAppPid() else { return false }
        return EventEmitter.emit(text: text, targetPid: pid, newlineDelayMs: newlineDelayMs)
    }

    // MARK: - Clipboard Injection

    /// Entry point for the clipboard (m3) tier. Serializes rapid pastes so the
    /// shared single-slot pasteboard is never overwritten while a previous async
    /// Cmd-V is still being drained by the target (see `pasteSettleSeconds`).
    /// Without this, rapid word-by-word Tab accepts in terminals race on the
    /// clipboard: queued Cmd-V events all read whichever word was written last,
    /// duplicating one word and dropping an earlier one.
    private func insertViaClipboard(_ text: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        // Fast path: no paste in flight → paste immediately. Byte-identical to the
        // pre-serialization single-paste behavior; only rapid follow-ups coalesce.
        if now >= clipboardBusyUntil && coalescedPaste.isEmpty {
            clipboardBusyUntil = now + Self.pasteSettleSeconds
            return performClipboardPaste(text)
        }
        // A prior paste is still settling. Overwriting the clipboard now would make
        // the target's not-yet-drained Cmd-V read THIS text instead of the previous
        // word. Accumulate and flush all pending words as ONE paste when the window
        // ends. The Engine already advanced its ghost state synchronously (see
        // acceptWord), so the real text just needs to catch up — same characters,
        // same order.
        coalescedPaste += text
        scheduleCoalescedFlush()
        Log.debug("Clipboard paste coalesced — pending '\(coalescedPaste)'")
        return true
    }

    /// Schedule the coalesced-paste flush for the moment the current settle window
    /// ends, unless one is already pending (the accumulated text rides along with it).
    private func scheduleCoalescedFlush() {
        guard coalescedFlush == nil else { return }
        let delay = max(0, clipboardBusyUntil - CFAbsoluteTimeGetCurrent())
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.coalescedFlush = nil
            let pending = self.coalescedPaste
            self.coalescedPaste = ""
            guard !pending.isEmpty else { return }
            self.clipboardBusyUntil = CFAbsoluteTimeGetCurrent() + Self.pasteSettleSeconds
            _ = self.performClipboardPaste(pending)
        }
        coalescedFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Write `text` to the pasteboard and issue Cmd-V. Callers MUST gate this through
    /// `insertViaClipboard` so the settle window is respected.
    private func performClipboardPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        // Resolve target PID up front so we can use postToPid for ALL events (Cmd-V
        // and the cursor flush) through the same delivery path. Mixing delivery paths
        // (.cgAnnotatedSessionEventTap for Cmd-V vs postToPid for the cursor flush)
        // creates a timing race: the postToPid arrows arrive at Chrome before the
        // session-tap Cmd-V is processed, causing the cursor to move before the paste
        // and overwriting / mispositioning a character.
        let targetPid = focusedAppPid()

        // Cancel any pending clipboard restore from a previous insertion
        let hadPendingRestore = pendingRestore != nil
        pendingRestore?.cancel()
        pendingRestore = nil

        // Only save the clipboard on the first insertion in a session.
        // Subsequent rapid insertions reuse the original snapshot so the
        // final restore returns the user's real clipboard, not a previous chunk.
        if !hadPendingRestore {
            // [InsertLatency] diagnostic: snapshotting a large clipboard (image / big text)
            // blocks the main thread — suspect for the m3 stutter. Temporary.
            let saveStart = CFAbsoluteTimeGetCurrent()
            savedBoard = savePasteboard(pasteboard)
            let saveMs = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
            let bytes = savedBoard?.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } ?? 0
            Log.debug("[InsertLatency] m3 savePasteboard=\(String(format: "%.1f", saveMs))ms clipboardBytes=\(bytes)")
        }

        // Set our text, tagged with a private marker type so our own clipboard
        // poller (ClipboardHistory) recognizes this as a self-paste and skips it.
        // The marker is a separate pasteboard *type*, not part of the string —
        // paste targets read only `.string`, so the inserted text is byte-identical
        // and the marker never reaches the host app.
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data([1]), forType: .flowinSelfPaste)
        pasteboard.writeObjects([item])

        // Simulate Cmd+V using a private event source to avoid interference with our event tap
        let source = CGEventSource(stateID: .privateState)
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            if let original = savedBoard {
                restorePasteboard(pasteboard, items: original)
                savedBoard = nil
            }
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Deliver Cmd-V via postToPid when we know the target — same delivery path as
        // the cursor flush below, eliminates ordering races. Fall back to the session
        // tap (no flush) if PID lookup failed.
        if let pid = targetPid {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)

            // Cursor flush: nudge the host's accessibility subsystem to refresh its
            // text marker after the paste. Without this, hosts like Gmail expanded-
            // history compose leave the AX caret pinned to the line-start of a
            // freshly-created DOM node, causing subsequent ghost text to render in
            // the wrong position. Same primitive used by EventEmitter after
            // batched synthesis.
            //
            // (We also tried backspace flush as an alternative — it consistently put
            // Blink's text marker into a degenerate state where AXBoundsForTextMarkerRange
            // returns the parent contenteditable's bounds instead of a leaf cursor
            // rect. The DOM mutation from the deletion appears to be what corrupts
            // the marker; cursor movement is non-mutating and works reliably.)
            //
            // Skipped for terminal (cursor-block) hosts: there the Left+Right pair
            // is real escape-sequence input to the TUI rather than an AX no-op, and
            // interleaving it with the async paste can reorder the caret. Terminals
            // re-read their AX caret fresh on each event, so they need no nudge.
            let isCursorBlock = NSRunningApplication(processIdentifier: pid)?
                .bundleIdentifier.map(InsertionRouting.isCursorBlockHost) ?? false
            if !isCursorBlock {
                EventEmitter.flushCursor(targetPid: pid)
            }
        } else {
            // Fallback path: no PID, can't use postToPid or cursor flush. Behave like
            // the legacy clipboard injection.
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }

        // Restore the original clipboard after the last insertion settles
        let restore = DispatchWorkItem { [weak self] in
            if let original = self?.savedBoard {
                self?.restorePasteboard(pasteboard, items: original)
                self?.savedBoard = nil
            }
            self?.pendingRestore = nil
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restore)

        Log.debug("Inserted via m3")
        return true
    }

    // MARK: - Clipboard Save/Restore

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict
        } ?? []
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[String: Data]]) {
        pasteboard.clearContents()
        for itemDict in items {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
            }
            pasteboard.writeObjects([item])
        }
    }
}
