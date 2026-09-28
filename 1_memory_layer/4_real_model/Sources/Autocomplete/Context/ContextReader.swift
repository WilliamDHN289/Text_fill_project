import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class ContextReader {

    /// Track PIDs where we've already enabled accessibility
    private static var enabledPids = Set<pid_t>()

    private enum RectSource { case s1, s2, s3, s4 }
    private var lastRectSource: RectSource?
    /// Set to true when Strategy 1's `AXBoundsForRange([caret, 1])` returned a
    /// line-wide rect (typically because the next char is a newline). Terminal.app
    /// gives bogus zero-range bounds in this situation once any text is typed on
    /// the line, so for `isCursorBlock` hosts we recompute caret X from monospace
    /// line geometry after the fact.
    private var lastRectViaLineWideRect: Bool = false

    /// Monospace cell width as a fraction of line height, used to place the caret
    /// in terminal (block-cursor) hosts. Their AX quantizes per-char bounds to an
    /// integer point width that's narrower than the real cell, so we estimate the
    /// cell from line height instead. Tuned against SF Mono / Menlo in Terminal.app.
    private static let terminalCellAspect: CGFloat = 0.48

    /// Lightweight check: does the focused element currently have a non-empty
    /// text selection? Used after mouseUp to detect drag-selection without
    /// re-running the full context read.
    func hasNonEmptySelection() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, axFocusedUIElement, &focusedRef) == .success,
              let focused = focusedRef else { return false }
        let element = focused as! AXUIElement

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axSelectedTextRange, &rangeRef) == .success,
              let rangeValue = rangeRef else { return false }

        var range = CFRange(location: 0, length: 0)
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        return range.length > 0
    }

    func readContext() -> TextContext? {
        let systemWide = AXUIElementCreateSystemWide()

        // Step 1: Get focused application
        var appRef: AnyObject?
        let appErr = AXUIElementCopyAttributeValue(
            systemWide,
            axFocusedApplication,
            &appRef
        )

        // Resolve the focused application. The system-wide AXFocusedApplication query
        // is primary, but some apps (e.g. WeChat 4.x) return kAXErrorNoValue for it
        // while their app-level AX tree is still reachable. In that case fall back to
        // the frontmost app (NSWorkspace — window-server level, no AX) and address its
        // AX element by PID, which bypasses the failing system-wide lookup.
        //
        // Safe vs the non-activating-overlay caveat (see Engine.isFrontmostAppDisabled):
        // overlays resolve via AX *successfully*, so they never reach this fallback;
        // only a fully-empty AX focused-app (WeChat) does, where frontmost is correct.
        let focusedApp: AXUIElement
        var pidValue: pid_t = 0
        if appErr == .success, let ref = appRef {
            focusedApp = ref as! AXUIElement
            AXUIElementGetPid(focusedApp, &pidValue)
        } else {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier > 0 else {
                Log.debug("readContext nil: no AXFocusedApplication (err=\(appErr.rawValue)) and no frontmost app")
                return nil
            }
            pidValue = front.processIdentifier
            focusedApp = AXUIElementCreateApplication(pidValue)
            Log.debug("readContext: AXFocusedApplication nil (err=\(appErr.rawValue)) → frontmost fallback app=\(front.bundleIdentifier ?? "?") name=\(front.localizedName ?? "?") pid=\(pidValue)")
        }

        // Get app info
        let runningApp = NSRunningApplication(processIdentifier: pidValue)
        let appName = runningApp?.localizedName ?? "Unknown"
        let appBundleId = runningApp?.bundleIdentifier ?? ""

        // Enable accessibility for Electron/Chromium apps
        ensureAccessibilityEnabled(app: focusedApp, pid: pidValue, bundleId: appBundleId)

        // Get window title and reference
        var windowRef: AnyObject?
        var windowTitle = ""
        var focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(focusedApp, axFocusedWindow, &windowRef) == .success,
           let w = windowRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
            focusedWindow = (w as! AXUIElement)
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(focusedWindow!, axTitle, &titleRef) == .success {
                windowTitle = titleRef as? String ?? ""
            }
        }

        // Step 2: Get focused UI element
        var elemRef: AnyObject?
        let elemErr = AXUIElementCopyAttributeValue(
            focusedApp,
            axFocusedUIElement,
            &elemRef
        )
        guard elemErr == .success else {
            Log.debug("readContext nil: no AXFocusedUIElement app=\(appBundleId) (err=\(elemErr.rawValue))")
            return nil
        }
        let focusedElement = elemRef as! AXUIElement

        // Step 3: Verify it's a text element
        var roleRef: AnyObject?
        let roleErr = AXUIElementCopyAttributeValue(
            focusedElement,
            axRole,
            &roleRef
        )
        guard roleErr == .success else {
            Log.debug("readContext nil: no AXRole app=\(appBundleId) (err=\(roleErr.rawValue))")
            return nil
        }

        let role = roleRef as? String ?? ""
        let textRoles: Set<String> = [
            axTextField as String,
            axTextArea as String,
            axComboBox as String,
            axWebArea as String
        ]
        guard textRoles.contains(role) else {
            Log.debug("readContext nil: role '\(role)' not a text role, app=\(appBundleId)")
            return nil
        }

        // Step 4: Check for password field and search field
        var isPassword = false
        var isSearchField = false
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            axSubrole,
            &subroleRef
        ) == .success {
            let subrole = subroleRef as? String ?? ""
            if subrole == axSecureTextField as String {
                isPassword = true
            } else if subrole == axSearchField as String {
                isSearchField = true
            }
        }

        // Step 5+6: Get caret position and build prefix/suffix.
        // Strategy A (preferred): Use AXStringForRange to extract text near cursor.
        //   Reads only maxPrefixRead + maxSuffixRead chars (~8K) instead of the entire
        //   text buffer, which can be 800K+ in Terminal. Also avoids the Slate.js vs
        //   Gmail newline offset mismatch because AXStringForRange and AXSelectedTextRange
        //   use the same coordinate system in all apps.
        // Strategy B (fallback): Read full AXValue and split at offset with newline adjustment.
        var rangeRef: AnyObject?
        let rangeErr = AXUIElementCopyAttributeValue(
            focusedElement,
            axSelectedTextRange,
            &rangeRef
        )
        var prefix: String
        var suffix: String
        var caretPosition: Int
        let textLength: Int

        // WebKit document-level web areas (e.g. Apple Mail's compose body) return
        // kAXErrorNoValue for the integer AXSelectedTextRange and expose the caret only
        // through the text-marker API. Use markers when the integer range is unavailable;
        // otherwise take the standard integer path below.
        if rangeErr != .success {
            guard role == (axWebArea as String),
                  let marker = extractTextViaTextMarkers(element: focusedElement) else {
                Log.debug("readContext nil: no AXSelectedTextRange role='\(role)' app=\(appBundleId) (err=\(rangeErr.rawValue))")
                return nil
            }
            prefix = marker.prefix
            suffix = marker.suffix
            caretPosition = marker.prefix.count
            Log.debug("TextExtract: markers (prefix=\(prefix.count) suffix=\(suffix.count))")
            textLength = prefix.count + suffix.count
        } else {
            var range = CFRange(location: 0, length: 0)
            AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)

            let selLocation = range.location
            let selLength = range.length

            // Suppress autocomplete when the user has a non-empty selection — accepting a
            // suggestion would replace the selected text via AXSelectedText set, which is
            // almost never what the user wants.
            if selLength > 0 {
                Log.debug("TextExtract: skipped (selection length=\(selLength))")
                return nil
            }

            if let result = extractTextViaStringForRange(element: focusedElement, selLocation: selLocation, selLength: selLength),
               // Sanity check: if both prefix and suffix are empty but totalChars > 0,
               // AXStringForRange returned stale data (common after clipboard paste in Chrome).
               !(result.prefix.isEmpty && result.suffix.isEmpty && result.totalChars > 0) {
                prefix = result.prefix
                suffix = result.suffix
                caretPosition = selLocation + selLength
                textLength = result.totalChars
                Log.debug("TextExtract: ranged (prefix=\(prefix.count) suffix=\(suffix.count))")
            } else {
                // Fallback: read full AXValue (expensive for large buffers)
                var valueRef: AnyObject?
                guard AXUIElementCopyAttributeValue(
                    focusedElement,
                    axValue,
                    &valueRef
                ) == .success else {
                    Log.debug("readContext nil: AXValue fallback failed (ranged extract nil) role='\(role)' app=\(appBundleId)")
                    return nil
                }
                let text = valueRef as? String ?? ""
                textLength = text.count

                let rawCaretPosition = selLocation + selLength

                var isWebContent = (role == axWebArea as String)
                if !isWebContent {
                    var domRef: AnyObject?
                    if AXUIElementCopyAttributeValue(focusedElement, axDOMClassList, &domRef) == .success {
                        isWebContent = true
                    }
                }

                if isWebContent && text.contains("\n") {
                    var adjusted = rawCaretPosition
                    for (i, char) in text.enumerated() {
                        if i >= adjusted { break }
                        if char == "\n" { adjusted += 1 }
                    }
                    let adjustedPos = min(adjusted, text.count)
                    let rawClamped = min(rawCaretPosition, text.count)

                    if adjustedPos != rawClamped {
                        let rawIsAtLineBoundary: Bool = {
                            if rawClamped >= text.count { return true }
                            var idx = text.index(text.startIndex, offsetBy: rawClamped)
                            while idx < text.endIndex && text[idx].isWhitespace && !text[idx].isNewline {
                                idx = text.index(after: idx)
                            }
                            return idx >= text.endIndex || text[idx].isNewline
                        }()

                        if rawIsAtLineBoundary {
                            caretPosition = rawClamped
                            Log.debug("CaretFix: raw \(rawCaretPosition) at line boundary, skipping adjustment (would be \(adjustedPos))")
                        } else {
                            caretPosition = adjustedPos
                            Log.debug("CaretFix: web newline adjustment raw=\(rawCaretPosition) → \(adjustedPos) (textLen=\(text.count))")
                        }
                    } else {
                        caretPosition = rawClamped
                    }
                } else {
                    caretPosition = min(rawCaretPosition, text.count)
                }

                let prefixEnd = text.index(text.startIndex, offsetBy: min(caretPosition, text.count), limitedBy: text.endIndex) ?? text.endIndex
                prefix = String(text[text.startIndex..<prefixEnd])
                suffix = String(text[prefixEnd...])
            }
        }

        // Step 6b: Terminal trailing-space re-anchor.
        // macOS Terminal.app trims trailing spaces from each screen row but still
        // reports the insertion point AFTER the (now-absent) space, which resolves to
        // the START of the next row. In a TUI like Claude Code that row is the input
        // box border, so the caret lands just before a box-drawing char: suffix begins
        // with neither whitespace nor newline, isAtEndOfLine is false, and we suppress
        // the suggestion right after every space typed. Re-anchor to the end of the
        // input line (the row-terminating "\n" moves to the suffix → atEOL true); the
        // existing line-wide-rect path then positions the caret on the input line.
        // Scoped to cursor-block hosts so non-terminal apps are unaffected.
        if InsertionRouting.isCursorBlockHost(appBundleId),
           caretPosition > 0, !suffix.isEmpty, prefix.hasSuffix("\n") {
            prefix = String(prefix.dropLast())
            suffix = "\n" + suffix
            caretPosition -= 1
            Log.debug("CaretReanchor (terminal): trailing-space trim → end of input line (caretPos=\(caretPosition))")
        }

        // Step 7: Get caret screen bounds (multi-strategy cascade)
        let caretRect = getCaretRect(element: focusedElement, caretPosition: caretPosition, textLength: textLength, prevChar: prefix.last, nextChar: suffix.first)
        let caretDegraded = (lastRectSource == .s4)

        // Step 7b: Get the text element's frame for constraining the overlay
        let elemFrame = getElementFrame(element: focusedElement) ?? .zero

        // Step 8: Try to detect font (with zoom adjustment for WKWebView/CSS-zoomed apps)
        // Pass prefix for zoom detection (only needs ~10 chars near caret)
        let font = detectFont(element: focusedElement, caretPosition: caretPosition, text: prefix)

        // Step 8b: Detect text area left edge (for headIndent in soft-wrapped text)
        let textLeftEdge = detectTextAreaLeftEdge(element: focusedElement, caretPosition: caretPosition)

        // Step 8c: Terminal caret-X override.
        // Terminal.app's AXBoundsForRange returns bogus zero-range bounds for the
        // caret index whenever any text has been typed on the line. Since
        // `isCursorBlock` hosts are guaranteed monospace, recompute caretX as
        // `textLeftEdge + chars-on-current-visual-line × charWidth`. Only fires
        // when Strategy 1 hit the line-wide path (i.e., the AX result is already
        // known to be derived from line-bounds rather than a clean char bounds).
        let correctedCaretRect = correctTerminalCaretX(
            rect: caretRect,
            prefix: prefix,
            textLeftEdge: textLeftEdge,
            bundleId: appBundleId
        )

        // Step 9: Get input band frame (for screen context cropping)
        let bandFrame = getInputBandFrame(
            element: focusedElement,
            elementFrame: elemFrame,
            bundleId: appBundleId,
            focusedWindow: focusedWindow
        )

        return TextContext(
            textLength: textLength,
            caretPosition: caretPosition,
            prefix: prefix,
            suffix: suffix,
            caretScreenRect: correctedCaretRect ?? .zero,
            elementFrame: elemFrame,
            inputBandFrame: bandFrame,
            appName: appName,
            appBundleId: appBundleId,
            appPid: pidValue,
            windowTitle: windowTitle,
            isPasswordField: isPassword,
            isSearchField: isSearchField,
            font: font,
            textAreaLeftEdge: textLeftEdge,
            caretReadingDegraded: caretDegraded
        )
    }

    /// Result of `probeFocusedField()` — the cheap focused-field metadata that
    /// stays readable when text extraction fails (WhatsApp/iMessage-class).
    struct FocusedFieldProbe {
        let appPid: pid_t
        let appName: String
        let appBundleId: String
        let windowTitle: String
        let elementFrame: CGRect
        let inputBandFrame: CGRect
        let isPasswordField: Bool
        let isSearchField: Bool
    }

    /// Lightweight metadata probe for when `readContext()` returns nil because
    /// TEXT EXTRACTION failed: WhatsApp/iMessage-class Catalyst apps expose a
    /// healthy focused text element (role, subrole, title, frames all read
    /// fine) but fail both AXStringForRange and AXValue while the field is
    /// EMPTY. This reads only the cheap attributes — no text, caret, or font
    /// work — so callers can treat the focus as an empty editable field:
    /// enough for screen-capture cropping and a speculative KV prefill,
    /// neither of which needs field text. Returns nil unless a text-role
    /// element is focused. Attribute sources mirror `readContext()` exactly
    /// (the prefill's appHeader must be token-identical to the real request's).
    func probeFocusedField() -> FocusedFieldProbe? {
        let systemWide = AXUIElementCreateSystemWide()

        var appRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, axFocusedApplication, &appRef) == .success,
              appRef != nil else { return nil }
        let focusedApp = appRef as! AXUIElement

        var pidValue: pid_t = 0
        AXUIElementGetPid(focusedApp, &pidValue)
        let runningApp = NSRunningApplication(processIdentifier: pidValue)
        let appName = runningApp?.localizedName ?? "Unknown"
        let appBundleId = runningApp?.bundleIdentifier ?? ""

        var windowRef: AnyObject?
        var windowTitle = ""
        var focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(focusedApp, axFocusedWindow, &windowRef) == .success,
           let w = windowRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
            focusedWindow = (w as! AXUIElement)
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(focusedWindow!, axTitle, &titleRef) == .success {
                windowTitle = titleRef as? String ?? ""
            }
        }

        var elemRef: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp, axFocusedUIElement, &elemRef) == .success,
              elemRef != nil else { return nil }
        let focusedElement = elemRef as! AXUIElement

        var roleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement, axRole, &roleRef) == .success else { return nil }
        let role = roleRef as? String ?? ""
        let textRoles: Set<String> = [
            axTextField as String,
            axTextArea as String,
            axComboBox as String,
            axWebArea as String
        ]
        guard textRoles.contains(role) else { return nil }

        var isPassword = false
        var isSearchField = false
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(focusedElement, axSubrole, &subroleRef) == .success {
            let subrole = subroleRef as? String ?? ""
            if subrole == axSecureTextField as String {
                isPassword = true
            } else if subrole == axSearchField as String {
                isSearchField = true
            }
        }

        let elemFrame = getElementFrame(element: focusedElement) ?? .zero
        let bandFrame = getInputBandFrame(
            element: focusedElement,
            elementFrame: elemFrame,
            bundleId: appBundleId,
            focusedWindow: focusedWindow
        )

        return FocusedFieldProbe(
            appPid: pidValue,
            appName: appName,
            appBundleId: appBundleId,
            windowTitle: windowTitle,
            elementFrame: elemFrame,
            inputBandFrame: bandFrame,
            isPasswordField: isPassword,
            isSearchField: isSearchField
        )
    }

    /// Context for the reply feature, which (unlike autocomplete) doesn't need the field's
    /// own text — the conversation comes from screen OCR. When `readContext()` returns nil
    /// because text extraction failed (WhatsApp / iMessage-class apps fail both
    /// AXStringForRange and AXValue on an empty field), fall back to the lightweight probe so
    /// the reply can still anchor its badge and draft. Empty prefix/suffix; the caret is
    /// approximated by the element frame (no per-character caret read here).
    func readContextForReply() -> TextContext? {
        if let ctx = readContext() { return ctx }
        if let probe = probeFocusedField(), !probe.isPasswordField,
           probe.elementFrame.width > 0, probe.elementFrame.height > 0 {
            return TextContext(
                textLength: 0,
                caretPosition: 0,
                prefix: "",
                suffix: "",
                caretScreenRect: probe.elementFrame,   // no caret read; anchor the badge to the field
                elementFrame: probe.elementFrame,
                inputBandFrame: probe.inputBandFrame,
                appName: probe.appName,
                appBundleId: probe.appBundleId,
                appPid: probe.appPid,
                windowTitle: probe.windowTitle,
                isPasswordField: probe.isPasswordField,
                isSearchField: probe.isSearchField,
                font: nil,
                textAreaLeftEdge: nil,
                caretReadingDegraded: true
            )
        }
        // Fully AX-blind (WeChat): nothing to probe — anchor to the cursor instead.
        return weChatReplyContext()
    }

    private static let weChatBundleId = "com.tencent.xinWeChat"

    /// WeChat exposes no AX content at all (focused app AND element both nil), so there's
    /// nothing to probe. When it's frontmost, anchor the reply badge to the cursor — the user
    /// must click WeChat's composer to focus it, so the pointer is near the input — and read
    /// the conversation from the window's bottom 95pt band via the WeChat OCR pipeline.
    /// Mirrors Engine.fireWeChatCaptureIfFrontmost (spike; gated to WeChat's bundle id).
    private func weChatReplyContext() -> TextContext? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == Self.weChatBundleId,
              let wf = WindowCapturer.windowBounds(forPid: front.processIdentifier) else { return nil }
        // AppKit mouse coords (y-up) → AX top-left (y-down).
        let mouse = NSEvent.mouseLocation
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let cursor = CGPoint(x: mouse.x, y: screenH - mouse.y)
        guard wf.contains(cursor) else { return nil }   // cursor off the WeChat window → silent
        let caret = CGRect(origin: cursor, size: CGSize(width: 0, height: 20))
        // Conversation comes from the window's bottom 95pt band (full width; the OCR pipeline
        // strips the sidebar). Same band as the autocomplete WeChat capture.
        let inputPts: CGFloat = 95
        let band = CGRect(x: wf.origin.x, y: wf.origin.y + wf.height - inputPts, width: wf.width, height: inputPts)
        return TextContext(
            textLength: 0,
            caretPosition: 0,
            prefix: "",
            suffix: "",
            caretScreenRect: caret,
            elementFrame: caret,            // badge anchors to the cursor
            inputBandFrame: band,           // OCR reads the chat above this band
            appName: front.localizedName ?? "WeChat",
            appBundleId: Self.weChatBundleId,
            appPid: front.processIdentifier,
            windowTitle: "",
            isPasswordField: false,
            isSearchField: false,
            font: nil,
            textAreaLeftEdge: nil,
            caretReadingDegraded: true
        )
    }

    func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Electron/Chromium Accessibility Enablement

    private func ensureAccessibilityEnabled(app: AXUIElement, pid: pid_t, bundleId: String) {
        guard !Self.enabledPids.contains(pid) else { return }
        Self.enabledPids.insert(pid)

        // Known Chromium/Electron bundle ID prefixes and exact matches
        let chromiumBundleIds: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.canary",
            "com.brave.Browser", "com.microsoft.edgemac",
            "com.tinyspeck.slackmacgap",  // Slack
            "com.hnc.Discord",             // Discord
            "com.microsoft.VSCode",        // VS Code
            "com.obsidian",                // Obsidian
            "com.spotify.client",          // Spotify
            "com.figma.Desktop",           // Figma
            "com.linear",                  // Linear
            "com.notion.Notion",           // Notion
            "com.todoist.mac.Todoist",     // Todoist
        ]

        let isChromium = chromiumBundleIds.contains(bundleId)
            || bundleId.hasSuffix(".electron")
            || bundleId.contains("electron")

        guard isChromium else { return }

        // Try AXManualAccessibility first (Electron-specific, fewer side effects)
        let result = AXUIElementSetAttributeValue(
            app,
            axManualAccessibility,
            kCFBooleanTrue
        )

        if result != .success {
            // Fallback to AXEnhancedUserInterface (works for Chrome, has minor side effects)
            AXUIElementSetAttributeValue(
                app,
                axEnhancedUserInterface,
                kCFBooleanTrue
            )
        }
    }

    // MARK: - AXStringForRange Text Extraction

    private struct TextExtractResult {
        let prefix: String
        let suffix: String
        let totalChars: Int
    }

    /// Extract text before/after cursor using AXStringForRange.
    /// AXStringForRange and AXSelectedTextRange use the same coordinate system in all apps
    /// (native, Chromium, Electron), avoiding the Slate.js vs Gmail newline offset mismatch
    /// that occurs when splitting AXValue text at AXSelectedTextRange offsets.
    /// Maximum characters to read for prefix/suffix via AXStringForRange.
    /// Sized to match the largest downstream consumer:
    ///   - non-Claude-Code apps cap at Engine.maxPrefixChars (6000)
    ///   - Claude-Code strips TUI padding + splits at the `❯` marker, then
    ///     caps priorContext at 3500 chars. TUI padding eats ~60% of raw
    ///     bytes, so we need ~12K raw to yield ~3.5K useful content.
    /// Keeps Terminal (825K scrollback) reads bounded; non–Claude-Code apps
    /// still see their last 6000 chars via Engine's cap.
    private static let maxPrefixRead = 12000
    private static let maxSuffixRead = 2000

    private func extractTextViaStringForRange(element: AXUIElement, selLocation: Int, selLength: Int) -> TextExtractResult? {
        // Get total character count (same coordinate system as selectedTextRange)
        var numCharsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            axNumberOfCharacters,
            &numCharsRef
        ) == .success, let totalChars = numCharsRef as? Int, totalChars > 0 else { return nil }

        let cursorEnd = selLocation + selLength

        // Get prefix: read only the last maxPrefixRead chars before the cursor
        let prefixText: String
        if selLocation > 0 {
            let prefixStart = max(0, selLocation - Self.maxPrefixRead)
            let prefixLen = selLocation - prefixStart
            var prefixRange = CFRange(location: prefixStart, length: prefixLen)
            guard let rangeValue = AXValueCreate(.cfRange, &prefixRange) else { return nil }

            var prefixRef: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, axStringForRange, rangeValue, &prefixRef
            ) == .success, let str = prefixRef as? String else { return nil }
            prefixText = str
        } else {
            prefixText = ""
        }

        // Get suffix: read only the first maxSuffixRead chars after the cursor
        let suffixText: String
        if cursorEnd < totalChars {
            let suffixLen = min(Self.maxSuffixRead, totalChars - cursorEnd)
            var suffixRange = CFRange(location: cursorEnd, length: suffixLen)
            guard let rangeValue = AXValueCreate(.cfRange, &suffixRange) else {
                return TextExtractResult(prefix: prefixText, suffix: "", totalChars: totalChars)
            }

            var suffixRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, axStringForRange, rangeValue, &suffixRef
            ) == .success, let str = suffixRef as? String {
                suffixText = str
            } else if totalChars - cursorEnd > 5 {
                suffixText = accumulateSuffixChunks(
                    element: element,
                    start: cursorEnd,
                    windowLen: min(Self.maxSuffixRead, totalChars - cursorEnd)
                )
            } else {
                suffixText = ""
            }
        } else {
            suffixText = ""
        }

        return TextExtractResult(prefix: prefixText, suffix: suffixText, totalChars: totalChars)
    }

    /// Chunked-accumulation fallback for suffix reads. Chromium fails
    /// AXStringForRange when the span crosses certain Gmail quote structures
    /// (blockquote/link boundaries — see a060391); each call resolves its
    /// (start, length) independently, so spans that fail from the cursor
    /// succeed from re-anchored positions. Larger rungs first — the mail-quote
    /// segmentation wants as much of the quote as the structure allows.
    /// Strategy: descending rungs with a TCP-style adaptive entry — enter at
    /// the last successful rung, climb one rung after two consecutive
    /// successes, shrink on failure; when even a 1-char read fails, skip that
    /// position with a newline placeholder (block-boundary semantics) and
    /// re-enter small. Hard call budget bounds worst-case latency (~1ms per
    /// AX call).
    ///
    /// GATING GUARANTEE: the head of the assembled text is identical to what a
    /// single-shot ladder read at `start` would return, and the result is ""
    /// exactly when nothing at `start` is readable at any rung — so
    /// isAtEndOfLine, which inspects the suffix head, is unaffected by
    /// accumulation. (isAtEndOfText sees the whole suffix, so reading MORE
    /// than the old 200-cap ladder can flip it from a false "at end" to a
    /// correct "not at end" — deliberate: that under-read was the Gmail
    /// truncation bug.) Accumulation is pure append beyond the first chunk.
    ///
    /// Note: positions advance in AX index units (`readLen`), while the
    /// assembled string grows by the returned string's own length — the two
    /// can differ across Chromium's flattened-text representations; downstream
    /// consumers only ever see the assembled text, never AX offsets.
    private func accumulateSuffixChunks(element: AXUIElement, start: Int, windowLen: Int) -> String {
        let rungs = [1000, 500, 200, 50, 10, 1]
        let smallRungIdx = rungs.count - 2   // re-entry rung right after a wall (10)
        var acc = ""
        var pos = start
        let end = start + windowLen
        var rungIdx = 0
        var callBudget = 28
        var consecutiveOK = 0
        var firstChunkDone = false
        let t0 = CFAbsoluteTimeGetCurrent()
        while pos < end && callBudget > 0 {
            var advanced = false
            var i = rungIdx
            while i < rungs.count && callBudget > 0 {
                let readLen = min(rungs[i], end - pos)
                guard readLen > 0 else { break }
                var r = CFRange(location: pos, length: readLen)
                guard let rv = AXValueCreate(.cfRange, &r) else { i += 1; continue }
                callBudget -= 1
                var ref: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, axStringForRange, rv, &ref
                ) == .success, let str = ref as? String {
                    acc += str
                    pos += readLen
                    rungIdx = i
                    consecutiveOK += 1
                    if consecutiveOK >= 2 && rungIdx > 0 {
                        rungIdx -= 1   // good terrain: climb a rung
                        consecutiveOK = 0
                    }
                    advanced = true
                    firstChunkDone = true
                    break
                }
                i += 1
                consecutiveOK = 0
            }
            if !advanced {
                // Nothing readable at `pos` at any rung.
                if !firstChunkDone { return "" }  // old-ladder behavior: head unreadable → empty
                acc += "\n"                        // climb over the boundary char
                pos += 1
                rungIdx = smallRungIdx             // re-enter small right after a wall
                consecutiveOK = 0
            }
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        Log.debug("TextExtract: suffix chunked fallback assembled \(acc.count) chars (window \(windowLen), \(28 - callBudget) calls, \(ms)ms)")
        return acc
    }

    // MARK: - AXTextMarker Text Extraction (WebKit document-level web areas)

    /// Extract prefix/suffix around the caret in a WebKit document-level web area
    /// (e.g. Apple Mail's compose body), which returns kAXErrorNoValue for the integer
    /// AXSelectedTextRange. The caret IS exposed as a (collapsed) AXSelectedTextMarkerRange,
    /// and document bounds via AXStartTextMarker / AXEndTextMarker:
    ///   prefix = string for [documentStart … caretStart]
    ///   suffix = string for [caretEnd … documentEnd]
    /// caretPosition is recovered downstream as prefix.count.
    private func extractTextViaTextMarkers(element: AXUIElement) -> TextExtractResult? {
        // Caret as a (collapsed) marker range.
        var selRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axSelectedTextMarkerRange, &selRef) == .success,
              let selRange = selRef else {
            Log.debug("  markers: no AXSelectedTextMarkerRange")
            return nil
        }

        // Decompose the selection into caret start/end markers (equal when collapsed).
        // No AX attribute does this — use the private HIServices C functions.
        guard let caretStart = AXTextMarkerRangeCopyStartMarker(selRange)?.takeRetainedValue() else {
            Log.debug("  markers: no caret start marker")
            return nil
        }
        guard let caretEnd = AXTextMarkerRangeCopyEndMarker(selRange)?.takeRetainedValue() else {
            Log.debug("  markers: no caret end marker")
            return nil
        }

        // Mirror the integer path's selection suppressor (selLength > 0 → nil):
        // accepting a suggestion would replace the selection on insert. CFEqual
        // on identical positions is a free fast-path; differing marker bytes can
        // still encode the same position (node boundary), so confirm via the
        // index bridge before suppressing.
        if !CFEqual(caretStart as CFTypeRef, caretEnd as CFTypeRef),
           let selStart = indexForMarker(element: element, marker: caretStart),
           let selEnd = indexForMarker(element: element, marker: caretEnd),
           selEnd > selStart {
            Log.debug("TextExtract: markers skipped (selection length=\(selEnd - selStart))")
            return nil
        }

        // Document bounds.
        var docStartRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axStartTextMarker, &docStartRef) == .success,
              let docStart = docStartRef else {
            Log.debug("  markers: no AXStartTextMarker")
            return nil
        }
        var docEndRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axEndTextMarker, &docEndRef) == .success,
              let docEnd = docEndRef else {
            Log.debug("  markers: no AXEndTextMarker")
            return nil
        }

        // Bound the SUFFIX read to maxSuffixRead chars instead of serializing caret→docEnd.
        // In Mail replies the caret sits above a large quoted thread, so a whole-body
        // attributed read is hundreds of ms AND re-provokes WebKit's a11y flush. Convert
        // caret→index, then index→a bounded end marker. (Prefix stays whole — it is
        // naturally tiny in Mail, and keeping it preserves the exact caretPosition the
        // caller derives from prefix.count.) Falls back to docEnd if the index/marker
        // bridge is unavailable on this web area.
        // Caret index in marker space, computed ONCE and shared with the recovery gate
        // below. Taken from caretEnd, NOT caretStart: the suppressor above cannot
        // confirm a selection when the index bridge is unavailable, so a non-collapsed
        // selection can still reach here, and a caretStart-based gate would read the
        // selected text back into the suffix; from caretEnd both the bounding and
        // the recovery start strictly after the selection. Collapsed caret: identical.
        let caretIdx = indexForMarker(element: element, marker: caretEnd)
        let suffixEnd: AnyObject = {
            guard let caretIdx else {
                Log.debug("  markers: index/marker bridge unavailable, suffix read unbounded")
                return docEnd
            }
            // caretIdx comes straight from WebKit's AXIndexForTextMarker with no
            // bounds check; a stale/invalid marker can report a garbage index
            // (NSNotFound == Int.max), and Int.max + maxSuffixRead traps on
            // overflow (SIGTRAP). Guard the add; out-of-range falls back to docEnd.
            let (boundIdx, overflowed) = caretIdx.addingReportingOverflow(Self.maxSuffixRead)
            guard !overflowed, let bounded = markerForIndex(element: element, index: boundIdx) else {
                Log.debug("  markers: suffix bound unavailable (overflow=\(overflowed)) — unbounded")
                return docEnd
            }
            return bounded
        }()

        let prefix = stringForMarkerRange(element: element, docStart, caretStart) ?? ""
        var suffix = stringForMarkerRange(element: element, caretEnd, suffixEnd) ?? ""
        // Recovery: in Mail's degraded reply state the whole-span read crossing the
        // quoted-thread boundary returns empty — or a PARTIAL result truncated at
        // the boundary (live-observed: suffix="\n" while the bridge reported 43
        // chars past the caret; the whitespace-only remnant flips end-of-text /
        // end-of-line gating, so suggestions fired mid-text). Rebuild from small
        // marker ranges when the read is whitespace-only yet shorter than the
        // bridge-reported span. Non-whitespace partials can't flip gating (text
        // after the caret suppresses correctly) and are left alone — that also
        // keeps grapheme-vs-offset count mismatches (non-BMP text) from
        // triggering spurious rebuilds. The tolerated set mirrors
        // TextContext.isAtEndOfText (whitespace + zero-width FEFF/200B WebKit
        // anchor chars) — any remnant THAT predicate tolerates can flip gating,
        // so all of it must trigger a rebuild. These are single-scalar BMP
        // characters, so grapheme count == offset span for the compared case
        // (CRLF, the lone multi-scalar whitespace, never reaches this path —
        // WebKit emits "\n"; a spurious rebuild would be content-identical
        // anyway). caretIdx must come from
        // the marker bridge — prefix.count counts graphemes, not WebKit offsets;
        // if the bridge can't resolve it, skip recovery entirely. Typing at the
        // true end of the document costs one docEnd index lookup per read.
        if suffix.allSatisfy({ $0.isWhitespace || $0 == "\u{FEFF}" || $0 == "\u{200B}" }),
           let caretIdx,
           let docLen = indexForMarker(element: element, marker: docEnd) {
            // Same overflow guard as the suffixEnd bound above: a garbage caretIdx
            // near Int.max would trap on the add before min() could clamp it.
            let (capIdx, overflowed) = caretIdx.addingReportingOverflow(Self.maxSuffixRead)
            let readTo = overflowed ? docLen : min(docLen, capIdx)
            if suffix.count < readTo - caretIdx {
                if !suffix.isEmpty {
                    Log.debug("  markers: primary suffix partial (read=\(suffix.count), span=\(readTo - caretIdx))")
                }
                let rebuilt = accumulateMarkerSuffixChunks(element: element, from: caretIdx, to: readTo)
                // Chunker total failure returns "" — keep the primary remnant
                // rather than discarding a possibly-real trailing newline.
                if !rebuilt.isEmpty { suffix = rebuilt }
            }
        }
        return TextExtractResult(prefix: prefix, suffix: suffix, totalChars: prefix.count + suffix.count)
    }

    /// Chunked-accumulation recovery for marker-range suffix reads — the marker-space
    /// sibling of accumulateSuffixChunks on the integer-range path. In Mail's degraded
    /// reply state a single attributed read crossing the quoted-thread boundary returns
    /// empty even though the marker document still holds the full body; small marker
    /// spans and the index↔marker bridge keep working, so rebuild the suffix from
    /// small ranges. Same shape as the integer path: TCP-style rung laddering (shrink
    /// on failure, climb after two consecutive successes), "\n" placeholder when a
    /// position is unreadable at every rung, hard call budget and a 50ms elapsed-time
    /// brake; plus a bail-out after 8 consecutive walls (dead region — don't burn the
    /// budget crawling it). If no real chunk is ever read, returns "" rather than a
    /// placeholder-only string — the caller's suffix.isEmpty gating depends on that.
    /// (Weaker than the sibling's head-unreadable → empty contract: a head wall with
    /// later successes still returns a "\n"-headed suffix here.)
    ///
    /// An EMPTY string for a non-empty span counts as failure — accepting it would
    /// silently lose text while pos advances. On success, pos advances by the
    /// REQUESTED span, not chunk.count: marker index space and Swift Character count
    /// can disagree (surrogate pairs), and markerForIndex clamps past-end indices,
    /// so requested-span advancement guarantees termination without overlap.
    private func accumulateMarkerSuffixChunks(element: AXUIElement, from: Int, to: Int) -> String {
        let rungs = [500, 250, 100, 25]
        var acc = ""
        var pos = from
        var rungIdx = 0
        var calls = 0
        let callBudget = 60        // one position = 1 start-marker call + up to 3 calls per rung attempt
        var consecutiveOK = 0
        var consecutiveWalls = 0
        var walls = 0
        var gotRealChunk = false
        let t0 = CFAbsoluteTimeGetCurrent()
        let deadline = t0 + 0.05   // a stalled a11y server must not own the keystroke
        while pos < to && calls + 4 <= callBudget && CFAbsoluteTimeGetCurrent() < deadline {
            var advanced = false
            // Start marker doesn't depend on rung size — fetch once per position;
            // if it fails here it fails at every rung (AX reads are deterministic).
            calls += 1
            if let a = markerForIndex(element: element, index: pos) {
                var i = rungIdx
                while i < rungs.count && calls + 3 <= callBudget && CFAbsoluteTimeGetCurrent() < deadline {
                    let size = min(rungs[i], to - pos)
                    guard size > 0 else { break }
                    calls += 1
                    if let b = markerForIndex(element: element, index: pos + size) {
                        calls += 2   // stringForMarkerRange = range build + attributed read
                        if let chunk = stringForMarkerRange(element: element, a, b), !chunk.isEmpty {
                            acc += chunk
                            pos += size
                            rungIdx = i
                            consecutiveOK += 1
                            consecutiveWalls = 0
                            gotRealChunk = true
                            if consecutiveOK >= 2 && rungIdx > 0 {
                                rungIdx -= 1   // good terrain: climb a rung
                                consecutiveOK = 0
                            }
                            advanced = true
                            break
                        }
                    }
                    consecutiveOK = 0
                    // Skip rungs that clamp to the SAME span — retrying an identical
                    // read is pointless, but a genuinely smaller rung still gets its
                    // try (e.g. span 300: rung 500 clamps to 300 and fails; rung 250
                    // reads a different span and may succeed). Exhaustion → wall.
                    repeat { i += 1 } while i < rungs.count && min(rungs[i], to - pos) == size
                }
            }
            if !advanced {
                if calls + 3 > callBudget || CFAbsoluteTimeGetCurrent() >= deadline {
                    break   // budget/time exhausted mid-ladder, not a wall
                }
                // Nothing readable at `pos` even at the smallest rung.
                walls += 1
                consecutiveWalls += 1
                if consecutiveWalls >= 8 { break }   // dead region
                acc += "\n"                          // climb over the boundary char
                pos += 1
                rungIdx = rungs.count - 1            // re-enter small right after a wall
                consecutiveOK = 0
            }
        }
        if !gotRealChunk { acc = "" }   // placeholder-only: never fabricate a suffix
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        Log.debug("TextExtract: marker suffix chunked \(acc.count) chars (span \(to - from), \(calls) calls, \(walls) walls, \(ms)ms)")
        return acc
    }

    /// Integer character index of a text marker (inverse of AXTextMarkerForIndex).
    private func indexForMarker(element: AXUIElement, marker: AnyObject) -> Int? {
        var ref: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, axIndexForTextMarker, marker as CFTypeRef, &ref
        ) == .success, let n = ref as? Int else { return nil }
        return n
    }

    /// Text marker at the given character index (out-of-range / unsupported → nil).
    private func markerForIndex(element: AXUIElement, index: Int) -> AnyObject? {
        guard index >= 0 else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, axTextMarkerForIndex, index as CFTypeRef, &ref
        ) == .success, let marker = ref else { return nil }
        return marker
    }

    /// Build a marker range from two (unordered) markers and return its plain string.
    private func stringForMarkerRange(element: AXUIElement, _ a: AnyObject, _ b: AnyObject) -> String? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, axTextMarkerRangeForUnorderedTextMarkers, [a, b] as CFArray, &rangeRef
        ) == .success, let markerRange = rangeRef else { return nil }

        var attrRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, axAttributedStringForTextMarkerRange, markerRange, &attrRef
        ) == .success, let attrStr = attrRef as? NSAttributedString else { return nil }
        return attrStr.string
    }

    // MARK: - Multi-Strategy Caret Position

    private func getCaretRect(element: AXUIElement, caretPosition: Int, textLength: Int, prevChar: Character?, nextChar: Character?) -> CGRect? {
        lastRectSource = nil
        lastRectViaLineWideRect = false

        // Strategy 1: Standard AXBoundsForRange (works for native macOS apps)
        if let rect = getCaretRectViaBoundsForRange(element: element, caretPosition: caretPosition, textLength: textLength, prevChar: prevChar, nextChar: nextChar),
           isValidCaretRect(rect) {
            Log.debug("Caret strategy 1: \(rect)")
            lastRectSource = .s1
            return rect
        }

        // Strategy 2: Text Marker API (works for Chrome/Electron web content)
        if let rect = getCaretRectViaTextMarkers(element: element),
           isValidCaretRect(rect) {
            Log.debug("Caret strategy 2: \(rect)")
            lastRectSource = .s2
            return rect
        }

        // Strategy 3: Walk AXStaticText children (Chromium exposes AXBoundsForRange on these)
        if let rect = getCaretRectViaStaticTextChildren(element: element, caretPosition: caretPosition),
           isValidCaretRect(rect) {
            Log.debug("Caret strategy 3: \(rect)")
            lastRectSource = .s3
            return rect
        }

        // Strategy 4: Element frame + line number approximation (last resort)
        if let rect = getCaretRectViaElementFrame(element: element) {
            Log.debug("Caret strategy 4: \(rect)")
            // TEMPORARY DIAGNOSTIC — remove together with describeAXElement()
            // below once the LinkedIn-messaging "no suggestions" issue is
            // resolved. Tracking which AX role the focused element reports
            // when text APIs are unavailable, so we know whether to walk
            // children, retry, or fall back to OCR. Costs ~5–25ms (5 IPC
            // reads) only on this failure path; zero impact on normal
            // typing where strategies 1-3 hit. See investigation notes in
            // the related session for details.
            //
            // Common offenders we want to identify here:
            //   AXGroup / AXUnknown — Lexical/Quill/CodeMirror editors
            //     in shadow DOM that didn't get a textbox role applied
            //   AXButton / AXMenuItem — focus stuck on UI chrome instead
            //     of the editor
            //   AXTextArea but missing text APIs — Chrome a11y mode is
            //     incomplete (rare; would point back to lazy a11y)
            Log.info("[AXDebug] strategy 4 (text APIs unavailable) | \(describeAXElement(element))")
            lastRectSource = .s4
            return rect
        }

        Log.debug("Caret: all strategies failed")
        return nil
    }

    /// TEMPORARY — paired with the [AXDebug] log in strategy 4 above.
    /// Delete this whole method when the LinkedIn-messaging issue is
    /// fixed; nothing else calls it.
    ///
    /// Read AX identity attributes for diagnostic logging. Returns a
    /// compact one-line summary suitable for a Log line. All reads are
    /// best-effort — missing attributes are reported as `<nil>` rather
    /// than failing the whole probe.
    private func describeAXElement(_ element: AXUIElement) -> String {
        func readString(_ attribute: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let s = ref as? String, !s.isEmpty else { return "<nil>" }
            return s
        }
        let role = readString(kAXRoleAttribute)
        let subrole = readString(kAXSubroleAttribute)
        let roleDesc = readString(kAXRoleDescriptionAttribute)
        let identifier = readString(kAXIdentifierAttribute)
        // DOM class/id leaks via AXDOMClassList on Chromium for web content.
        // Not part of the public AX API, but Chrome ships it; if absent the
        // attribute read just returns <nil> and we move on.
        var domClass = "<nil>"
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &ref) == .success,
           let arr = ref as? [String], !arr.isEmpty {
            domClass = arr.prefix(3).joined(separator: " ")
        }
        return "role=\(role) subrole=\(subrole) desc='\(roleDesc.prefix(40))' id='\(identifier.prefix(40))' domClass='\(domClass.prefix(60))'"
    }

    /// Validate that a caret rect is plausible (not zero, not the known Electron failure pattern)
    private func isValidCaretRect(_ rect: CGRect) -> Bool {
        // Reject zero rect
        if rect.origin.x == 0 && rect.origin.y == 0 && rect.width == 0 && rect.height == 0 {
            return false
        }
        // Reject if both dimensions are zero (just a point at origin)
        if rect.width == 0 && rect.height == 0 {
            return false
        }
        // Reject the known Electron failure pattern: x≈0, y≈primaryScreenHeight
        if let primaryHeight = NSScreen.screens.first?.frame.height {
            if rect.origin.x < 2 && abs(rect.origin.y - primaryHeight) < 2 {
                return false
            }
        }
        return true
    }

    // MARK: Strategy 1: AXBoundsForRange (native apps)

    private func getCaretRectViaBoundsForRange(element: AXUIElement, caretPosition: Int, textLength: Int, prevChar: Character?, nextChar: Character?) -> CGRect? {
        // "Previous-character + right edge" with line-number disambiguation.
        //
        // The Safari Gmail bug (2026-04-08): in WebKit contenteditables that contain a
        // sibling structured node (e.g. a <blockquote> with quoted email history), querying
        // AXBoundsForRange for [cursor, 1] returns the bounds of the character at the cursor
        // offset in the *linear* text — which is the FIRST CHAR OF THE BLOCKQUOTE, visually
        // far below the actual cursor on the user's line. The character at [cursor-1, 1]
        // is in the user's typed content, so its right edge gives the correct caret position.
        //
        // But: if the cursor is at the start of a wrapped line (right after a soft wrap or
        // a newline), [cursor-1, 1] is at the END of the previous visual line, not the
        // start of the cursor's line. So we can't unconditionally prefer [cursor-1, 1] —
        // we need to disambiguate using AXInsertionPointLineNumber when the two queries
        // return different Y values.
        //
        // Edge cases (cursor at position 0 or at the very end of text) only need ONE query;
        // we check them up front to avoid wasted AX IPC calls. Mid-text editing requires
        // two queries for the disambiguation, which is the cost of correctness.

        // Edge case: cursor at start of text — only one AX call needed.
        if caretPosition == 0 {
            let rectNext = queryBoundsForRange(element: element, location: 0, length: 1)
            return processCaretRect(rectNext, element: element, caretPosition: caretPosition, useRightEdge: false)
        }

        // Edge case: cursor at end of all text — only one AX call needed. This is the
        // common "typing at the end of a field" path; querying [cursor, 1] here would
        // query past the end and waste an IPC round-trip. Matches the original pre-fix
        // behavior.
        if caretPosition >= textLength {
            let rectPrev = queryBoundsForRange(element: element, location: caretPosition - 1, length: 1)
            return processCaretRect(rectPrev, element: element, caretPosition: caretPosition, useRightEdge: true)
        }

        // Mid-text: query both [cursor, 1] and [cursor-1, 1] for disambiguation.
        let rectNext = queryBoundsForRange(element: element, location: caretPosition, length: 1)
        let rectPrev = queryBoundsForRange(element: element, location: caretPosition - 1, length: 1)

        // Line-wide rect handling (Terminal, Stickies). If the next-char query came back
        // line-wide, use the existing refineCaretXPosition path with the original rect
        // rather than trying to disambiguate via Y-comparison (which doesn't work when
        // both rects span the whole line).
        if let r = rectNext, r.width > 50 {
            Log.debug("Bounds returned line-wide rect (\(r.width)pt), using left edge")
            lastRectViaLineWideRect = true
            if let refined = refineCaretXPosition(element: element, caretPosition: caretPosition, lineRect: r) {
                return refined
            }
            var rect = r
            rect.size.width = 1
            return rect
        }

        // Both queries available — pick whichever rect is on the cursor's line.
        switch (rectNext, rectPrev) {
        case (nil, nil):
            return nil
        case (.some(let n), nil):
            return processCaretRect(n, element: element, caretPosition: caretPosition, useRightEdge: false)
        case (nil, .some(let p)):
            return processCaretRect(p, element: element, caretPosition: caretPosition, useRightEdge: true)
        case (.some(let n), .some(let p)):
            let (chosen, useRightEdge) = chooseBetweenCaretRects(next: n, prev: p, element: element, prevChar: prevChar, nextChar: nextChar)
            return processCaretRect(chosen, element: element, caretPosition: caretPosition, useRightEdge: useRightEdge)
        }
    }

    /// Decide which of the two `AXBoundsForRange` results (the character at the cursor
    /// position vs the character before the cursor) is on the cursor's visual line.
    /// Returns (rect, useRightEdge): if true, the caret X is the right edge of the rect;
    /// if false, the caret X is the left edge.
    private func chooseBetweenCaretRects(next: CGRect, prev: CGRect, element: AXUIElement, prevChar: Character?, nextChar: Character?) -> (CGRect, Bool) {
        // Estimate line height from the character heights (close enough — line spacing
        // typically adds <2px on top of glyph height).
        let lineHeight = max(prev.height, next.height, 12.0)
        let yDiff = next.origin.y - prev.origin.y
        let absYDiff = abs(yDiff)

        // Same Y → both characters are on the same visual line. Prefer prev+rightEdge;
        // this is correct in normal mid-line cursor and also in the
        // Safari Gmail bug case (where both rects happen to have similar Y because
        // the bug only manifests when next-char is in a sibling DOM node — in which
        // case yDiff is large and we fall through to the disambiguation branch).
        if absYDiff < lineHeight * 0.5 {
            return (prev, true)
        }

        // Y differs — either line-wrap (prev on line N-1, next on line N) or
        // sibling-DOM-node bug (next is somewhere far away). Use AXInsertionPointLineNumber
        // to identify the cursor's actual line, then pick the rect whose Y matches.
        if let cursorLine = readInsertionPointLineNumber(element: element),
           let elementTop = readElementTop(element: element) {
            let expectedY = elementTop + CGFloat(cursorLine) * lineHeight
            let prevError = abs(prev.origin.y - expectedY)
            let nextError = abs(next.origin.y - expectedY)
            Log.debug("CaretChoose: cross-line (yDiff=\(yDiff)), lineNum=\(cursorLine), expectedY=\(expectedY), prevErr=\(prevError), nextErr=\(nextError)")
            if prevError <= nextError {
                return (prev, true)
            } else {
                return (next, false)
            }
        }

        // No line-number support. Heuristic fallback:
        // - If next is roughly one line below prev → line-wrap case → use next.
        // - Otherwise (jump > 1.5 lines, or next is above prev) → assume sibling-DOM-node
        //   bug → use prev with right edge.
        if yDiff > 0 && absYDiff < lineHeight * 1.5 {
            // "next is ~one line below prev" is normally a soft wrap (caret at the start of
            // the wrapped line → use next). But it ALSO happens when the caret sits at the
            // end of a non-empty line ended by a hard newline whose following paragraph or
            // blockquote begins on the next visual line (Apple Mail reply above quoted
            // history): there [cursor,1] is the '\n', which WebKit lays out at the start of
            // that next line. Then the caret belongs at the right edge of the typed content
            // (prev), not down on the quoted block. Disambiguate via the surrounding chars:
            // hard newline right after real content ⇒ prev; soft wrap or empty line ⇒ next.
            if nextChar == "\n" && prevChar != "\n" {
                Log.debug("CaretChoose: hard newline after content (yDiff=\(yDiff)) → prev")
                return (prev, true)
            }
            Log.debug("CaretChoose: heuristic line-wrap (yDiff=\(yDiff), lineHeight=\(lineHeight))")
            return (next, false)
        }
        Log.debug("CaretChoose: heuristic large-jump (yDiff=\(yDiff), lineHeight=\(lineHeight)), preferring prev")
        return (prev, true)
    }

    private func queryBoundsForRange(element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var queryRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &queryRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axBoundsForRange,
            rangeValue,
            &boundsRef
        ) == .success else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)
        return rect
    }

    private func readInsertionPointLineNumber(element: AXUIElement) -> Int? {
        var lineRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axInsertionPointLineNumber, &lineRef) == .success else { return nil }
        return lineRef as? Int
    }

    private func readElementTop(element: AXUIElement) -> CGFloat? {
        var posRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axPosition, &posRef) == .success else { return nil }
        var position = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        guard position.y.isFinite, abs(position.y) < 100_000 else { return nil }
        return position.y
    }

    /// Apply line-wide-rect refinement and right-edge offset to a raw AXBoundsForRange result,
    /// then normalize to 1px width at the caret position.
    private func processCaretRect(_ rect: CGRect?, element: AXUIElement, caretPosition: Int, useRightEdge: Bool) -> CGRect? {
        guard var rect = rect else { return nil }

        // Some apps (Terminal, Stickies) return the entire line bounds instead of a
        // single character. Detect this: a single char shouldn't be wider than ~50pt.
        if rect.width > 50 {
            Log.debug("Bounds returned line-wide rect (\(rect.width)pt), using left edge")
            lastRectViaLineWideRect = true
            if let refined = refineCaretXPosition(element: element, caretPosition: caretPosition, lineRect: rect) {
                return refined
            }
            rect.size.width = 1
            return rect
        }

        if useRightEdge {
            rect.origin.x += rect.width
        }
        // Always normalize to 1px width at the caret position.
        // When useRightEdge=false, the rect is the character AFTER the caret —
        // the caret is at the left edge. Without this, the character width
        // (e.g. 14px for a newline in Outlook) creates a visible gap.
        rect.size.width = 1
        return rect
    }

    /// When AXBoundsForRange returns full-line bounds, try to calculate the X offset
    /// by comparing bounds of adjacent characters or using line geometry.
    private func refineCaretXPosition(element: AXUIElement, caretPosition: Int, lineRect: CGRect) -> CGRect? {
        // Try querying bounds for position 0 to get character width, then calculate offset
        // First, try bounds for a range of length 0 at the caret (some apps support this)
        var zeroRange = CFRange(location: caretPosition, length: 0)
        if let zeroRangeValue = AXValueCreate(.cfRange, &zeroRange) {
            var boundsRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                axBoundsForRange,
                zeroRangeValue,
                &boundsRef
            ) == .success {
                var rect = CGRect.zero
                AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)
                if rect.width <= 50 && rect.height > 0 {
                    return CGRect(x: rect.origin.x, y: lineRect.origin.y, width: 1, height: lineRect.height)
                }
            }
        }

        // Try to estimate character width from a known position near the start of the line
        // Get the line number for this position, then get the range for that line
        var lineNumRef: AnyObject?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            axLineForIndex,
            caretPosition as CFTypeRef,
            &lineNumRef
        ) == .success, let lineNum = lineNumRef as? Int {
            // Get the range for this line
            var lineRangeRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                axRangeForLine,
                lineNum as CFTypeRef,
                &lineRangeRef
            ) == .success {
                var lineCFRange = CFRange(location: 0, length: 0)
                AXValueGetValue(lineRangeRef as! AXValue, .cfRange, &lineCFRange)

                // Characters from line start to caret
                let charsIntoCaret = caretPosition - lineCFRange.location

                // Estimate character width from line width / line length
                if lineCFRange.length > 0 {
                    let charWidth = lineRect.width / CGFloat(lineCFRange.length)
                    let caretX = lineRect.origin.x + CGFloat(charsIntoCaret) * charWidth
                    return CGRect(x: caretX, y: lineRect.origin.y, width: 1, height: lineRect.height)
                }
            }
        }

        return nil
    }

    /// For monospace hosts (terminals) where Strategy 1 hit the line-wide-rect
    /// path, override caretX. Terminal.app returns a bogus line-wide rect for the
    /// zero-length range at the caret once text is on the line, so Strategy 1's x
    /// is useless. Since the host is monospace we derive caretX geometrically:
    ///
    ///     caretX = textLeftEdge + displayColumns × cellWidth
    ///
    /// displayColumns counts CJK / fullwidth chars as two cells. cellWidth is
    /// derived from the line height (× `terminalCellAspect`), NOT from
    /// AXBoundsForRange: Terminal's AX quantizes per-character bounds to an integer
    /// point width (e.g. 7.0) narrower than the real rendered cell (~7.x), so an
    /// AX-derived width drifts the ghost left, growing with column count. A
    /// height-derived width tracks the real cell and scales with font size.
    /// (Verified: AX reports an identical integer width for single-char and
    /// multi-char range queries alike, so the real fraction can't be recovered
    /// from AX at all — see the `[CellProbe]` investigation.)
    private func correctTerminalCaretX(
        rect: CGRect?,
        prefix: String,
        textLeftEdge: CGFloat?,
        bundleId: String
    ) -> CGRect? {
        guard let rect = rect,
              lastRectViaLineWideRect,
              InsertionRouting.isCursorBlockHost(bundleId),
              let textLeftEdge = textLeftEdge else {
            return rect
        }

        // Display columns on the current visual line (everything after the last
        // `\n` in prefix). CJK / fullwidth chars occupy two monospace cells, so a
        // plain grapheme count would undercount and push the ghost left.
        let lastLine: Substring
        if let lastNewline = prefix.lastIndex(of: "\n") {
            lastLine = prefix[prefix.index(after: lastNewline)...]
        } else {
            lastLine = Substring(prefix)
        }
        let displayCols = PostProcessor.displayWidth(of: String(lastLine))

        let cellWidth = rect.height * Self.terminalCellAspect
        let overrideX = textLeftEdge + CGFloat(displayCols) * cellWidth

        Log.debug("CaretOverride (terminal): cols=\(displayCols) cellW=\(String(format: "%.2f", cellWidth)) h=\(Int(rect.height)) textLeft=\(Int(textLeftEdge)) → x=\(Int(overrideX)) (was \(Int(rect.origin.x)))")
        return CGRect(x: overrideX, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    // MARK: Strategy 2: Text Marker API (Chromium web content)

    private func getCaretRectViaTextMarkers(element: AXUIElement) -> CGRect? {
        var markerRangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            axSelectedTextMarkerRange,
            &markerRangeRef
        ) == .success, let markerRange = markerRangeRef else { return nil }

        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axBoundsForTextMarkerRange,
            markerRange,
            &boundsRef
        ) == .success else { return nil }

        var rect = CGRect.zero
        AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)

        // When selection is collapsed (caret), width may be 0 — that's fine
        // But if we get a zero rect, it's a failure
        if rect.height > 0 {
            return rect
        }

        return nil
    }

    // MARK: Strategy 3: Walk AXStaticText children

    private func getCaretRectViaStaticTextChildren(element: AXUIElement, caretPosition: Int) -> CGRect? {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            axChildren,
            &childrenRef
        ) == .success else { return nil }

        guard let children = childrenRef as? [AXUIElement] else { return nil }

        var offset = 0
        for child in children {
            var roleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(child, axRole, &roleRef) == .success else { continue }

            let childRole = roleRef as? String ?? ""
            guard childRole == (axStaticText as String) else {
                // Still accumulate length from non-static-text children if they have a value
                var valRef: AnyObject?
                if AXUIElementCopyAttributeValue(child, axValue, &valRef) == .success {
                    let val = valRef as? String ?? ""
                    offset += val.count
                }
                continue
            }

            var valueRef: AnyObject?
            guard AXUIElementCopyAttributeValue(child, axValue, &valueRef) == .success else { continue }
            let childText = valueRef as? String ?? ""

            let childEnd = offset + childText.count
            if caretPosition >= offset && caretPosition <= childEnd {
                let localPosition = caretPosition - offset
                let queryLoc = min(localPosition, max(0, childText.count - 1))
                let useRightEdge = localPosition >= childText.count

                var queryRange = CFRange(location: queryLoc, length: 1)
                guard let rangeValue = AXValueCreate(.cfRange, &queryRange) else { continue }

                var boundsRef: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    child,
                    axBoundsForRange,
                    rangeValue,
                    &boundsRef
                ) == .success {
                    var rect = CGRect.zero
                    AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)
                    if useRightEdge {
                        rect.origin.x += rect.width
                        rect.size.width = 1
                    }
                    return rect
                }
            }
            offset = childEnd
        }

        return nil
    }

    // MARK: Strategy 4: Element frame + line number (last resort)

    private func getCaretRectViaElementFrame(element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?

        guard AXUIElementCopyAttributeValue(element, axPosition, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, axSize, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        // Reject garbage values from stale Chrome AX state. Coordinates beyond
        // ~2^53 lose Double precision and produce NaN/Inf in arithmetic later.
        // Real screen coordinates are always well under 100000.
        guard position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              abs(position.x) < 100_000, abs(position.y) < 100_000,
              size.width >= 0, size.width < 100_000,
              size.height >= 0, size.height < 100_000
        else { return nil }

        let lineHeight: CGFloat = 20

        // Try to refine Y position using insertion point line number
        var lineRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, axInsertionPointLineNumber, &lineRef) == .success {
            let lineNumber = (lineRef as? Int) ?? 0
            if lineNumber > 0 {
                let yOffset = CGFloat(lineNumber) * lineHeight
                return CGRect(
                    x: position.x,
                    y: position.y + yOffset,
                    width: 1,
                    height: lineHeight
                )
            }
        }

        // Absolute fallback: top-right of the element (like Grammarly's floating tab)
        return CGRect(
            x: position.x + size.width,
            y: position.y,
            width: 1,
            height: min(size.height, lineHeight)
        )
    }

    // MARK: - Element Frame

    private func getElementFrame(element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?

        guard AXUIElementCopyAttributeValue(element, axPosition, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, axSize, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    // MARK: - Input Band Frame

    /// Walk up the AX parent chain to find the input band container.
    /// The input band is the first ancestor that is wider than the input field
    /// and shares a similar vertical position (same row), capped at 3 levels.
    private func getInputBandFrame(element: AXUIElement, elementFrame: CGRect, bundleId: String, focusedWindow: AXUIElement?) -> CGRect {
        // Per-app overrides for apps whose default 3-level walk lands on too narrow a band.
        if bundleId == "com.openai.chat",
           let convX = chatGPTConversationFrame(element: element) {
            // Use conversation list's x/width but keep element's y/height so cropper
            // computes the correct vertical extent (window-top to input-top).
            return CGRect(x: convX.minX, y: elementFrame.minY, width: convX.width, height: elementFrame.height)
        }

        // Telegram: AX tree below the textarea is locked down. Recover conversation pane
        // bounds by extending textarea content box: ~60pt left (covers message-bubble avatars
        // and a small leading margin) and right-anchor to the focused window's right edge
        // (the right side of the conversation pane always touches the window edge — there's
        // no right sidebar).
        if bundleId == "ru.keepcoder.Telegram" || bundleId == "org.telegram.desktop",
           let win = focusedWindow,
           let winFrame = getElementFrame(element: win) {
            let leftPad: CGFloat = 60
            let x = max(winFrame.minX, elementFrame.minX - leftPad)
            let width = winFrame.maxX - x
            return CGRect(x: x, y: elementFrame.minY, width: width, height: elementFrame.height)
        }

        var current: AXUIElement = element
        for _ in 0..<3 {
            var parentRef: AnyObject?
            guard AXUIElementCopyAttributeValue(current, axParent, &parentRef) == .success else { break }
            let parent = parentRef as! AXUIElement

            guard let parentFrame = getElementFrame(element: parent) else { break }

            // The input band should be wider but roughly the same row height.
            // Reject tall containers (conversation + input panels) by checking
            // that the parent isn't dramatically taller than the input field.
            let elementBottom = elementFrame.origin.y + elementFrame.height
            let parentBottom = parentFrame.origin.y + parentFrame.height
            let bottomAligned = abs(parentBottom - elementBottom) < 20
            let similarHeight = parentFrame.height < elementFrame.height * 3

            if parentFrame.width > elementFrame.width && bottomAligned && similarHeight {
                return parentFrame
            }

            current = parent
        }
        // Fallback to the element frame itself
        return elementFrame
    }

    /// ChatGPT-specific: the AX hierarchy exposes the conversation list as an AXScrollArea
    /// containing an AXList, sibling to the input's own AXScrollArea. Its frame matches
    /// the visible conversation column (wider than the textarea content box). Works for
    /// both the main window and the Option+Space launcher — same structure either way.
    private func chatGPTConversationFrame(element: AXUIElement) -> CGRect? {
        var current = element
        for _ in 0..<2 {
            var parentRef: AnyObject?
            guard AXUIElementCopyAttributeValue(current, axParent, &parentRef) == .success else { return nil }
            current = parentRef as! AXUIElement
        }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children where axRoleString(child) == "AXScrollArea" {
            var subRef: AnyObject?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &subRef) == .success,
                  let sub = subRef as? [AXUIElement] else { continue }
            if sub.contains(where: { axRoleString($0) == "AXList" }) {
                return getElementFrame(element: child)
            }
        }
        return nil
    }

    private func axRoleString(_ element: AXUIElement) -> String {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axRole, &ref) == .success else { return "?" }
        return (ref as? String) ?? "?"
    }

    // MARK: - Text Area Left Edge Detection

    /// Detect the X coordinate where text content begins in the text area.
    /// Uses AXLineForIndex + AXRangeForLine + AXBoundsForRange to find the left edge
    /// of text on a visual line, which is more accurate than elementFrame when the
    /// element frame includes padding or belongs to a wider parent container.
    private func detectTextAreaLeftEdge(element: AXUIElement, caretPosition: Int) -> CGFloat? {
        guard caretPosition > 0 else { Log.debug("TextAreaLeftEdge: caretPosition=0, skipping"); return nil }

        // Check if AX line APIs are available by querying the current visual line
        var lineNumRef: AnyObject?
        let lineResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            axLineForIndex,
            max(0, caretPosition - 1) as CFTypeRef,
            &lineNumRef
        )
        guard lineResult == .success, let currentLine = lineNumRef as? Int else {
            Log.debug("TextAreaLeftEdge: line index failed (error=\(lineResult.rawValue)), trying children fallback")
            return detectTextAreaLeftEdgeViaChildren(element: element)
        }

        // Prefer a wrapped line (line > 0) since position 0 can return garbage in Electron
        if currentLine > 0 {
            for line in stride(from: min(currentLine, 3), through: 1, by: -1) {
                if let leftEdge = getLineLeftEdge(element: element, lineNumber: line) {
                    Log.debug("TextAreaLeftEdge: from visual line \(line): x=\(Int(leftEdge))")
                    return leftEdge
                }
            }
        }

        // Try line 0 as fallback
        if let leftEdge = getLineLeftEdge(element: element, lineNumber: 0) {
            Log.debug("TextAreaLeftEdge: from line 0: x=\(Int(leftEdge))")
            return leftEdge
        }

        Log.debug("TextAreaLeftEdge: line index OK (line=\(currentLine)) but getLineLeftEdge failed, trying children fallback")
        return detectTextAreaLeftEdgeViaChildren(element: element)
    }

    /// Fallback: walk AXStaticText children and query AXBoundsForRange for the first character.
    /// Works for Electron/Chromium where AXLineForIndex is unsupported on the parent element.
    private func detectTextAreaLeftEdgeViaChildren(element: AXUIElement) -> CGFloat? {
        // Walk up to 3 levels deep to find an AXStaticText with valid AXBoundsForRange
        return findStaticTextLeftEdge(element: element, depth: 0)
    }

    private func findStaticTextLeftEdge(element: AXUIElement, depth: Int) -> CGFloat? {
        guard depth < 3 else { return nil }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, axChildren, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(child, axRole, &roleRef) == .success else { continue }
            let childRole = roleRef as? String ?? ""

            if childRole == (axStaticText as String) {
                // Try AXBoundsForRange for the first character
                var charRange = CFRange(location: 0, length: 1)
                guard let rangeValue = AXValueCreate(.cfRange, &charRange) else { continue }

                var boundsRef: AnyObject?
                guard AXUIElementCopyParameterizedAttributeValue(
                    child,
                    axBoundsForRange,
                    rangeValue,
                    &boundsRef
                ) == .success else { continue }

                var rect = CGRect.zero
                AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)

                if rect.origin.x > 0 && rect.height > 0 {
                    Log.debug("TextAreaLeftEdge: from child at depth \(depth): x=\(Int(rect.origin.x))")
                    return rect.origin.x
                }
            }

            // Recurse into groups and other container roles
            if let result = findStaticTextLeftEdge(element: child, depth: depth + 1) {
                return result
            }
        }

        return nil
    }

    /// Get the X coordinate of the first character on the given visual line.
    private func getLineLeftEdge(element: AXUIElement, lineNumber: Int) -> CGFloat? {
        var lineRangeRef: AnyObject?
        let rangeResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            axRangeForLine,
            lineNumber as CFTypeRef,
            &lineRangeRef
        )
        guard rangeResult == .success else {
            Log.debug("TextAreaLeftEdge: rangeForLine(\(lineNumber)) failed (error=\(rangeResult.rawValue))")
            return nil
        }

        var lineRange = CFRange(location: 0, length: 0)
        AXValueGetValue(lineRangeRef as! AXValue, .cfRange, &lineRange)
        guard lineRange.length > 0 else {
            Log.debug("TextAreaLeftEdge: rangeForLine(\(lineNumber)) returned empty range")
            return nil
        }

        var charRange = CFRange(location: lineRange.location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &charRange) else { return nil }

        var boundsRef: AnyObject?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            axBoundsForRange,
            rangeValue,
            &boundsRef
        )
        guard boundsResult == .success else {
            Log.debug("TextAreaLeftEdge: bounds(loc=\(lineRange.location)) failed (error=\(boundsResult.rawValue))")
            return nil
        }

        var rect = CGRect.zero
        AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)

        // Validate - reject garbage values (known Electron issue with position 0)
        if rect.origin.x > 0 && rect.height > 0 {
            return rect.origin.x
        }

        Log.debug("TextAreaLeftEdge: bounds(loc=\(lineRange.location)) returned invalid rect: \(rect)")
        return nil
    }

    // MARK: - Font Detection

    private func detectFont(element: AXUIElement, caretPosition: Int, text: String) -> NSFont? {
        guard caretPosition > 0 else { return nil }

        // Strategy 1: AXAttributedStringForRange (native apps — exact)
        var queryRange = CFRange(location: max(0, caretPosition - 1), length: 1)
        if let rangeValue = AXValueCreate(.cfRange, &queryRange) {
            var attrRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                axAttributedStringForRange,
                rangeValue,
                &attrRef
            ) == .success, let attrString = attrRef as? NSAttributedString, attrString.length > 0 {
                let attrs = attrString.attributes(at: 0, effectiveRange: nil)
                if let font = attrs[.font] as? NSFont {
                    Log.debug("FontDetect: strategy 1a → \(font.fontName) \(String(format: "%.1f", font.pointSize))pt")
                    return adjustFontForZoom(font: font, element: element, caretPosition: caretPosition, text: text)
                }
                if let font = fontFromAXDict(attrs) {
                    Log.debug("FontDetect: strategy 1b → \(font.fontName) \(String(format: "%.1f", font.pointSize))pt")
                    return adjustFontForZoom(font: font, element: element, caretPosition: caretPosition, text: text)
                }
            }
        }

        // Strategy 2: AXTextMarkerForIndex → AXFont (Electron — exact but unreliable)
        if let font = detectFontViaIndexMarker(element: element, caretPosition: caretPosition) {
            Log.debug("FontDetect: strategy 2 → \(font.fontName) \(String(format: "%.1f", font.pointSize))pt")
            return adjustFontForZoom(font: font, element: element, caretPosition: caretPosition, text: text)
        }

        // Strategy 3: AXBoundsForRange height (Electron — reliable, approximate)
        // No zoom adjustment — we don't have a real font name to compare width against
        var boundsRange = CFRange(location: max(0, caretPosition - 1), length: 1)
        if let rangeValue = AXValueCreate(.cfRange, &boundsRange) {
            var boundsRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                axBoundsForRange,
                rangeValue,
                &boundsRef
            ) == .success, let val = boundsRef {
                var rect = CGRect.zero
                AXValueGetValue(val as! AXValue, .cgRect, &rect)
                if rect.height > 0 {
                    let fontSize = max(rect.height - 1, 8)
                    Log.debug("FontDetect: strategy 3 → systemFont \(String(format: "%.1f", fontSize))pt (charH=\(String(format: "%.1f", rect.height)))")
                    return .systemFont(ofSize: fontSize)
                }
            }
        }

        return nil
    }

    // MARK: - Zoom Detection

    /// Adjust font size for visual zoom (e.g., WKWebView CSS zoom in Outlook).
    /// Measures multiple characters via AXBoundsForRange to amortize integer rounding
    /// error, then compares total visual width against expected width from font metrics.
    private func adjustFontForZoom(font: NSFont, element: AXUIElement, caretPosition: Int, text: String) -> NSFont {
        guard caretPosition > 0, !text.isEmpty else { return font }

        // AX base offset: text may be a truncated prefix, so string index 0
        // corresponds to AX position (caretPosition - text.count).
        let axBase = caretPosition - text.count

        // Find a span of non-whitespace characters ending near the caret (up to 10 chars,
        // staying on the current logical line, crossing word boundaries for accuracy).
        let endOffset = min(caretPosition, text.count)
        var spanEnd = text.index(text.startIndex, offsetBy: endOffset)

        // Skip trailing whitespace before caret (measuring a space char gives bad bounds)
        while spanEnd > text.startIndex {
            let prevIdx = text.index(before: spanEnd)
            if !text[prevIdx].isWhitespace { break }
            spanEnd = prevIdx
        }

        // Walk backwards from spanEnd, skipping whitespace, counting non-whitespace chars
        var spanStart = spanEnd
        var spanLen = 0
        let maxSpan = 10
        var idx = spanEnd
        while spanLen < maxSpan, idx > text.startIndex {
            let prevIdx = text.index(before: idx)
            let ch = text[prevIdx]
            if ch.isNewline { break }
            if !ch.isWhitespace {
                spanStart = prevIdx
                spanLen += 1
            }
            idx = prevIdx
        }

        guard spanLen >= 2 else { return font }

        // Use two single-character AXBoundsForRange queries to compute visual width.
        // This avoids a bug where multi-character ranges return full-line-width rects
        // in some apps (e.g., WeChat with CJK text).

        // Get the end character's bounds first (near caret — always on the current visual line)
        let lastCharLocation = axBase + text.distance(from: text.startIndex, to: text.index(before: spanEnd))
        guard let endRect = axBoundsForSingleChar(element: element, location: lastCharLocation) else {
            return font
        }

        // Get the start character's bounds, then check if it's on the same visual line.
        // If the span crosses a visual line wrap, walk forward to find the first char
        // on the same visual line as the end char.
        var currentStart = spanStart
        var startLocation = axBase + text.distance(from: text.startIndex, to: spanStart)
        var startRect: CGRect?

        while currentStart < text.index(before: spanEnd) {
            if let rect = axBoundsForSingleChar(element: element, location: startLocation) {
                // Same visual line if Y coordinates are close (within half a char height)
                if abs(rect.origin.y - endRect.origin.y) < max(rect.height, endRect.height) / 2 {
                    startRect = rect
                    break
                }
            }
            // Move forward, skipping whitespace
            currentStart = text.index(after: currentStart)
            startLocation += 1
            while currentStart < text.index(before: spanEnd), text[currentStart].isWhitespace {
                currentStart = text.index(after: currentStart)
                startLocation += 1
            }
        }

        guard let startRect = startRect else { return font }

        // Recompute the span text and expected width for the (possibly shortened) span
        let spanText = String(text[currentStart..<spanEnd])
        let nonWhitespaceCount = spanText.filter({ !$0.isWhitespace }).count
        guard nonWhitespaceCount >= 2 else { return font }

        let expectedWidth = (spanText as NSString).size(withAttributes: [.font: font]).width
        guard expectedWidth > 10 else { return font }

        // Compute visual width from X-coordinate distance (start of first char to end of last char)
        let visualWidth = endRect.origin.x + endRect.width - startRect.origin.x
        guard visualWidth > 10 else { return font }

        let ratio = visualWidth / expectedWidth
        Log.debug("ZoomDetect: span='\(spanText.prefix(20))' chars=\(nonWhitespaceCount) expectedW=\(String(format: "%.1f", expectedWidth)) visualW=\(String(format: "%.1f", visualWidth)) ratio=\(String(format: "%.2f", ratio)) (two-point)")

        // Only adjust if zoom is significant (>15%)
        guard ratio > 1.15 else { return font }

        let adjustedSize = font.pointSize * ratio
        Log.debug("ZoomDetect: zoom detected! factor=\(String(format: "%.2f", ratio)) \(String(format: "%.1f", font.pointSize))pt → \(String(format: "%.1f", adjustedSize))pt")

        if let adjustedFont = NSFont(name: font.fontName, size: adjustedSize) {
            return adjustedFont
        }
        return .systemFont(ofSize: adjustedSize)
    }

    /// Query AXBoundsForRange for a single character at the given location.
    private func axBoundsForSingleChar(element: AXUIElement, location: Int) -> CGRect? {
        var range = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axBoundsForRange,
            rangeValue,
            &boundsRef
        ) == .success, let val = boundsRef else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(val as! AXValue, .cgRect, &rect)
        return rect
    }

    private func detectFontViaIndexMarker(element: AXUIElement, caretPosition: Int) -> NSFont? {
        let startIdx = max(0, caretPosition - 1)
        var startMarkerRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axTextMarkerForIndex,
            startIdx as CFTypeRef,
            &startMarkerRef
        ) == .success, let startMarker = startMarkerRef else { return nil }

        var endMarkerRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axTextMarkerForIndex,
            caretPosition as CFTypeRef,
            &endMarkerRef
        ) == .success, let endMarker = endMarkerRef else { return nil }

        var rangeRef: AnyObject?
        let markers = [startMarker, endMarker] as CFArray
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axTextMarkerRangeForUnorderedTextMarkers,
            markers,
            &rangeRef
        ) == .success, let markerRange = rangeRef else { return nil }

        var attrRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            axAttributedStringForTextMarkerRange,
            markerRange,
            &attrRef
        ) == .success, let attrStr = attrRef as? NSAttributedString, attrStr.length > 0 else { return nil }

        let attrs = attrStr.attributes(at: 0, effectiveRange: nil)
        return fontFromAXDict(attrs)
    }

    private func fontFromAXDict(_ attrs: [NSAttributedString.Key: Any]) -> NSFont? {
        let fontAttrKey = NSAttributedString.Key(rawValue: axFontKey as String)
        guard let fontDict = attrs[fontAttrKey] as? [String: Any],
              let fontSize = fontDict[axFontSizeKey as String] as? CGFloat else { return nil }

        if let fontName = fontDict[axFontNameKey as String] as? String,
           let font = NSFont(name: fontName, size: fontSize) {
            return font
        }
        return .systemFont(ofSize: fontSize)
    }
}
