import AppKit
import CoreGraphics

/// Synthesizes text input as a sequence of CGEvent key-down/key-up pairs, one per
/// grapheme cluster, using `kVK_Space` as a carrier keycode and
/// `CGEventKeyboardSetUnicodeString` to override the character with the actual UTF-16.
/// Events are posted via `CGEventPostToPid` for targeted delivery to the focused process,
/// bypassing global event taps.
///
/// This is the canonical Apple technique for synthesized arbitrary-text input. Validated
/// 2026-04-08 against Gmail expanded-history compose (where AX-set silently fails and
/// clipboard paste corrupts the AX text marker): synthesized keystrokes route through
/// Chrome's normal input pipeline and keep the AX caret marker coherent.
///
/// Caller is responsible for waiting ~200ms before re-reading AX context, since Chrome's
/// `AXValue` / `AXStringForRange` extraction lags ~150-200ms behind the actual DOM update
/// (the `AXBoundsForTextMarkerRange` query updates faster, ~50ms). Alternatively, use the
/// known inserted-text length to update cached state predictively and skip the wait.
@MainActor
enum EventEmitter {
    /// Send `text` as synthesized key events targeted at `targetPid`.
    /// Characters are batched into groups of up to `batchLimit` UTF-16 code units per
    /// CGEvent (respecting grapheme cluster boundaries — a single grapheme is never
    /// split across batches). For a typical 50-70 character chunk this produces 3-4
    /// key-down/key-up pairs instead of 50-70, dramatically reducing the per-character
    /// typing animation and the AX update lag in target apps.
    ///
    /// Batch size rationale: Apple's documentation notes that `CGEventKeyboardSetUnicodeString`
    /// "becomes potentially quite complex" past 20 characters. 20 is a conservative
    /// ceiling that works on all macOS versions while still giving a large speedup over
    /// per-grapheme synthesis.
    ///
    /// Returns false if event creation fails for any batch. Best-effort: any successfully
    /// posted events have already been delivered by the time it returns.
    static func emit(text: String, targetPid: pid_t, newlineDelayMs: Int = 0) -> Bool {
        guard !text.isEmpty else { return true }

        // Private state source: events from this source are not seen by our own event tap,
        // matching the convention TextInserter already uses for clipboard-paste synthesis.
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.error("EventEmitter: failed to create CGEventSource")
            return false
        }

        let kVKSpace: CGKeyCode = 0x31
        let kVKReturn: CGKeyCode = 0x24
        let batchLimit = 20

        // Build a flat sequence of "segments". Each segment is either a printable text
        // batch (delivered via a single CGEventKeyboardSetUnicodeString) or a newline
        // (delivered as a real Return keystroke).
        //
        // Why: Chrome's contenteditable input handler rejects unicode-string batches
        // that contain `\n` — verified 2026-04-08 in Zoho Mail compose where a 21-char
        // chunk starting with `"\n\n"` lost its entire 20-char first batch. The
        // unicode-string carrier mechanism is meant for printable characters; newlines
        // in contenteditables come from real Return keystrokes, not from inserting `\n`
        // into a Space carrier event.
        enum Segment {
            case batch([UInt16])
            case newline
        }
        var segments: [Segment] = []
        var currentBatch: [UInt16] = []
        func flushBatch() {
            if !currentBatch.isEmpty {
                segments.append(.batch(currentBatch))
                currentBatch = []
            }
        }
        for grapheme in text {
            if grapheme == "\n" {
                flushBatch()
                segments.append(.newline)
                continue
            }
            let graphemeUnits = Array(String(grapheme).utf16)
            if !currentBatch.isEmpty && currentBatch.count + graphemeUnits.count > batchLimit {
                flushBatch()
            }
            currentBatch.append(contentsOf: graphemeUnits)
        }
        flushBatch()

        var batchCount = 0
        var newlineCount = 0
        var totalUnits = 0
        for seg in segments {
            switch seg {
            case .batch(let units):
                batchCount += 1
                totalUnits += units.count
            case .newline:
                newlineCount += 1
            }
        }
        Log.debug("EventEmitter: \(batchCount) batch(es) + \(newlineCount) newline(s), total \(totalUnits) UTF-16 units for text length \(text.count)")

        for segment in segments {
            switch segment {
            case .batch(let batch):
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVKSpace, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVKSpace, keyDown: false) else {
                    Log.error("EventEmitter: failed to create key event for batch")
                    return false
                }
                keyDown.flags = []
                keyUp.flags = []
                keyDown.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: batch)
                keyUp.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: batch)
                keyDown.postToPid(targetPid)
                keyUp.postToPid(targetPid)
            case .newline:
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVKReturn, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVKReturn, keyDown: false) else {
                    Log.error("EventEmitter: failed to create Return key event")
                    return false
                }
                keyDown.flags = []
                keyUp.flags = []
                keyDown.postToPid(targetPid)
                keyUp.postToPid(targetPid)
                // Let WebKit's async Return-triggered DOM mutation settle
                // before the next sync setUnicodeString batch. Per-host;
                // 0 for native Cocoa (Return is sync there). Set via
                // InsertionPolicy.newlineDelayMs.
                if newlineDelayMs > 0 {
                    Thread.sleep(forTimeInterval: Double(newlineDelayMs) / 1000.0)
                }
            }
        }

        // Post-synthesis "AX flush" trick: send a no-op cursor movement (Left then Right)
        // to nudge the target host's accessibility subsystem to evaluate cursor position
        // immediately. Hypothesis: cursor-movement events trigger Blink/WebKit to flush
        // pending text-marker updates that batched character insertion alone leaves queued.
        flushCursor(source: source, targetPid: targetPid)

        return true
    }

    /// Send a no-op Left Arrow + Right Arrow keystroke pair targeted at `targetPid`.
    /// Used as an "AX refresh" primitive after text insertion (synthesis or paste) to
    /// nudge the target host's accessibility subsystem to re-evaluate cursor position
    /// and flush pending text-marker updates. Net cursor position is unchanged.
    ///
    /// Left-first (into just-inserted text) is safer than Right-first, which in Gmail
    /// expanded-history compose would move into the quoted blockquote area and might
    /// trigger focus changes.
    static func flushCursor(targetPid: pid_t) {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.error("EventEmitter: failed to create CGEventSource for nav pair")
            return
        }
        flushCursor(source: source, targetPid: targetPid)
    }

    /// Internal overload that reuses an existing `CGEventSource` (saves an alloc when
    /// called from `synthesize`, which already has a source on hand).
    private static func flushCursor(source: CGEventSource, targetPid: pid_t) {
        let kVKLeftArrow: CGKeyCode = 123
        let kVKRightArrow: CGKeyCode = 124

        guard let leftDown = CGEvent(keyboardEventSource: source, virtualKey: kVKLeftArrow, keyDown: true),
              let leftUp = CGEvent(keyboardEventSource: source, virtualKey: kVKLeftArrow, keyDown: false),
              let rightDown = CGEvent(keyboardEventSource: source, virtualKey: kVKRightArrow, keyDown: true),
              let rightUp = CGEvent(keyboardEventSource: source, virtualKey: kVKRightArrow, keyDown: false) else {
            Log.error("EventEmitter: failed to create nav pair events")
            return
        }
        for event in [leftDown, leftUp, rightDown, rightUp] {
            event.flags = []
        }
        leftDown.postToPid(targetPid)
        leftUp.postToPid(targetPid)
        rightDown.postToPid(targetPid)
        rightUp.postToPid(targetPid)
        Log.debug("EventEmitter: sent no-op nav pair")
    }
}
