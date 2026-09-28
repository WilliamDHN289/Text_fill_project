import Foundation
import AppKit
import DPHMemory

struct Suggestion {
    let displayText: String     // Text shown in overlay
    let insertText: String      // Full text to insert on accept
    let caretRect: CGRect       // Where to position overlay
    let elementFrame: CGRect    // Text field bounds (for constraining width)
    let font: NSFont?           // Font to match
    let currentLinePrefix: String // Text on current line before caret
    let textAreaLeftEdge: CGFloat? // X coordinate where text begins (AX screen coords)
}

@MainActor
final class Engine: InputMonitorDelegate, ToolbarPanelDelegate, FocusMonitorDelegate {
    /// Maximum characters of prefix to send to the AI. Caps the token cost and
    /// context-window usage for pathological cases (Terminal scrollback,
    /// Gmail quoted-email history, long documents). Keeps the last N characters,
    /// snapping forward to a newline boundary for clean truncation.
    ///
    /// 6000 chars ≈ 1500 tokens. Covers 95%+ of real typing (email, chat, code,
    /// docs), fits comfortably in 8k local models, costs ~$0.0005/request on
    /// cloud with prompt caching. Reduces Terminal's 131k-char pathological case
    /// by ~22x.
    private static let maxPrefixChars = 6000

    /// Tighter cap for the local provider — per-token inference cost grows
    /// linearly with prompt size, so tight capping matters more for local
    /// than for cloud (where cache amortizes the cost).
    /// 1500 chars ≈ 250–400 tokens (English).
    private static let maxPrefixCharsLocal = 1500

    /// Maximum characters of suffix (text after the cursor) to send to the AI.
    /// Smaller than the prefix cap because the most valuable suffix context is
    /// the first few hundred chars (immediately after the cursor); far text is
    /// essentially irrelevant for a few tokens of completion.
    ///
    /// 2000 chars ≈ 500 tokens. Prevents Gmail quoted-email pathology (18k
    /// quoted-email chars → 2k = 9x reduction). Normal typing at the end of a
    /// field has empty suffix and is unaffected.
    private static let maxSuffixChars = 2000

    /// Speculative-prefill tuning (Q2 eager prefill). Hard minimum interval
    /// between fires (fire-rate cap vs OCR/scroll/TUI churn), and the keystroke-
    /// quiet window `startPrefill` requires — a keystroke within it means the
    /// user is typing, so let the real request path warm the cache instead.
    private static let prefillMinInterval: TimeInterval = 3.0
    private static let prefillKeystrokeQuiet: TimeInterval = 0.8

    private let contextReader: ContextReader
    private let renderer: Renderer
    private let textInserter: TextInserter
    private let cloudProvider: CloudProvider
    private let settings: SettingsManager
    private let screenContextManager: ScreenContextManager
    private let clipboardHistory: ClipboardHistory
    private let messageHistory: MessageHistory
    private let llamaProvider: LlamaProvider?

    private let debouncer: Debouncer
    private let cache = SuggestionCache()

    /// DPHM (Dual-Path Habit Memory): low-latency personal habit memory.
    /// Hot path (`suggest`) is dict-lookups-only (~µs); all learning happens
    /// on background queues. Tunables live in dphm.yaml (see DPHMConfig).
    private let habitMemory = DPHMMemory.shared

    /// Speculative-prefill trigger state (default-off `isEagerPrefillEnabled`).
    /// Separate debouncer (~0.7 s settle) so a settle-triggered prefill never
    /// fights the suggestion debounce. `warmupCompleted` gates prefills until
    /// the model-load warmup has populated the cache (so a prefill can't race or
    /// clobber the in-flight warmup); `lastPrefillFireTime` backs the fire cap.
    private let prefillDebouncer = Debouncer(interval: 0.7)
    private var lastPrefillFireTime: CFAbsoluteTime = 0
    private var warmupCompleted = false

    private var currentSuggestion: Suggestion?
    private var pendingRemainder: String?

    // MARK: - Cycle state (3-in-1 cloud alternatives)
    //
    // Cloud now returns up to 3 candidate completions per request. [0] is
    // the primary that displays normally; [1..2] are alternates the user
    // can step through with ⌥↓ / ⌥↑. State lives on Engine because cycle
    // is purely an Engine-level swap of which candidate is active —
    // no cloud RTT required. Reset whenever a new completion is fetched,
    // user types, or suggestion is dismissed.
    private var cycleCandidates: [String] = []
    private var cycleActiveIndex: Int = 0
    /// Snapshot of TextContext fields needed to re-render an alternate
    /// (caret position, font, etc.). Same values currentSuggestion uses
    /// at first display; stashed so cycle calls don't have to re-read AX.
    private var cycleDisplayContext: TextContext?

    /// B-lazy refetch state: when ⌥↓/⌥↑ fires with an empty buffer
    /// (typically right after partial accept invalidated the prior alts),
    /// we kick off a fresh cloud request via requestSuggestion(). This
    /// flag tells handleCompletionResult that the response should land
    /// directly on alt 1 (or count-1 for prev) — not on the new primary
    /// — because the user pressed cycle, not "give me a suggestion".
    private var cycleRefetchPending: CycleRefetchDirection?
    private enum CycleRefetchDirection { case next, previous }
    /// Progressive disclosure: current chunk index for the active suggestion.
    /// Reset to 0 on new suggestion / dismiss / hide-while-waiting.
    private var chunkIndex: Int = 0
    /// Cumulative typedSinceCache.count threshold required to advance chunkIndex.
    /// Set when a chunk is shown; compared against the live count on each cache-forward.
    /// 0 means "no chunk currently displayed" — type-through detection is gated by `> 0`.
    private var nextCommitPosition: Int = 0
    private var currentRequestId: String?
    private var lastDeleteTimestamp: TimeInterval = 0
    private let deleteCooldown: TimeInterval = 0.5
    private var lastKeystrokeTime: CFAbsoluteTime = 0
    private var lastAcceptTime: CFAbsoluteTime = 0
    private var lastRequestLackedScreenContext = false
    /// Tracks textLength across `requestSuggestion` calls so we can detect
    /// "user just typed the first character in a previously-empty field" —
    /// a strong signal of a fresh draft or chat switch in apps that don't
    /// update their window title (WhatsApp, iMessage, Telegram).
    private var lastObservedTextLengthForFirstChar: Int = -1
    /// Prefix length when the current suggestion was first shown.
    /// Used to decide whether delete removes "new" text (keep suggestion) or "existing" text (dismiss).
    private var suggestionPrefixLength: Int = 0

    /// Most recent successful AX read of the focused field — prefix/suffix
    /// for the message body, plus app/window identifiers for the recent-
    /// messages-history capture path. Updated by `observeReadContext()`,
    /// which wraps every readContext call in Engine. All three identifier
    /// fields are already in `TextContext`, so stashing them here is a
    /// nanosecond-level CoW string copy — no extra AX cost.
    /// TODO: add a `lastObservedAt: TimeInterval` if we ever need to reject
    /// stale snapshots (e.g., after a long pause between last keystroke and
    /// Return). Not needed for the initial use case.
    private var lastObservedPrefix: String?
    private var lastObservedSuffix: String?
    private var lastObservedAppName: String?
    private var lastObservedAppBundleId: String?
    private var lastObservedWindowTitle: String?

    /// When the last Return keystroke fired, used to suppress the
    /// transition-based capture path for ~300 ms so it doesn't fight the
    /// Return-confirmation path (which has its own labeled signal).
    private var lastReturnTime: CFAbsoluteTime = 0

    /// Last active app the user was working in (for per-app settings)
    private(set) var lastActiveAppBundleId: String?
    private(set) var lastActiveAppName: String?

    /// Consecutive cloud failures with a "provider unavailable" status
    /// (429/502/503). Reset to 0 on any cloud success. Once it reaches
    /// `cloudOutageThreshold`, we prompt the user once (per outage) to switch
    /// to the local model; `cloudOutageAlertShown` re-arms after the next
    /// cloud success.
    private var consecutiveCloudFailures = 0
    private var cloudOutageAlertShown = false
    private let cloudOutageThreshold = 10

    /// Reference to input monitor for updating suggestion visibility flag
    weak var inputMonitor: InputMonitor?
    /// Reference to focus monitor for dismissing on focus change
    weak var focusMonitor: FocusMonitor?
    /// Drives the auto reply-offer badge (idle-in-a-reply-box). Injected by AppDelegate.
    weak var replyController: ReplyController?
    /// Pending 5 s idle timer that arms the reply offer; cancelled on any keystroke,
    /// app switch, or click elsewhere.
    private var replyOfferWork: DispatchWorkItem?
    private static let replyOfferIdleSeconds: TimeInterval = 5.0
    /// WeChat-only: its offer badge anchors to the moving cursor (no fixed input box), so
    /// re-popping every few seconds is jarring. Suppress auto re-offers in WeChat for 3 min
    /// after one shows (other apps re-offer freely; the manual trigger is never gated).
    /// Monotonic uptime; nil until the first WeChat offer actually appears.
    private var lastWeChatOfferShownAt: TimeInterval?
    private static let weChatOfferCooldownSeconds: TimeInterval = 180
    /// Opens the Settings window; injected by AppDelegate (created after Engine).
    var onRequestSettings: (() -> Void)?

    init(
        contextReader: ContextReader,
        renderer: Renderer,
        textInserter: TextInserter,
        cloudProvider: CloudProvider,
        settings: SettingsManager,
        screenContextManager: ScreenContextManager,
        clipboardHistory: ClipboardHistory,
        messageHistory: MessageHistory,
        llamaProvider: LlamaProvider? = nil
    ) {
        self.contextReader = contextReader
        self.renderer = renderer
        self.textInserter = textInserter
        self.cloudProvider = cloudProvider
        self.settings = settings
        self.screenContextManager = screenContextManager
        self.clipboardHistory = clipboardHistory
        self.messageHistory = messageHistory
        self.llamaProvider = llamaProvider
        self.debouncer = Debouncer(interval: TimeInterval(settings.debounceMs) / 1000.0)
        renderer.toolbarPanel.delegate = self

        screenContextManager.onContextReady = { [weak self] in
            self?.onScreenContextReady()
        }

        // A committed sent message changes the `messages` prompt section —
        // warm it during the natural post-send pause instead of paying the
        // re-decode (messages + everything after it) on the next message's
        // first keystroke. Hooked at MessageHistory's commit point rather
        // than the Return keystroke: Return is ambiguous (newline/command/
        // send) and races the ~250ms send-confirmation, while the commit
        // fires exactly when the history changed — covering the transition-
        // capture path too. The usual gates apply: keystroke-quiet skips it
        // if the user is already typing, and a no-change history never fires
        // (record() dedups before this callback).
        messageHistory.onRecord = { [weak self] in
            self?.firePrefillIfEligible()
        }
    }

    /// Per-provider debounce interval. The OpenRouter route is pinned to a
    /// curated set of fast providers and warrants a tighter debounce than
    /// other cloud providers.
    private var currentDebounceInterval: TimeInterval {
        if settings.activeProvider == "openrouter" { return 0.15 }
        return TimeInterval(settings.debounceMs) / 1000.0
    }

    /// Cheap check: is the frontmost app disabled? Uses only NSWorkspace
    /// (no AX queries), so it returns in microseconds rather than the
    /// 200-300ms that readContext() takes on apps with large text buffers.
    ///
    /// Does NOT write lastActiveApp* — that comes exclusively from the AX
    /// context bundle id (see the write site near the suggestion handler).
    /// frontmostApplication is wrong for non-activating overlays like ChatGPT's
    /// Option+Space window, which leaves the underlying app as "frontmost"
    /// even though the user is typing into the overlay. Letting that bundle
    /// id leak into lastActiveAppBundleId caused the menu bar to flip
    /// between "Disable for ChatGPT" and "Disable for Terminal" depending on
    /// timing.
    private func isFrontmostAppDisabled() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return false }
        return settings.disabledApps.contains(bundleId)
    }

    /// Wraps `contextReader.readContext()` so every successful read updates
    /// `lastObservedPrefix` / `lastObservedSuffix`. All AX-read call sites in
    /// Engine should go through this helper rather than calling readContext
    /// directly, so freshest-wins observation is automatic.
    private func observeReadContext() -> TextContext? {
        let ctx = contextReader.readContext()
        guard let ctx else { return nil }

        // Hook: detect context transitions BEFORE updating lastObserved*.
        // Pure side-effect (records to messageHistory); doesn't influence
        // the stash logic below. lastObserved* still updates unconditionally.
        detectContextTransitionForMessageHistory(newContext: ctx)

        // Stash latest read. This is the only writer of lastObserved*.
        lastObservedPrefix = ctx.prefix
        lastObservedSuffix = ctx.suffix
        lastObservedAppName = ctx.appName
        lastObservedAppBundleId = ctx.appBundleId
        lastObservedWindowTitle = ctx.windowTitle
        return ctx
    }

    /// Compares `ctx` against `lastObserved*` (the values from the previous
    /// successful read) and, if a meaningful boundary crossed, records the
    /// previous context's prefix+suffix into `messageHistory` as a sent-
    /// message candidate. Three signals trigger capture:
    /// - app-switch: focused app's bundle id changed
    /// - window-switch: same app, different window title (e.g., switched
    ///   chat thread)
    /// - empty-field: clicked into an empty field within same app/window
    ///   (compose reset, or Outlook/Gmail-style reply where the new focus
    ///   has no prefix yet)
    /// Suppressed for 300 ms after a Return so the Return-confirmation
    /// path's labeled capture wins (avoids double-capture with a
    /// less-specific reason).
    private func detectContextTransitionForMessageHistory(newContext ctx: TextContext) {
        guard CFAbsoluteTimeGetCurrent() - lastReturnTime >= 0.3 else { return }

        let appChanged = lastObservedAppBundleId != nil &&
                         lastObservedAppBundleId != ctx.appBundleId
        let windowChanged = !appChanged &&
                            lastObservedWindowTitle != nil &&
                            !(lastObservedWindowTitle ?? "").isEmpty &&
                            !ctx.windowTitle.isEmpty &&
                            lastObservedWindowTitle != ctx.windowTitle
        let movedToEmptyField = !appChanged && !windowChanged &&
                                ctx.prefix.isEmpty &&
                                (lastObservedPrefix?.count ?? 0) > 0

        if appChanged {
            captureLastObservedAsSentMessage(reason: "app-switch")
        } else if windowChanged {
            captureLastObservedAsSentMessage(reason: "window-switch")
        } else if movedToEmptyField {
            captureLastObservedAsSentMessage(reason: "empty-field")
        }
    }

    /// Degraded equivalent of `observeReadContext()`'s transition bookkeeping
    /// for probe-fallback paths (WhatsApp-class apps, whose empty fields fail
    /// text extraction so observeReadContext() can't run). Runs the app-switch
    /// arm of `detectContextTransitionForMessageHistory` and stashes the
    /// probed field as the new lastObserved* state (empty text — the field IS
    /// empty, that's why only the probe succeeded). Without this the capture
    /// defers to the first successful read — the first keystroke — where the
    /// messages-section churn invalidates the prefill warm at the worst
    /// possible moment. Idempotent: a second probe of the same app (click +
    /// focus both fire) sees appBundleId unchanged and captures nothing.
    private func observeProbedField(_ probe: ContextReader.FocusedFieldProbe) {
        if CFAbsoluteTimeGetCurrent() - lastReturnTime >= 0.3,
           lastObservedAppBundleId != nil,
           lastObservedAppBundleId != probe.appBundleId {
            captureLastObservedAsSentMessage(reason: "app-switch")
        }
        lastObservedPrefix = ""
        lastObservedSuffix = ""
        lastObservedAppName = probe.appName
        lastObservedAppBundleId = probe.appBundleId
        lastObservedWindowTitle = probe.windowTitle
    }

    // MARK: - Screen Context Re-trigger

    /// Called when ScreenContextManager has new context that differs meaningfully
    /// from the prior value (Jaccard-filtered). When a request is in flight or a
    /// suggestion is displayed, refresh it against the latest screen state. When
    /// fully idle, treat the settle as a chance to speculatively warm the local
    /// KV cache for the field the user likely just entered (Q2 eager prefill).
    private func onScreenContextReady() {
        guard currentRequestId != nil || currentSuggestion != nil else {
            // screenRefresh: the click/focus prefill has usually already fired
            // (and set the fire-cap clock) with the screen that was CACHED at
            // click time. This post-OCR pass folds the fresh screen in off the
            // keystroke's critical path — the real request would otherwise pay
            // that screen re-decode itself. Skips the fire-cap (the OCR lands
            // ~0.5–1s after the click, inside the cap window); bursts are still
            // coalesced by the debounce, and an unchanged screen no-ops in
            // runPrefill's section match. No timer/poll recaptures exist, so
            // this only fires after a user interaction.
            firePrefillIfEligible(screenRefresh: true)
            return
        }
        Log.debug("Screen context updated, re-triggering suggestion")
        lastRequestLackedScreenContext = false
        cancelCurrentRequest()
        cache.invalidate()
        requestSuggestion()
    }

    /// Called by AppDelegate once the model-load KV-cache warmup has finished,
    /// so speculative prefills (which share the cache and the inference queue)
    /// can't race — or be clobbered by — the in-flight warmup's memory clear.
    func notifyWarmupComplete() {
        warmupCompleted = true
        Log.debug("[Prefill] warmup complete — speculative prefill armed")
    }

    /// Cheap MainActor gate for a speculative prefill. If it passes, debounce a
    /// `startPrefill` so a transient settle (app pass-through, scroll- or TUI-
    /// induced OCR delta) immediately followed by another change or a keystroke
    /// never starts a decode. Fires only when fully idle.
    /// `screenRefresh` (the onContextReady path) bypasses the fire-rate cap:
    /// the fresh OCR lands inside the cap window the click prefill started, and
    /// capping it away would leave the stale-screen warm in place — pushing the
    /// fresh-screen decode onto the first keystroke instead.
    private func firePrefillIfEligible(screenRefresh: Bool = false) {
        guard settings.isEnabled, settings.isEagerPrefillEnabled else { return }
        guard settings.activeProvider == "local", llamaProvider?.isModelLoaded == true else { return }
        // Bails below log (flag is on) — these double as A/B gate telemetry.
        guard warmupCompleted else { Log.debug("[Prefill] skip: warmup not complete"); return }
        guard currentRequestId == nil, currentSuggestion == nil else {
            Log.debug("[Prefill] skip: busy (req=\(currentRequestId != nil) sugg=\(currentSuggestion != nil))")
            return
        }
        // Hard fire-rate cap for the click/focus triggers: at most one prefill
        // per `prefillMinInterval`. Screen refreshes are exempt — they're
        // bounded instead by capture being interaction-driven (no timer/poll)
        // plus the Jaccard gate, the debounce, and the unchanged-screen no-op.
        let now = CFAbsoluteTimeGetCurrent()
        guard screenRefresh || now - lastPrefillFireTime >= Self.prefillMinInterval else { Log.debug("[Prefill] skip: fire-cap"); return }
        Log.debug("[Prefill] eligible — debouncing\(screenRefresh ? " (screen refresh)" : "")")
        prefillDebouncer.debounce { [weak self] in
            self?.startPrefill()
        }
    }

    /// Runs after the prefill debounce: re-validate liveness, do a side-effect-
    /// free AX read, apply waste/privacy guards, then fire the fire-and-forget
    /// prefill. Never touches currentRequestId / renderer / cache, so it can't
    /// be mistaken for (or coalesce away) a real request.
    private func startPrefill() {
        guard settings.isEnabled,
              settings.isEagerPrefillEnabled,
              settings.activeProvider == "local",
              llamaProvider?.isModelLoaded == true,
              warmupCompleted,
              currentRequestId == nil, currentSuggestion == nil else { Log.debug("[Prefill] start skip: re-check failed"); return }
        let now = CFAbsoluteTimeGetCurrent()
        // A keystroke during the debounce means the user is typing — the real
        // request path will warm the cache; don't risk head-of-line blocking it.
        guard now - lastKeystrokeTime >= Self.prefillKeystrokeQuiet else { Log.debug("[Prefill] start skip: keystroke too recent"); return }
        // Side-effect-free read: NOT observeReadContext(), whose message-history
        // transition capture could record a spurious sent message and poison the
        // `messages` section the prefill then warms.
        let context: TextContext
        if let full = contextReader.readContext() {
            context = full
        } else if let probe = contextReader.probeFocusedField() {
            // WhatsApp/iMessage-class apps fail text extraction outright on
            // EMPTY fields while role/title/frame reads succeed. The warm
            // covers bos…suffixContext — never the typed prefix — and an empty
            // field has no suffix, so field text isn't needed; app identity +
            // window title (the appHeader) are. Worst case the field actually
            // held unreadable text: the suffixContext tail mismatches and the
            // real request re-decodes it — under-warm, never wrong.
            context = TextContext(
                textLength: 0,
                caretPosition: 0,
                prefix: "",
                suffix: "",
                caretScreenRect: .zero,
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
            Log.debug("[Prefill] probe fallback (empty-field assumption) app=\(probe.appBundleId)")
        } else {
            Log.debug("[Prefill] start skip: readContext nil")
            return
        }
        // Still the app the settle fired for? Kills prefills for apps the user
        // merely tabbed through (the focus/OCR landed after they moved on).
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == context.appBundleId else { Log.debug("[Prefill] start skip: not frontmost (ctx=\(context.appBundleId))"); return }
        // Never warm a password field (privacy + an unacceptable suggestion) or
        // a disabled app. (Claude Code TUIs were previously skipped here for
        // scrollback churn; now allowed — prefill reuse is measured via the
        // `prewarmed=` telemetry on the following request. Observe-first; no gate.)
        guard !context.isPasswordField else { Log.debug("[Prefill] start skip: password field"); return }
        guard !settings.disabledApps.contains(context.appBundleId) else { Log.debug("[Prefill] start skip: disabled app \(context.appBundleId)"); return }
        // Warm a position the user is about to type into: either a normally-
        // suggestible spot OR the end of a field — including an EMPTY chat box,
        // a prime target that shouldSuggest alone rejects (no text yet). Still
        // bails on mid-text reads, read-only views, and non-text/navigation
        // clicks (caret not at end), so it isn't "click anywhere → speculate".
        guard context.shouldSuggest || context.isAtEndOfText else { Log.debug("[Prefill] start skip: not a typing position"); return }

        let sections = buildPromptSections(from: context)
        // Mirror captureIfNeeded's app-change invalidation without its side
        // effects: across an app switch the cached screen text belongs to the
        // PREVIOUS app — a real request's first captureIfNeeded would
        // invalidate it, so warming it decodes a screen section no future
        // request can ever match (pure waste + queue occupancy). Same-app
        // conversation switches keep the cached text: that IS what an
        // immediate request would use.
        let screenContext = screenContextManager.currentAppBundleId == context.appBundleId
            ? screenContextManager.currentContext : nil
        let appName = context.appName
        let windowTitle = context.windowTitle
        let midDecodeCancelEnabled = settings.isMidDecodeCancelEnabled
        lastPrefillFireTime = now
        let isClaudeCode = ClaudeCodeAdapter.matches(windowTitle: windowTitle, appName: appName)
        Log.debug("[Prefill] firing app=\(appName) claudecode=\(isClaudeCode) prefixLen=\(sections.trimmedPrefix.count) priorCtxLen=\(sections.priorContext?.count ?? 0)")
        Task { [weak self] in
            await self?.llamaProvider?.prefill(
                prefix: sections.trimmedPrefix,
                suffix: sections.trimmedSuffix.isEmpty ? nil : sections.trimmedSuffix,
                suffixKind: sections.suffixKind,
                userContext: sections.userContext,
                screenContext: screenContext,
                scrollback: sections.priorContext,
                clipboardItems: sections.clipboardItems.isEmpty ? nil : sections.clipboardItems,
                recentMessages: sections.recentMessages.isEmpty ? nil : sections.recentMessages,
                appName: appName,
                windowTitle: windowTitle,
                midDecodeCancelEnabled: midDecodeCancelEnabled
            )
        }
    }

    // MARK: - InputMonitorDelegate

    nonisolated func inputMonitor(_ monitor: InputMonitor, didReceiveKeystroke event: KeystrokeEvent) {
        Task { @MainActor in
            handleKeystroke(event)
        }
    }

    nonisolated func inputMonitorDidDetectClick(_ monitor: InputMonitor) {
        Task { @MainActor in
            // Ignore clicks on the toolbar panel — let the button handle it
            let mouseLocation = NSEvent.mouseLocation
            if renderer.toolbarPanel.containsPoint(mouseLocation) {
                return
            }
            // A click anywhere but the badge tears down a stale offer; an empty
            // allowlisted field below re-arms the idle timer.
            cancelReplyOffer()

            // Single AX read shared across the three checks below — each
            // observeReadContext() costs 50–300 ms on apps with large buffers.
            let context = observeReadContext()

            // Ensure AX observer is registered for this app early
            if let context {
                focusMonitor?.updateObservedApp(pid: context.appPid)
            }
            // Detect conversation switch: clicked into an empty text field
            let firedOnClick: Bool
            if let context, context.textLength == 0 {
                screenContextManager.onClickDetected(
                    pid: context.appPid,
                    appBundleId: context.appBundleId,
                    inputBandFrame: context.inputBandFrame,
                    windowTitle: context.windowTitle
                )
                firedOnClick = true
            } else if context == nil, let probe = contextReader.probeFocusedField() {
                // WhatsApp/iMessage-class apps fail text extraction outright on
                // EMPTY fields (readContext nil — steady-state, not a settle
                // delay), so the textLength == 0 branch above can never see
                // them. A successful probe (focused text role with readable
                // metadata) right after a failed read IS the empty-field
                // signal for these apps.
                observeProbedField(probe)
                focusMonitor?.updateObservedApp(pid: probe.appPid)
                Log.debug("[ScreenContext] Click probe fallback (empty-field assumption) app=\(probe.appBundleId)")
                screenContextManager.onClickDetected(
                    pid: probe.appPid,
                    appBundleId: probe.appBundleId,
                    inputBandFrame: probe.inputBandFrame,
                    windowTitle: probe.windowTitle
                )
                firedOnClick = true
                armReplyOffer(appBundleId: probe.appBundleId, windowTitle: probe.windowTitle, appName: probe.appName)
            } else if context == nil, fireWeChatCaptureIfFrontmost() {
                firedOnClick = true
                // WeChat is AX-blind: no field text/role to inspect, but a frontmost
                // capture confirms it. Allowlisted by bundle id; showOffer re-checks geometry.
                armReplyOffer(appBundleId: "com.tencent.xinWeChat", windowTitle: "", appName: "WeChat")
            } else {
                firedOnClick = false
            }
            // Arm the reply offer for any focused field in an allowlisted app. showOffer
            // does the authoritative empty-draft check, so this also covers Gmail/Outlook
            // replies where the field is pre-filled with the quote (textLength > 0). The
            // probe / WeChat branches above arm the context == nil (AX-blind) apps.
            if let context {
                armReplyOffer(appBundleId: context.appBundleId, windowTitle: context.windowTitle, appName: context.appName)
            }

            // Catalyst / WKWebView apps (WhatsApp, iMessage, Telegram) often
            // return nil or stale AX state at click time — the input field
            // stays the same focused element across chat switches, so neither
            // app-changed nor focus-changed signals fire. Retry once after 1s
            // to catch the chat-switch-in-same-window case.
            if !firedOnClick {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let retry = self.observeReadContext()
                    if let retry, retry.textLength == 0 {
                        Log.debug("[ScreenContext] Click retry — AX settled, recapturing")
                        self.screenContextManager.onClickDetected(
                            pid: retry.appPid,
                            appBundleId: retry.appBundleId,
                            inputBandFrame: retry.inputBandFrame,
                            windowTitle: retry.windowTitle
                        )
                    } else if retry == nil {
                        // WeChat (AX-blind) yields no context here. The first click into
                        // WeChat from another app often fails the WeChat branch above
                        // because the window isn't capturable yet at app-activation time
                        // (frontmost not flipped, or no on-screen layer-0 window resolved).
                        // Re-attempt after the 1s settle so a single click suffices.
                        _ = self.fireWeChatCaptureIfFrontmost()
                    }
                }
            }

            if renderer.isSuggestionVisible {
                dismissVisual()
            }
            // Try cache instantly; on cache miss, only pre-fire a request when
            // the caret has no preceding text (fresh draft — e.g. new note or
            // an empty Gmail reply with quoted history below). For non-empty
            // prefixes, the next keystroke fires its own request; pre-firing
            // on plain navigation clicks just wastes API calls.
            if !tryShowCachedSuggestion() {
                if let context,
                   context.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    debouncer.debounce(interval: currentDebounceInterval) { [weak self] in
                        self?.requestSuggestion()
                    }
                }
            }
            // OCR-independent prefill trigger: a click into a field is a focus
            // signal that doesn't depend on the screen-OCR pipeline (which bails
            // on some windows, e.g. Notes). Self-gates on idle/eligible, so an
            // empty-field pre-fire above (which makes us non-idle) suppresses it.
            firePrefillIfEligible()
        }
    }

    /// WeChat SPIKE (com.tencent.xinWeChat ONLY) — WeChat exposes no AX content
    /// (focused-app + focused-element both nil), so the context/probe click branches
    /// never fire. If WeChat is frontmost AND its window is capturable, synthesize an
    /// input band at the window bottom and reuse the OCR pipeline to dump the chat
    /// history above it; returns true if it fired. Capture the FULL window width
    /// (sidebar + chat) so the OCR x-filter (ScreenContextManager.weChatChatColumnOnly)
    /// can drop the left conversation-list column using each line's bbox — resize-robust,
    /// unlike a fixed pixel offset. The bottom input strip is excluded vertically by
    /// `cropAboveInput` ([windowTop, band.y]). Strictly gated to WeChat's bundle id, so
    /// existing behavior for other apps is unchanged. Diagnostic; remove after we
    /// evaluate OCR quality.
    private func fireWeChatCaptureIfFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.tencent.xinWeChat",
              let wf = WindowCapturer.windowBounds(forPid: front.processIdentifier) else {
            return false
        }
        // Bottom strip to exclude (input box + toolbar). WeChat is AX-blind, so we
        // can't read the real input geometry — this is a fixed guess. Measured from a
        // shortest-state composer: input-box top sits ~95pt above the window bottom, so
        // 95 chops exactly the empty composer while keeping the last message. Bias low:
        // too-high eats chat history (worse), too-low only includes the empty box.
        let inputPts: CGFloat = 95
        let band = CGRect(x: wf.origin.x,
                          y: wf.origin.y + wf.height - inputPts,
                          width: wf.width,
                          height: inputPts)
        Log.debug("[WeChatSpike] capture pid=\(front.processIdentifier) win=\(wf) band=\(band)")
        screenContextManager.onClickDetected(
            pid: front.processIdentifier,
            appBundleId: "com.tencent.xinWeChat",
            inputBandFrame: band,
            windowTitle: ""
        )
        return true
    }

    nonisolated func inputMonitorDidDetectScroll(_ monitor: InputMonitor) {
        Task { @MainActor in
            dismissVisual()
        }
    }

    /// Mouse-up runs after a potential drag-selection completes. The mouse-down
    /// path already dismissed and re-shows from cache, but at click-time the
    /// selection is still empty. By mouse-up the selection is final, so we
    /// re-check and dismiss if the user ended up with a non-empty selection.
    nonisolated func inputMonitorDidDetectMouseUp(_ monitor: InputMonitor) {
        Task { @MainActor in
            guard renderer.isSuggestionVisible else { return }
            if contextReader.hasNonEmptySelection() {
                Log.debug("dismissVisual: drag-selection detected on mouseUp")
                dismissVisual()
            }
        }
    }

    // MARK: - Keystroke Handling

    private func handleKeystroke(_ event: KeystrokeEvent) {
        Log.debug("Keystroke: keyCode=\(event.keyCode) chars='\(event.characters)' isChar=\(event.isCharacterKeystroke) enabled=\(settings.isEnabled)")
        // The user is typing — tear down any un-clicked reply offer (and its pending
        // timer). Independent of the autocomplete-enabled guard below.
        cancelReplyOffer()
        guard settings.isEnabled else { Log.debug("Skipped: disabled"); return }
        // Note: under session-wide secure input, this method is never reached
        // (CGEventTap doesn't fire). Detection happens at render time via
        // SecureInputNotifier — see check sites below.

        // Handle suggestion control keys first
        if renderer.isSuggestionVisible, let suggestion = currentSuggestion {
            if event.isTab && event.hasNoModifiers {
                acceptWord(suggestion)
                return
            }
            if event.isBacktick && event.hasNoModifiers {
                acceptFull(suggestion)
                return
            }
            if event.isEscape {
                dismiss()
                return
            }
            // ⌘↓ / ⌘↑ — cycle through 3-in-1 cloud alternates. Right-Command
            // only so left-Command shortcuts (Cmd+↑/↓ = document start/end)
            // keep working in the host app.
            if event.isRightCommandDown {
                cycleNext()
                return
            }
            if event.isRightCommandUp {
                cyclePrevious()
                return
            }
        }

        // Caret movement: hide visible ghost text, otherwise try cache re-show.
        // Never fire a fresh inference from navigation — that's an authoring
        // signal, not a navigation one. Cache exact-match is position-safe, so
        // even Right Arrow can re-show: it can only hit when prefix matches a
        // previously generated entry (i.e., user navigated back to where the
        // suggestion was). Right Arrow is pure navigation now — it dismisses
        // visible ghost text and never accepts (Tab accepts word-by-word).
        if event.isCaretMovement || event.isEmacsNavigation {
            if renderer.isSuggestionVisible {
                dismissVisual()
            } else {
                tryShowCachedSuggestion()
            }
            return
        }

        // Cmd+A (Select All) or Ctrl+K (kill line) — suggestion is invalid
        if event.isSelectAll || event.isEmacsKillLine {
            if renderer.isSuggestionVisible {
                dismiss()
            }
            return
        }

        // Cmd+V (paste) or Cmd+X (cut) — text is mutated in ways we can't track,
        // and the caret moves to a new position after paste. Hard dismiss.
        if event.isPaste || event.isCut {
            if renderer.isSuggestionVisible {
                dismiss()
            } else {
                cancelCurrentRequest()
                debouncer.cancel()
            }
            return
        }

        // Forward delete (Fn+Delete or Ctrl+D) — same logic as backspace
        if event.isForwardDelete || event.isEmacsForwardDelete {
            if settings.activeProvider == "local", let llama = llamaProvider, llama.isModelLoaded {
                cancelCurrentRequest()
                if renderer.isSuggestionVisible {
                    renderer.hideSuggestion()
                    updateSuggestionVisibility(false)
                }
                lastKeystrokeTime = CFAbsoluteTimeGetCurrent()
                requestSuggestion()
            } else {
                dismiss()
                lastKeystrokeTime = CFAbsoluteTimeGetCurrent()
                debouncer.debounce(interval: currentDebounceInterval) { [weak self] in
                    self?.requestSuggestion()
                }
            }
            return
        }

        // Handle deletion. Defer the body 50 ms so the focused app has time
        // to commit the delete into its text storage — same race we fight for
        // character keystrokes (kCGSessionEventTap fires upstream of the
        // focused app, so an immediate AX read returns pre-delete state).
        // Without the defer, processDeleteKeystroke's reposition check would
        // see prefix.count one above the post-delete value and mis-decide to
        // keep stale ghost text.
        if event.isDelete {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.processDeleteKeystroke(event)
            }
            return
        }

        // Return: capture a sent-message candidate (confirmed by 250 ms field-
        // clear / app-switch check), notify screen context, then hard-dismiss
        // any visible ghost text. Capture happens before dismiss so we can
        // grab `lastObserved*` while it's still fresh from the most recent
        // keystroke — same data the user just submitted.
        if event.isReturn {
            captureSentMessageCandidate()
            screenContextManager.onReturnPressed()
            if renderer.isSuggestionVisible {
                dismiss()
            } else {
                cancelCurrentRequest()
                debouncer.cancel()
            }
            return
        }

        // Skip non-character keystrokes (but allow Space to trigger suggestions)
        if !event.isCharacterKeystroke && !event.isSpace {
            return
        }

        // Defer the rest of the character-keystroke pipeline (cache lookup,
        // context read, request firing) by 30 ms.
        //
        // Why: kCGSessionEventTap fires upstream of the focused app's
        // responder chain. Even after our InputMonitor's
        // DispatchQueue.main.async dispatch, our handler can still run
        // before the foreground app has dequeued the event from its main
        // loop, run keyDown:/insertText:, and committed the character into
        // NSTextStorage. AX reads at that point return text that's one
        // character behind ("user types lo, AX reports l" — observed
        // repeatedly across native + WebKit + Electron apps).
        //
        // 30 ms covers native Cocoa apps (~5–15 ms commit latency) with
        // headroom and partially covers WebKit/Electron apps (which can
        // need 30–80 ms; not perfect but strict improvement). Tradeoff is
        // a fixed ~30 ms latency added to every character keystroke; for
        // local-model autocomplete with ~700 ms AI round-trip this is a
        // ~4% increase, imperceptible to the user. Control keys (Tab/Esc/
        // backtick/Right Arrow/Cmd-V/Delete) handled above are NOT delayed.
        //
        // See research notes 2026-04-26 for Pattern F (CGEventTap synthesis +
        // AXObserver) which would eliminate the 30 ms entirely. Deferred until
        // we observe how much this simple delay buys us.
        // Empirical: 30 ms wasn't enough on Chromium hosts (Slack, Chrome,
        // LinkedIn web) — user reproduced "1 char behind" repeatedly.
        // 500 ms was always enough (used as oracle to confirm root cause
        // is commit-timing race, not AX caching). 50 ms is the smallest
        // value that holds up across the apps tested while staying
        // imperceptible per keystroke.
        // A real character/space keystroke means the user is typing — abort any
        // pending speculative prefill so it can't head-of-line block this
        // keystroke's request on the shared inference queue.
        prefillDebouncer.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.processCharacterKeystroke(event)
        }
    }

    /// Body of `handleKeystroke` for the character-keystroke case, invoked
    /// after a 30 ms defer so the focused app has time to commit the
    /// character into its text storage before we read AX. Split out solely
    /// so `handleKeystroke` can defer this block as a single unit; logic is
    /// unchanged from the pre-defer version.
    private func processCharacterKeystroke(_ event: KeystrokeEvent) {
        // Cancel any in-flight request.
        // For local provider, let inflight finish and serve the new state via post-flight
        // roll or refetch (see handleCompletionResult). Cancelling mid-decode is both wasteful
        // (every keystroke kills hundreds of tokens of prompt processing) and risky for the
        // KV cache consistency on SWA models.
        let isLocalProvider = (settings.activeProvider == "local" && llamaProvider?.isModelLoaded == true)
        if !isLocalProvider {
            cancelCurrentRequest()
        }

        // Early bailout for disabled apps — avoids the expensive readContext()
        // which can take 200-300ms on apps with large text buffers (e.g. Terminal scrollback).
        if isFrontmostAppDisabled() {
            if renderer.isSuggestionVisible { dismissVisual() }
            debouncer.debounce(interval: currentDebounceInterval) { [weak self] in
                self?.requestSuggestion()
            }
            return
        }

        // Read context once and reuse across the cache-forward / space-reposition
        // / fire paths. Without this, a cache-miss keystroke would readContext()
        // twice (once here for cache-forward, once inside requestSuggestion) —
        // each call costs 50–300 ms of MainActor blocking.
        let context = observeReadContext()

        // Detect "user just typed the first character into a previously-empty
        // field" — bypasses captureIfNeeded's app-/title-change gate so we
        // catch sidebar chat-switch in apps where the window title is constant
        // (WhatsApp, iMessage, Telegram). Must live here (per-keystroke) rather
        // than in requestSuggestion, which is debounced — by the time it runs
        // textLength has already advanced past 1 for fast typists. Jaccard on
        // the resulting OCR decides whether to actually re-fire a suggestion.
        if let context, event.isCharacterKeystroke,
           !settings.disabledApps.contains(context.appBundleId) {
            let prev = lastObservedTextLengthForFirstChar
            lastObservedTextLengthForFirstChar = context.textLength
            if context.textLength == 1 && prev != 1 {
                Log.debug("[ScreenContext] Fresh typing (textLength: \(prev)→1)")
                screenContextManager.onFirstCharTyped(
                    pid: context.appPid,
                    appBundleId: context.appBundleId,
                    inputBandFrame: context.inputBandFrame,
                    windowTitle: context.windowTitle
                )
            }
        }

        // DPHM word-boundary event: a space completed a word — feed the
        // fast-decay session cache (inline, µs) and poke the speculative
        // prefetcher (debounced, async). Never blocks the keystroke.
        if event.isSpace, let context, !context.isPasswordField {
            habitMemory.onWordBoundary(bufferText: context.prefix)
        }

        // Try cache forwarding (skip for password fields)
        if let context, !context.isPasswordField,
           let cacheHit = cache.tryAdvance(newPrefix: context.prefix, appBundleId: context.appBundleId) {
            // Secure input may have activated since the last keystroke (e.g.,
            // user just clicked into a 1Password popover). Suppress the cached
            // ghost text so we don't show something Tab can't accept.
            if SecureInputNotifier.shared.checkAndNotify(caretRect: context.caretScreenRect, elementFrame: context.elementFrame) {
                Log.debug("Skipped: secure input (cache forward)")
                return
            }
            let (chunk, remainder) = chunkForCacheForward(
                remainingSuggestion: cacheHit.remainingSuggestion,
                typedSinceCacheCount: cacheHit.typedSinceCacheCount
            )
            pendingRemainder = remainder.isEmpty ? nil : remainder
            let suggestion = Suggestion(
                displayText: chunk,
                insertText: chunk,
                caretRect: context.caretScreenRect,
                elementFrame: context.elementFrame,
                font: context.font,
                currentLinePrefix: context.currentLinePrefix,
                textAreaLeftEdge: context.textAreaLeftEdge
            )
            currentSuggestion = suggestion
            renderer.showSuggestion(suggestion.displayText, at: suggestion.caretRect, elementFrame: suggestion.elementFrame, font: suggestion.font, currentLinePrefix: suggestion.currentLinePrefix, textAreaLeftEdge: suggestion.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
            updateSuggestionVisibility(true)
            // Type-through is a silent partial-accept: the user advanced past
            // the original cycleDisplayContext (prefix + caret), so any cached
            // cycle entries / display snapshot are now stale. Clearing here
            // routes the next ⌥↓ through the same fresh-refetch path that
            // explicit partial-accepts use, with `cycleDisplayContext` re-set
            // from the fresh request context. Without this, ⌥↓ would render
            // ghost text at the old caret position and trimOverlap/ensureSeparator
            // would run against a stale prefix.
            resetCycleState()
            return
        }

        // Space while suggestion visible: keep suggestion, reposition at new caret
        if event.isSpace, renderer.isSuggestionVisible,
           let suggestion = currentSuggestion,
           let context {
            let repositioned = Suggestion(
                displayText: suggestion.displayText,
                insertText: suggestion.insertText,
                caretRect: context.caretScreenRect,
                elementFrame: context.elementFrame,
                font: context.font,
                currentLinePrefix: context.currentLinePrefix,
                textAreaLeftEdge: context.textAreaLeftEdge
            )
            currentSuggestion = repositioned
            renderer.showSuggestion(repositioned.displayText, at: repositioned.caretRect, elementFrame: repositioned.elementFrame, font: repositioned.font, currentLinePrefix: repositioned.currentLinePrefix, textAreaLeftEdge: repositioned.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
            // Same staleness as cache-forward: caret advanced, cycle snapshot stale.
            resetCycleState()
            return
        }

        // Dismiss current suggestion while waiting for new one.
        // Resets progressive state so a stale chunkIndex/nextCommitPosition doesn't
        // affect the next display.
        if renderer.isSuggestionVisible {
            renderer.hideSuggestion()
            updateSuggestionVisibility(false)
            resetProgressiveState()
        }

        lastKeystrokeTime = CFAbsoluteTimeGetCurrent()

        // DPHM instant habit ghost text (hot path): bridge the LLM round-trip
        // (debounce + inference, hundreds of ms) with a personal-habit
        // suggestion when one clears the score bar. Dict lookups only (~µs) —
        // no embedding, no ANN, no LLM. Replaced by the real completion when
        // handleCompletionResult lands; Tab-accept works immediately because
        // currentSuggestion is set through the same mechanics as any other
        // suggestion. Gated in dphm.yaml (hot_path.display_enabled).
        if habitMemory.config.enabled, habitMemory.config.hotPathDisplayEnabled,
           let context, !context.isPasswordField, context.shouldSuggest,
           !settings.disabledApps.contains(context.appBundleId),
           let habit = habitMemory.suggest(bufferText: context.prefix) {
            let text = PostProcessor.ensureSeparator(suggestion: habit.text, prefix: context.prefix)
            if PostProcessor.isWorthShowing(text),
               !SecureInputNotifier.shared.checkAndNotify(caretRect: context.caretScreenRect, elementFrame: context.elementFrame) {
                let suggestion = Suggestion(
                    displayText: text,
                    insertText: text,
                    caretRect: context.caretScreenRect,
                    elementFrame: context.elementFrame,
                    font: context.font,
                    currentLinePrefix: context.currentLinePrefix,
                    textAreaLeftEdge: context.textAreaLeftEdge
                )
                currentSuggestion = suggestion
                pendingRemainder = nil
                resetProgressiveState()
                resetCycleState()
                renderer.showSuggestion(suggestion.displayText, at: suggestion.caretRect, elementFrame: suggestion.elementFrame, font: suggestion.font, currentLinePrefix: suggestion.currentLinePrefix, textAreaLeftEdge: suggestion.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
                inputMonitor?.setSuggestionVisible(true)
                // Set directly from the already-read context — no second AX read.
                suggestionPrefixLength = context.prefix.count
                let e2eMs = (CFAbsoluteTimeGetCurrent() - lastKeystrokeTime) * 1000
                Log.debug("[DPHM] instant habit ghost (\(habit.source), score=\(String(format: "%.2f", habit.score)), \(String(format: "%.2f", e2eMs))ms): '\(text.prefix(40))'")
            }
        }

        if isLocalProvider {
            // Coalesce: if a local inference is already in flight, skip firing a new one.
            // When it returns, handleCompletionResult's post-flight roll will serve the
            // current state (or refetch for the current state if the user diverged).
            if currentRequestId != nil {
                Log.debug("Local inflight running — coalescing, post-flight roll will serve")
                return
            }
            // Native inference: no debounce — fire immediately.
            requestSuggestion(passedContext: context)
        } else {
            // Cloud/Ollama: debounce to avoid excessive API calls
            debouncer.debounce(interval: currentDebounceInterval) { [weak self] in
                self?.requestSuggestion(passedContext: context)
            }
        }
    }

    /// Body of `handleKeystroke` for the delete-keystroke case, invoked after
    /// a 50 ms defer so the focused app has time to commit the delete into
    /// its text storage before we read AX. Reads context once at the top and
    /// passes it through to `requestSuggestion` to avoid the duplicate read
    /// that the pre-defer version did on the cache-miss path.
    private func processDeleteKeystroke(_ event: KeystrokeEvent) {
        let context = observeReadContext()

        // Delete while suggestion visible: keep if only deleting text added
        // after the suggestion was shown.
        if renderer.isSuggestionVisible,
           let suggestion = currentSuggestion,
           let context,
           context.prefix.count >= suggestionPrefixLength {
            let repositioned = Suggestion(
                displayText: suggestion.displayText,
                insertText: suggestion.insertText,
                caretRect: context.caretScreenRect,
                elementFrame: context.elementFrame,
                font: context.font,
                currentLinePrefix: context.currentLinePrefix,
                textAreaLeftEdge: context.textAreaLeftEdge
            )
            currentSuggestion = repositioned
            renderer.showSuggestion(repositioned.displayText, at: repositioned.caretRect, elementFrame: repositioned.elementFrame, font: repositioned.font, currentLinePrefix: repositioned.currentLinePrefix, textAreaLeftEdge: repositioned.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
            return
        }
        if settings.activeProvider == "local", let llama = llamaProvider, llama.isModelLoaded {
            // Local provider: deletion is cheap, request new suggestion immediately
            cancelCurrentRequest()
            if renderer.isSuggestionVisible {
                renderer.hideSuggestion()
                updateSuggestionVisibility(false)
            }
            lastKeystrokeTime = CFAbsoluteTimeGetCurrent()
            requestSuggestion(passedContext: context)
        } else {
            // Cloud provider: dismiss and debounce a new request
            dismiss()
            lastKeystrokeTime = CFAbsoluteTimeGetCurrent()
            debouncer.debounce(interval: currentDebounceInterval) { [weak self] in
                self?.requestSuggestion(passedContext: context)
            }
        }
    }

    // MARK: - Cache Shortcut

    /// Instantly check cache for an exact match and show it. Returns `true` on hit.
    @discardableResult
    private func tryShowCachedSuggestion() -> Bool {
        guard !isFrontmostAppDisabled(),
              let context = observeReadContext(),
              !context.isPasswordField,
              let cacheHit = cache.tryExactMatch(prefix: context.prefix, appBundleId: context.appBundleId) else {
            return false
        }
        // Secure input check: the click that triggered this may have landed in
        // an app holding secure input (Terminal, 1Password). If so, suppress
        // the cached ghost text and surface the hint instead of pretending Tab
        // will work.
        if SecureInputNotifier.shared.checkAndNotify(caretRect: context.caretScreenRect, elementFrame: context.elementFrame) {
            Log.debug("Skipped: secure input (instant cache)")
            return false
        }
        // Progressive disclosure: exact-match re-show after dismissal → fresh start at chunk 0.
        resetProgressiveState()
        let (chunk, remainder) = PostProcessor.progressiveChunk(of: cacheHit.remainingSuggestion, chunkIndex: chunkIndex, style: settings.chunkingStyle)
        pendingRemainder = remainder.isEmpty ? nil : remainder
        nextCommitPosition = chunk.count
        Log.debug("[Progressive] exact-match re-show: chunkIdx=\(chunkIndex) chunk='\(chunk)' nextPos=\(nextCommitPosition)")
        let suggestion = Suggestion(
            displayText: chunk,
            insertText: chunk,
            caretRect: context.caretScreenRect,
            elementFrame: context.elementFrame,
            font: context.font,
            currentLinePrefix: context.currentLinePrefix,
            textAreaLeftEdge: context.textAreaLeftEdge
        )
        currentSuggestion = suggestion
        renderer.showSuggestion(suggestion.displayText, at: suggestion.caretRect, elementFrame: suggestion.elementFrame, font: suggestion.font, currentLinePrefix: suggestion.currentLinePrefix, textAreaLeftEdge: suggestion.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
        updateSuggestionVisibility(true)
        Log.debug("Cache exact match (instant): re-showing suggestion")
        return true
    }

    // MARK: - Suggestion Request

    /// The per-request prompt sections, shared by the real request path
    /// (`requestSuggestion`) and the speculative prefill trigger (`startPrefill`).
    private struct PromptSections {
        let trimmedPrefix: String
        let trimmedSuffix: String
        let suffixKind: SuffixKind
        let priorContext: String?
        let userContext: String?
        let clipboardItems: [String]
        let recentMessages: [String]
    }

    /// Build the per-request prompt sections from a read context: route the raw
    /// prefix/suffix through the per-app adapters (Claude Code scrollback split,
    /// mail-reply quote segmentation), apply provider-aware caps, normalize the
    /// user context, and snapshot the clipboard/message histories. Centralized so
    /// a speculative prefill tokenizes byte-identically to the real request it
    /// precedes — any divergence here would make the warm a guaranteed cache miss.
    private func buildPromptSections(from context: TextContext) -> PromptSections {
        // Cap prefix and suffix to prevent pathological cases (Terminal scrollback,
        // Gmail quoted-email history, long documents) from blowing up token cost
        // and context window. Prefix keeps the tail; suffix keeps the head.
        // Tighter cap when EITHER:
        //   - the provider is local (per-token inference cost is high), OR
        //   - the user is in a Claude Code window (TUI redraw fills the prefix
        //     with low-signal noise — borders, status lines, repeated prompts —
        //     that wastes cloud tokens without improving suggestions).
        // Route through per-app adapters: Claude Code (scrollback split) and
        // mail replies (suffix quote segmentation) today; future apps (vim,
        // Slack threads) plug in here as siblings without widening this function.
        let priorContext: String?
        let trimmedPrefix: String
        let trimmedSuffix: String
        let suffixKind: SuffixKind
        if ClaudeCodeAdapter.matches(windowTitle: context.windowTitle, appName: context.appName) {
            let r = ClaudeCodeAdapter.preprocess(
                rawPrefix: context.prefix,
                provider: settings.activeProvider,
                localCap: Self.maxPrefixCharsLocal
            )
            priorContext = r.priorContext
            trimmedPrefix = r.trimmedPrefix
            trimmedSuffix = r.trimmedSuffix
            suffixKind = .plain
        } else if MailReplyAdapter.matches(appBundleId: context.appBundleId, windowTitle: context.windowTitle, appName: context.appName) {
            let prefixCap = settings.activeProvider == "local"
                ? Self.maxPrefixCharsLocal
                : Self.maxPrefixChars
            trimmedPrefix = trimPrefix(context.prefix, maxChars: prefixCap)
            trimmedSuffix = trimSuffix(context.suffix, maxChars: Self.maxSuffixChars)
            // nil preprocess (no attribution parsed) → .plain: an unparsed non-empty
            // suffix is indistinguishable from the user's own draft text below the
            // caret, and email framing would mislabel it. Empty suffix renders no
            // section either way.
            suffixKind = MailReplyAdapter.preprocess(rawSuffix: trimmedSuffix)
                .map { .mailReply(quote: $0) } ?? .plain
            priorContext = nil
        } else {
            let prefixCap = settings.activeProvider == "local"
                ? Self.maxPrefixCharsLocal
                : Self.maxPrefixChars
            trimmedPrefix = trimPrefix(context.prefix, maxChars: prefixCap)
            trimmedSuffix = trimSuffix(context.suffix, maxChars: Self.maxSuffixChars)
            suffixKind = .plain
            priorContext = nil
        }

        // Per-line normalize (trim each line, drop empty lines, collapse
        // internal multi-space). Catches paste artifacts like trailing
        // whitespace runs on identifier lines and consecutive blank lines
        // that would otherwise eat prompt budget. Reads `settings.userContext`
        // fresh each request — Settings edits propagate to the next request
        // automatically without any cache invalidation.
        let normalizedUC = TextNormalize.collapsePerLine(settings.userContext)
        let userContext: String? = normalizedUC.isEmpty ? nil : normalizedUC
        let clipboardItems = clipboardHistory.snapshot()
        let recentMessages = messageHistory.snapshot().map { $0.text }

        return PromptSections(
            trimmedPrefix: trimmedPrefix,
            trimmedSuffix: trimmedSuffix,
            suffixKind: suffixKind,
            priorContext: priorContext,
            userContext: userContext,
            clipboardItems: clipboardItems,
            recentMessages: recentMessages
        )
    }

    /// `wantsAlternates: true` switches the cloud request into 3-in-1 cycle
    /// mode (returns 3 intent-divergent candidates). Default false produces
    /// a single focused primary completion. Set true by triggerCycleRefetch
    /// when the user presses ⌥↓/⌥↑ and the cycle buffer needs alternates.
    /// When a cycle refetch is requested but a gate bails out (delete cooldown,
    /// password field, etc.), `cycleRefetchPending` is auto-cleared on exit
    /// so the next ⌥↓ isn't blocked by a stale "in flight" check.
    private func requestSuggestion(passedContext: TextContext? = nil, isAutoTrigger: Bool = false, wantsAlternates: Bool = false) {
        var willFireRequest = false
        defer {
            if wantsAlternates && !willFireRequest {
                if cycleRefetchPending != nil {
                    Log.debug("[Cycle] refetch bailed before fire — clearing pending so next ⌥↓ can retry")
                    cycleRefetchPending = nil
                }
            }
        }
        Log.debug("requestSuggestion called")
        guard settings.isEnabled else { Log.debug("Skipped: globally disabled"); return }
        if isFrontmostAppDisabled() { Log.debug("Skipped: app disabled (early)"); return }
        // Check deletion cooldown (skip for local provider — inference is cheap)
        let isLocal = settings.activeProvider == "local" && llamaProvider?.isModelLoaded == true
        if !isLocal {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDeleteTimestamp < deleteCooldown { Log.debug("Skipped: delete cooldown"); return }
        }

        // Reuse the context already read by processCharacterKeystroke when
        // available; otherwise read fresh. Saves a duplicate AX read on every
        // character that misses the cache (each read is 50–300 ms of MainActor
        // blocking).
        let context: TextContext
        if let passed = passedContext {
            context = passed
            Log.debug("Context (reused): app=\(context.appName) prefix='\(context.prefix.suffix(20))' suffix='\(context.suffix.prefix(20))' caretPos=\(context.caretPosition) textLen=\(context.textLength) atEnd=\(context.isAtEndOfText) atEOL=\(context.isAtEndOfLine) shouldSuggest=\(context.shouldSuggest)\(context.isSearchField ? " [SEARCH]" : "") winTitle='\(context.windowTitle.prefix(40))'")
        } else {
            let contextStart = CFAbsoluteTimeGetCurrent()
            guard let read = observeReadContext() else { Log.debug("Skipped: readContext returned nil"); return }
            let contextMs = (CFAbsoluteTimeGetCurrent() - contextStart) * 1000
            Log.debug("Context: app=\(read.appName) prefix='\(read.prefix.suffix(20))' suffix='\(read.suffix.prefix(20))' caretPos=\(read.caretPosition) textLen=\(read.textLength) atEnd=\(read.isAtEndOfText) atEOL=\(read.isAtEndOfLine) shouldSuggest=\(read.shouldSuggest)\(read.isSearchField ? " [SEARCH]" : "") winTitle='\(read.windowTitle.prefix(40))' contextReadMs=\(Int(contextMs))")
            context = read
        }

        // Don't suggest in password fields. Two reasons:
        //   1. Privacy: never send password text to the AI provider.
        //   2. Secure input UX: when secure input is on *because* the user
        //      focused a password field, the SecureInputNotifier check below
        //      would otherwise fire a misleading "Tab is blocked" hint naming
        //      the focused app as the culprit. Filtering here prevents that.
        // This path can be entered for password fields via the click handler
        // (mouse events still flow under secure input), so the keystroke-side
        // filter alone isn't sufficient.
        guard !context.isPasswordField else { Log.debug("Skipped: password field"); return }

        // Track last active app for per-app settings (skip self)
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        if context.appBundleId != ownBundleId {
            lastActiveAppBundleId = context.appBundleId
            lastActiveAppName = context.appName
        }

        // Trigger async screen context capture if needed (non-blocking)
        // Placed before shouldSuggest/disabled checks so app switches still capture context,
        // but captureIfNeeded itself respects the disabled apps list.
        if !settings.disabledApps.contains(context.appBundleId) {
            screenContextManager.captureIfNeeded(
                pid: context.appPid,
                appBundleId: context.appBundleId,
                inputBandFrame: context.inputBandFrame,
                windowTitle: context.windowTitle
            )
        }

        // Update focus monitor to track AX changes in this app (before shouldSuggest guard
        // so we can detect focus changes even in non-suggesting apps like Chrome)
        focusMonitor?.updateObservedApp(pid: context.appPid)

        let shouldSuggest: Bool = {
            if context.shouldSuggest { return true }
            // Mail reply with the caret above an INLINE quoted thread: the suffix holds
            // the quote, so isAtEndOfText/Line is false and the normal gate would skip.
            // Force-enable when we're in a recognized mail context and the suffix
            // contains an attribution line. (Generalizes the old Chrome+gmail+English
            // override; collapsed-web replies have an empty suffix → already at
            // end-of-text → the normal context.shouldSuggest above fires, so no
            // regression there.)
            if MailReplyAdapter.matches(appBundleId: context.appBundleId, windowTitle: context.windowTitle, appName: context.appName),
               MailReplyAdapter.detectsQuoteAtSuffixHead(context.suffix) {
                Log.debug("Mail reply: caret above inline quote — treating as suggestible")
                return true
            }
            return false
        }()
        guard shouldSuggest else { Log.debug("Skipped: shouldSuggest=false"); return }

        // Check if app is disabled
        if settings.disabledApps.contains(context.appBundleId) { Log.debug("Skipped: app disabled"); return }

        // Suppress when the user has just finished typing a question. Cloud
        // models' RLHF prior overwhelmingly answers question-ending text instead
        // of continuing it (e.g. "will there be any side effect?" → "The side
        // effect is small"). Local models don't share this prior, so the gate
        // is cloud-only. Trim only trailing spaces/tabs so a caret on a fresh
        // line below a prior question (prefix ends in '\n') doesn't get
        // misclassified. shouldSuggest above already filters mid-line edits.
        if !isLocal {
            let lastMeaningful = context.prefix.reversed().drop(while: { $0 == " " || $0 == "\t" }).first
            if lastMeaningful == "?" || lastMeaningful == "？" {
                Log.debug("Skipped: prefix ends with question mark (cloud)")
                return
            }
        }

        // Secure input check: this path can be triggered by clicks (which flow
        // through the event tap even under secure input) and by the screen-context
        // re-trigger timer. If secure input is on we'd waste an AI request and
        // then render ghost text the user can't accept with Tab. Bail early.
        if SecureInputNotifier.shared.checkAndNotify(caretRect: context.caretScreenRect, elementFrame: context.elementFrame) {
            Log.debug("Skipped: secure input (request)")
            return
        }

        // Browser compatibility gate: in browsers where we can't position ghost text
        // correctly, suppress the suggestion entirely (saves API cost, avoids visual
        // distraction from misplaced ghost text) and surface a one-shot hint instead.
        //
        // - Unfixable browsers (Firefox/Zen): always blocked. Their AX layer doesn't
        //   expose the per-character bounds API at all, and there's no user-side fix.
        // - Fixable browsers (Arc/Dia): blocked only when caret reading is actually
        //   degraded. If the user has enabled "Text Metrics" in chrome://accessibility,
        //   caret reading works, no degradation, no hint, suggestions flow normally.
        //
        // The hint is shown at most once per browser per session (deduped in
        // BrowserCompatibilityChecker), and the user can permanently dismiss it via the
        // ✕ button on the hint panel.
        if let limitedBrowser = LimitedBrowser.from(bundleId: context.appBundleId) {
            let shouldBlock = !limitedBrowser.isFixable || context.caretReadingDegraded
            if shouldBlock {
                BrowserCompatibilityChecker.shared.notifyIfNeeded(browser: limitedBrowser, elementFrame: context.elementFrame)
                Log.debug("Skipped: limited browser \(limitedBrowser.displayName) (fixable=\(limitedBrowser.isFixable), degraded=\(context.caretReadingDegraded))")
                return
            }
        }

        // Fallback cache check — instant check may have missed due to caret not yet moved.
        // Skip when this is a cycle refetch: the cache only stores the primary
        // completion, but cycle wants 3 fresh intent-divergent alternatives —
        // returning the cached primary would just re-show what the user
        // already saw and pressed ⌥↓ to leave behind.
        if !wantsAlternates, let cacheHit = cache.tryExactMatch(prefix: context.prefix, appBundleId: context.appBundleId) {
            let (chunk, remainder) = chunkForCacheForward(
                remainingSuggestion: cacheHit.remainingSuggestion,
                typedSinceCacheCount: cacheHit.typedSinceCacheCount
            )
            pendingRemainder = remainder.isEmpty ? nil : remainder
            let suggestion = Suggestion(
                displayText: chunk,
                insertText: chunk,
                caretRect: context.caretScreenRect,
                elementFrame: context.elementFrame,
                font: context.font,
                currentLinePrefix: context.currentLinePrefix,
                textAreaLeftEdge: context.textAreaLeftEdge
            )
            currentSuggestion = suggestion
            renderer.showSuggestion(suggestion.displayText, at: suggestion.caretRect, elementFrame: suggestion.elementFrame, font: suggestion.font, currentLinePrefix: suggestion.currentLinePrefix, textAreaLeftEdge: suggestion.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
            updateSuggestionVisibility(true)
            Log.debug("Cache exact match (debounced fallback): re-showing suggestion")
            return
        }

        let requestId = UUID().uuidString
        currentRequestId = requestId

        let screenContext = screenContextManager.currentContext
        lastRequestLackedScreenContext = (screenContext == nil && settings.isScreenContextEnabled)

        let sections = buildPromptSections(from: context)
        let priorContext = sections.priorContext
        let trimmedPrefix = sections.trimmedPrefix
        let trimmedSuffix = sections.trimmedSuffix
        let suffixKind = sections.suffixKind
        let userContext = sections.userContext
        let clipboardItems = sections.clipboardItems
        let recentMessages = sections.recentMessages
        let request = CompletionRequest(
            prefix: trimmedPrefix,
            suffix: trimmedSuffix,
            appName: context.appName,
            windowTitle: context.windowTitle,
            provider: settings.activeProvider,
            maxTokens: settings.maxSuggestionTokens,
            requestId: requestId,
            screenContext: screenContext,
            userContext: userContext,
            priorContext: priorContext,
            clipboardItems: clipboardItems.isEmpty ? nil : clipboardItems,
            recentMessages: recentMessages.isEmpty ? nil : recentMessages,
            wantsAlternates: wantsAlternates,
            suffixKind: suffixKind
        )

        let aiRequestStart = CFAbsoluteTimeGetCurrent()
        Log.debug("Sending request: provider=\(settings.activeProvider) requestId=\(requestId)")
        let splitInfo = priorContext.map { " | split: priorCtx=\($0.count) active=\(trimmedPrefix.count)" } ?? ""
        let kindInfo: String = {
            switch suffixKind {
            case .plain: return ""
            case .mailReply(let q): return " | mailQuote: lead=\(q.lead.count) newest=\(q.newest.count) older=\(q.older?.count ?? 0)"
            }
        }()
        Log.debug("[Request] prefix: '\(trimmedPrefix.suffix(50))' | suffix: '\(trimmedSuffix.prefix(50))' | prefixLen=\(trimmedPrefix.count)(was \(context.prefix.count)) suffixLen=\(trimmedSuffix.count)(was \(context.suffix.count))\(splitInfo)\(kindInfo)")

        Log.debug("Screen context: \(screenContextManager.currentContext ?? "none")")
        if settings.activeProvider == "local", let llama = llamaProvider, llama.isModelLoaded {
            Log.info("[Engine] request via local | requestId=\(requestId)")
            Task {
                do {
                    let text = try await llama.complete(
                        prefix: trimmedPrefix,
                        suffix: trimmedSuffix.isEmpty ? nil : trimmedSuffix,
                        suffixKind: suffixKind,
                        userContext: userContext,
                        screenContext: screenContext,
                        scrollback: priorContext,
                        clipboardItems: clipboardItems.isEmpty ? nil : clipboardItems,
                        recentMessages: recentMessages.isEmpty ? nil : recentMessages,
                        appName: context.appName,
                        windowTitle: context.windowTitle,
                        maxTokens: settings.maxSuggestionTokens,
                        midDecodeCancelEnabled: settings.isMidDecodeCancelEnabled
                    )
                    let aiMs = (CFAbsoluteTimeGetCurrent() - aiRequestStart) * 1000
                    // Local provider returns single completion (no 3-in-1 yet);
                    // wrap as single-element array so handleCompletionResult can
                    // share the cloud signature.
                    self.handleCompletionResult(.success([text]), requestId: requestId, context: context, aiLatencyMs: aiMs, isAutoTrigger: isAutoTrigger)
                } catch {
                    let aiMs = (CFAbsoluteTimeGetCurrent() - aiRequestStart) * 1000
                    self.handleCompletionResult(.failure(error), requestId: requestId, context: context, aiLatencyMs: aiMs, isAutoTrigger: isAutoTrigger)
                }
            }
        } else {
            // If user picked "local" but isModelLoaded==false (load failed,
            // sampler init failed, file corrupt, etc.), Engine silently
            // routes to cloud. Without this log, the user thinks local is
            // working — they're not. Surfaces gap #5 from the local-model
            // analysis: the silent local→cloud fallthrough.
            let providerLabel = settings.activeProvider == "local"
                ? "cloud (fallthrough: local selected but isModelLoaded=false)"
                : "cloud (\(Log.providerCode(settings.activeProvider)))"
            Log.info("[Engine] request via \(providerLabel) | requestId=\(requestId)")
            let isRefetch = wantsAlternates  // captured for closure
            willFireRequest = true
            cloudProvider.complete(request: request) { [weak self] result in
                Task { @MainActor in
                    let aiMs = (CFAbsoluteTimeGetCurrent() - aiRequestStart) * 1000
                    if isRefetch {
                        self?.handleCycleRefetchResult(result, requestId: requestId, context: context, aiLatencyMs: aiMs)
                    } else {
                        self?.handleCompletionResult(result, requestId: requestId, context: context, aiLatencyMs: aiMs, isAutoTrigger: isAutoTrigger)
                    }
                }
            }
        }
    }

    private func handleCompletionResult(_ result: Result<[String], Error>, requestId: String, context: TextContext, aiLatencyMs: Double = 0, isAutoTrigger: Bool = false) {
        // Ignore if this isn't the current request (was cancelled)
        guard requestId == currentRequestId else { Log.debug("Ignoring stale result for \(requestId)"); return }

        // Mark inflight as done so subsequent keystrokes can fire new requests (or coalesce).
        currentRequestId = nil

        switch result {
        case .success(let rawCandidates):
            // Cloud round-trip succeeded — any outage is over; re-arm the prompt.
            consecutiveCloudFailures = 0
            cloudOutageAlertShown = false
            // DPHM shallow fusion at the candidate level: optionally re-rank
            // the 3-in-1 alternates by personal-habit affinity. Conservative —
            // the challenger must beat the LLM's primary by rerank_margin.
            // Off by default (dphm.yaml: fusion.rerank_cloud_candidates).
            let candidates = habitMemory.config.rerankCloudCandidates
                ? habitMemory.rankCandidates(rawCandidates, bufferText: context.prefix)
                : rawCandidates
            // [0] is the primary; [1...] are cycle alternates. parseCandidates
            // guarantees ≥1 element. Fall back gracefully if cloud returned 0
            // (shouldn't happen but defensive).
            guard let rawSuggestion = candidates.first, !rawSuggestion.isEmpty else {
                Log.debug("Cloud returned empty candidate array, skipping")
                return
            }
            Log.info("[Latency] AI round-trip: \(Int(aiLatencyMs))ms | candidates=\(candidates.count) | primary: '\(rawSuggestion.prefix(40))'")

            var trimmed = PostProcessor.trimOverlap(
                suggestion: rawSuggestion,
                prefix: context.prefix,
                suffix: context.suffix
            )
            trimmed = PostProcessor.ensureSeparator(suggestion: trimmed, prefix: context.prefix, atWordBoundary: isAutoTrigger)
            Log.debug("Trimmed: '\(trimmed)' worthShowing=\(PostProcessor.isWorthShowing(trimmed))")

            guard PostProcessor.isWorthShowing(trimmed) else { Log.debug("Not worth showing, skipping"); return }

            // Always stash the full completion in cache keyed on the prefix it was fired for.
            // This lets future cache.tryAdvance() roll the suggestion against further-advanced prefixes.
            cache.store(suggestion: trimmed, prefix: context.prefix, appBundleId: context.appBundleId)

            // Post-flight roll: user may have typed more while the request was in flight.
            // If so, slice the completion to serve the current state — or refetch on divergence.
            // A failed re-read is NOT "nothing changed": in nil-on-empty apps
            // (WhatsApp/iMessage-class) it is the normal post-send state — the
            // field was just cleared, so serving would paint ghost text for the
            // message that was sent over an empty box. Treat it as divergence:
            // the refetch bails cleanly if the field is truly unreadable, and
            // the suggestion is already in `cache` for an instant re-show if
            // the nil was a transient AX hiccup.
            guard let fresh = observeReadContext() else {
                Log.debug("Post-flight re-read nil — refetching instead of serving")
                requestSuggestion()
                return
            }
            let displayContext: TextContext
            let effectiveSuggestion: String
            if fresh.appBundleId != context.appBundleId {
                Log.debug("App changed mid-flight (\(context.appBundleId) → \(fresh.appBundleId)) — refetching")
                requestSuggestion()
                return
            }
            // Divergence checks run against the *active* edit prefix (what
            // survives adapter routing — for Claude Code, the text after `❯`;
            // for everything else, the full RAW prefix). RAW changed without
            // active changing is the Claude Code TUI churn case (scrollback
            // redraws, spinner ticks, generated tokens above the input box);
            // pre-fix we refetched on every one of those and ghost text never
            // got to display.
            let consumedCount: Int
            if fresh.prefix != context.prefix {
                // Cheap RAW check short-circuited "nothing changed" already.
                // Compute active only when RAW changed.
                let requestActive = activePartOf(context)
                let freshActive = activePartOf(fresh)
                if freshActive != requestActive {
                    guard freshActive.hasPrefix(requestActive) else {
                        Log.debug("Post-flight divergence (active prefix changed, not extended) — refetching")
                        requestSuggestion()
                        return
                    }
                    let typed = String(freshActive.dropFirst(requestActive.count))
                    guard trimmed.hasPrefix(typed) else {
                        Log.debug("Post-flight divergence (typed '\(typed.prefix(20))' ≠ suggestion start) — refetching")
                        requestSuggestion()
                        return
                    }
                    effectiveSuggestion = String(trimmed.dropFirst(typed.count))
                    displayContext = fresh
                    consumedCount = typed.count
                    Log.debug("Post-flight roll ok: consumed \(typed.count) chars, serving '\(effectiveSuggestion.prefix(20))'")
                } else {
                    // RAW prefix changed but active didn't — Claude Code
                    // scrollback churn with stable user input. Keep the
                    // original request context for display so the caret
                    // anchor matches what we asked the model about.
                    effectiveSuggestion = trimmed
                    displayContext = context
                    consumedCount = 0
                }
            } else {
                effectiveSuggestion = trimmed
                displayContext = context
                consumedCount = 0
            }

            guard !effectiveSuggestion.isEmpty else { Log.debug("Post-roll suggestion empty"); return }

            // Race-check: secure input may have activated since the request fired.
            // Using displayContext (post-roll) for the check.
            if SecureInputNotifier.shared.checkAndNotify(caretRect: displayContext.caretScreenRect, elementFrame: displayContext.elementFrame) {
                Log.debug("Skipped: secure input (result)")
                return
            }

            // Progressive disclosure: new suggestion → reset chunk index to 0.
            resetProgressiveState()
            let (chunk, remainder) = PostProcessor.progressiveChunk(of: effectiveSuggestion, chunkIndex: chunkIndex, style: settings.chunkingStyle)
            pendingRemainder = remainder.isEmpty ? nil : remainder
            // typedSinceCache at this display = chars consumed during inflight (post-roll).
            // Including it in the threshold prevents a spurious type-through advance on the
            // first keystroke after a rolled suggestion arrives. Uses `consumedCount`
            // (active-prefix diff) rather than RAW prefix diff so Claude Code scrollback
            // growth doesn't inflate the threshold.
            nextCommitPosition = consumedCount + chunk.count
            let capStr = PostProcessor.progressiveWidthCap(forChunkIndex: chunkIndex, style: settings.chunkingStyle).map(String.init) ?? "unbounded"
            Log.debug("[Progressive] new suggestion: style=\(settings.chunkingStyle.rawValue) chunkIdx=\(chunkIndex) cap=\(capStr) chunk='\(chunk)' nextPos=\(nextCommitPosition)")

            let suggestion = Suggestion(
                displayText: chunk,
                insertText: chunk,
                caretRect: displayContext.caretScreenRect,
                elementFrame: displayContext.elementFrame,
                font: displayContext.font,
                currentLinePrefix: displayContext.currentLinePrefix,
                textAreaLeftEdge: displayContext.textAreaLeftEdge
            )

            currentSuggestion = suggestion

            // Populate cycle buffer with all candidates after primary processing.
            // Alts use a simplified pipeline (trimOverlap + ensureSeparator on
            // the SAME displayContext as primary, but skip post-flight roll
            // since they're alternates not the chosen text). De-dupe against
            // the primary so we don't show duplicates if cloud collapsed
            // candidates. Skipping cycle when only 1 unique candidate.
            cycleCandidates = []
            cycleActiveIndex = 0
            cycleDisplayContext = displayContext
            // Always include primary at [0]
            cycleCandidates.append(effectiveSuggestion)
            for raw in candidates.dropFirst() {
                var t = PostProcessor.trimOverlap(suggestion: raw, prefix: displayContext.prefix, suffix: displayContext.suffix)
                t = PostProcessor.ensureSeparator(suggestion: t, prefix: displayContext.prefix, atWordBoundary: isAutoTrigger)
                guard PostProcessor.isWorthShowing(t), !Self.isCycleDuplicate(t, in: cycleCandidates) else { continue }
                cycleCandidates.append(t)
            }
            Log.debug("[Cycle] populated buffer: \(cycleCandidates.count) candidate(s) (\(candidates.count) raw from cloud)")

            let renderStart = CFAbsoluteTimeGetCurrent()
            renderer.showSuggestion(suggestion.displayText, at: suggestion.caretRect, elementFrame: suggestion.elementFrame, font: suggestion.font, currentLinePrefix: suggestion.currentLinePrefix, textAreaLeftEdge: suggestion.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
            let renderMs = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000
            let e2eMs = (CFAbsoluteTimeGetCurrent() - lastKeystrokeTime) * 1000
            Log.info("[Latency] End-to-end: \(Int(e2eMs))ms (AI: \(Int(aiLatencyMs))ms, render: \(String(format: "%.1f", renderMs))ms, overhead: \(Int(e2eMs - aiLatencyMs))ms)")
            updateSuggestionVisibility(true)

            // Show contextual toolbar
            let isAppEnabled = !settings.disabledApps.contains(displayContext.appBundleId)
            renderer.showToolbar(
                near: displayContext.caretScreenRect,
                elementFrame: displayContext.elementFrame,
                appName: displayContext.appName,
                appBundleId: displayContext.appBundleId,
                isAppEnabled: isAppEnabled,
                isGloballyEnabled: settings.isEnabled
            )

        case .failure(let error):
            Log.error("Completion error: \(error)")
            handleCloudFailure(error)
        }
    }

    /// Track consecutive "cloud unavailable" failures and, once they cross the
    /// threshold, prompt the user (once per outage) to switch to the local
    /// model. Only provider-exhaustion statuses (429/502/503) count — these are
    /// the all-providers-down signal from OpenRouter (with allow_fallbacks:false
    /// it fans out across the pinned providers and returns one error only when
    /// every one fails). Network drops, auth (401) and bad-request (400) errors
    /// are ignored so a dropped Wi-Fi connection doesn't nag about local.
    private func handleCloudFailure(_ error: Error) {
        // Only relevant while a cloud provider is selected.
        guard settings.activeProvider != "local" else { return }
        guard case let CloudProviderError.httpError(code, _) = error,
              code == 429 || code == 502 || code == 503 else { return }

        consecutiveCloudFailures += 1
        guard consecutiveCloudFailures >= cloudOutageThreshold, !cloudOutageAlertShown else { return }
        cloudOutageAlertShown = true
        Log.info("[Engine] cloud outage detected (\(consecutiveCloudFailures) consecutive failures) — prompting local switch")
        showCloudOutageAlert()
    }

    /// One-time prompt shown when the cloud route is sustained-unavailable. We
    /// can't switch for the user (they may not have downloaded the local model),
    /// so this only points them to Settings; [Not Now] dismisses it.
    private func showCloudOutageAlert() {
        // Accessory (LSUIElement) app: the user is typing in another app when
        // this fires, so activate first or the alert surfaces behind windows.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "FlowIn — Cloud model unavailable"
        alert.informativeText = "Switch to the local model to keep getting suggestions."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            onRequestSettings?()
        }
    }

    /// Handle the result of a cycle-mode cloud refetch (wantsAlternates=true).
    /// Unlike handleCompletionResult — which displays the response as a fresh
    /// primary and resets cycle state — this APPENDS the new candidates to
    /// the existing buffer and advances the active index past the previously-
    /// shown content. Net effect for the user:
    ///
    ///   • From initial primary → ⌥↓ → buffer goes [primary] → [primary, c1, c2, c3]
    ///     and we display c1. ⌥↑ wraps back to primary.
    ///   • After partial accept → ⌥↓ → buffer goes [] → [c1, c2, c3] and we
    ///     display c1. The truncated old remainder isn't preserved; user
    ///     committed to that direction by accepting.
    private func handleCycleRefetchResult(_ result: Result<[String], Error>, requestId: String, context: TextContext, aiLatencyMs: Double = 0) {
        guard requestId == currentRequestId else {
            Log.debug("[Cycle] refetch result stale, dropping")
            cycleRefetchPending = nil
            return
        }
        currentRequestId = nil

        let direction = cycleRefetchPending ?? .next
        cycleRefetchPending = nil

        switch result {
        case .success(let candidates):
            Log.info("[Latency] AI round-trip (cycle refetch): \(Int(aiLatencyMs))ms | candidates=\(candidates.count)")

            // Use the same display context primary used. If no buffer existed
            // before refetch (post-partial-accept case), captureReadContext
            // gives us a fresh one as best-effort fallback.
            let dc: TextContext = cycleDisplayContext ?? context
            cycleDisplayContext = dc

            // Process each candidate the same way primary processes effectiveSuggestion
            // (trimOverlap + ensureSeparator + isWorthShowing + dedupe).
            let oldBufferSize = cycleCandidates.count
            for raw in candidates {
                var t = PostProcessor.trimOverlap(suggestion: raw, prefix: dc.prefix, suffix: dc.suffix)
                t = PostProcessor.ensureSeparator(suggestion: t, prefix: dc.prefix, atWordBoundary: false)
                guard PostProcessor.isWorthShowing(t), !Self.isCycleDuplicate(t, in: cycleCandidates) else { continue }
                cycleCandidates.append(t)
            }
            Log.debug("[Cycle] refetch buffer: \(oldBufferSize) → \(cycleCandidates.count)")

            // Land on the first newly-appended item so user sees a real
            // alternate, not the entry they were already looking at.
            // For .previous, jump to the LAST appended (visual ⌥↑ symmetry).
            guard cycleCandidates.count > oldBufferSize else {
                Log.info("[Cycle] refetch returned no new candidates — staying put")
                return
            }
            switch direction {
            case .next:
                cycleActiveIndex = oldBufferSize
            case .previous:
                cycleActiveIndex = cycleCandidates.count - 1
            }
            showCycleCandidate(at: cycleActiveIndex, displayContext: dc)

        case .failure(let error):
            Log.error("[Cycle] refetch error: \(error)")
        }
    }

    // MARK: - Acceptance

    func acceptFull(_ suggestion: Suggestion) {
        lastAcceptTime = CFAbsoluteTimeGetCurrent()
        let success = textInserter.insert(suggestion.insertText)
        if success {
            UsageStatsStore.shared.record(savedText: suggestion.insertText)
            // DPHM: accepted AI text is an endorsed habit signal (async).
            habitMemory.commitAcceptedSuggestion(suggestion.insertText)
            if let remainder = pendingRemainder, !remainder.isEmpty {
                // Show next chunk after a brief delay to let the AX tree update caret position.
                // Synthesis and clipboard paths both send a no-op Left+Right cursor flush
                // (see KeystrokeSynthesizer.flushCursor) which forces the host to refresh
                // its AX text marker immediately. 200ms gives the host's input loop time
                // to process the text insertion + flush events. The AX path doesn't need
                // a flush because its update is synchronous, so 100ms is enough.
                renderer.hideSuggestion()
                // Progressive disclosure: Tab fully committed the displayed chunk, so advance.
                chunkIndex += 1
                Log.debug("[Progressive] acceptFull: chunkIdx now \(chunkIndex)")
                // Cycle alts no longer apply — they were generated for the
                // old prefix, which no longer matches the post-accept state.
                // ⌥↓ after this will trigger a fresh cloud refetch (B-lazy).
                resetCycleState()
                let capturedRemainder = remainder
                let capturedInsertedLen = suggestion.insertText.count
                let waitNs: UInt64 = (textInserter.lastMethod == .m1) ? 100_000_000 : 200_000_000
                Task {
                    try? await Task.sleep(nanoseconds: waitNs)
                    self.showNextChunk(capturedRemainder, insertedCharsBeforeShow: capturedInsertedLen)
                }
            } else {
                renderer.hideSuggestion()
                updateSuggestionVisibility(false)
                currentSuggestion = nil
                pendingRemainder = nil
                resetProgressiveState()
                cache.invalidate()
                autoTriggerNextSuggestion()
            }
        }
    }

    func acceptWord(_ suggestion: Suggestion) {
        lastAcceptTime = CFAbsoluteTimeGetCurrent()
        let firstWord = PostProcessor.firstWord(of: suggestion.insertText)
        let success = textInserter.insert(firstWord)
        if success {
            UsageStatsStore.shared.record(savedText: firstWord)
            // DPHM: word-level accepts are habit evidence too (async).
            habitMemory.commitAcceptedSuggestion(firstWord)
            let remaining = String(suggestion.insertText.dropFirst(firstWord.count))
            if remaining.isEmpty || !PostProcessor.isWorthShowing(remaining) {
                if let pendingRem = pendingRemainder, !pendingRem.isEmpty {
                    // Tab consumed the last word of the displayed chunk.
                    // Treat as commit: advance chunkIndex and show the next chunk.
                    // Same delay logic as acceptFull (AX vs synthesis/clipboard).
                    renderer.hideSuggestion()
                    chunkIndex += 1
                    Log.debug("[Progressive] acceptWord last-word commit: chunkIdx now \(chunkIndex)")
                    resetCycleState()
                    let capturedRemainder = pendingRem
                    let capturedInsertedLen = firstWord.count
                    let waitNs: UInt64 = (textInserter.lastMethod == .m1) ? 50_000_000 : 200_000_000
                    Task {
                        try? await Task.sleep(nanoseconds: waitNs)
                        self.showNextChunk(capturedRemainder, insertedCharsBeforeShow: capturedInsertedLen)
                    }
                } else {
                    renderer.hideSuggestion()
                    updateSuggestionVisibility(false)
                    currentSuggestion = nil
                    pendingRemainder = nil
                    resetProgressiveState()
                    cache.invalidate()
                    autoTriggerNextSuggestion()
                }
            } else {
                // CRITICAL: Update currentSuggestion SYNCHRONOUSLY so that rapid
                // Tab presses see the advanced state. Without this, pressing
                // Tab twice within 200ms reads the same stale currentSuggestion both
                // times and inserts the same word twice (verified 2026-04-08 in Zoho
                // Mail compose: " I' I'veve read read to to share share a few few...").
                // The async task below only refines positioning (caret rect after line
                // wrap); the text content is owned by this synchronous update.
                let predicted = Suggestion(
                    displayText: remaining,
                    insertText: remaining,
                    caretRect: suggestion.caretRect,
                    elementFrame: suggestion.elementFrame,
                    font: suggestion.font,
                    currentLinePrefix: suggestion.currentLinePrefix,
                    textAreaLeftEdge: suggestion.textAreaLeftEdge
                )
                currentSuggestion = predicted
                // Cycle alts were generated for the pre-accept prefix and
                // no longer apply. Clear the buffer so the next ⌥↓ triggers
                // a fresh refetch instead of cycling stale alts at the wrong
                // caret position.
                resetCycleState()

                // Immediately update ghost text to remove the accepted word (avoids overlap)
                renderer.updateSuggestionAfterPartialAccept(remainingText: remaining, acceptedText: firstWord)

                // Then re-read caret position to handle line wraps correctly.
                // Synthesis and clipboard paths both include a cursor flush (see
                // KeystrokeSynthesizer.flushCursor) so 200ms is sufficient. AX path is
                // synchronous, 50ms is enough.
                let waitNs: UInt64 = (textInserter.lastMethod == .m1) ? 50_000_000 : 200_000_000
                Task {
                    try? await Task.sleep(nanoseconds: waitNs)
                    // Read currentSuggestion fresh (not captured) so this task uses
                    // whatever state rapid prior presses have advanced to. If the user
                    // dismissed or accepted everything in the meantime, bail out.
                    guard let current = self.currentSuggestion else { return }
                    if let context = self.observeReadContext() {
                        let refreshed = Suggestion(
                            displayText: current.displayText,
                            insertText: current.insertText,
                            caretRect: context.caretScreenRect,
                            elementFrame: context.elementFrame,
                            font: context.font,
                            currentLinePrefix: context.currentLinePrefix,
                            textAreaLeftEdge: context.textAreaLeftEdge
                        )
                        self.currentSuggestion = refreshed
                        self.renderer.showSuggestion(
                            refreshed.displayText, at: refreshed.caretRect,
                            elementFrame: refreshed.elementFrame, font: refreshed.font,
                            currentLinePrefix: refreshed.currentLinePrefix,
                            textAreaLeftEdge: refreshed.textAreaLeftEdge,
                            focusedAppBundleId: self.lastActiveAppBundleId
                        )
                    }
                }
            }
        }
    }

    /// Show the next chunk after a Tab/Right-arrow commit. `chunkIndex` should already
    /// be incremented by the caller. `insertedCharsBeforeShow` is the number of chars the
    /// caller inserted into the text buffer (which advanced typedSinceCache by that amount).
    private func showNextChunk(_ remainder: String, insertedCharsBeforeShow: Int) {
        let (nextChunk, nextRemainder) = PostProcessor.progressiveChunk(of: remainder, chunkIndex: chunkIndex, style: settings.chunkingStyle)
        pendingRemainder = nextRemainder.isEmpty ? nil : nextRemainder

        guard PostProcessor.isWorthShowing(nextChunk) else {
            renderer.hideSuggestion()
            updateSuggestionVisibility(false)
            currentSuggestion = nil
            pendingRemainder = nil
            resetProgressiveState()
            cache.invalidate()
            return
        }

        if let context = observeReadContext() {
            // Race: user may have moved into a password field during the
            // inter-chunk delay. Bail silently — same rationale as the
            // requestSuggestion guard.
            if context.isPasswordField {
                Log.debug("Skipped: password field (next chunk)")
                renderer.hideSuggestion()
                updateSuggestionVisibility(false)
                currentSuggestion = nil
                pendingRemainder = nil
                resetProgressiveState()
                return
            }
            // Race-check: user may have moved into a secure-input app between
            // accepting the previous chunk and showing the next.
            if SecureInputNotifier.shared.checkAndNotify(caretRect: context.caretScreenRect, elementFrame: context.elementFrame) {
                Log.debug("Skipped: secure input (next chunk)")
                renderer.hideSuggestion()
                updateSuggestionVisibility(false)
                currentSuggestion = nil
                pendingRemainder = nil
                resetProgressiveState()
                return
            }
            let next = Suggestion(
                displayText: nextChunk,
                insertText: nextChunk,
                caretRect: context.caretScreenRect,
                elementFrame: context.elementFrame,
                font: context.font,
                currentLinePrefix: context.currentLinePrefix,
                textAreaLeftEdge: context.textAreaLeftEdge
            )
            currentSuggestion = next
            // Update commit position. Math: post-Tab typedSinceCache equals the OLD
            // nextCommitPosition (since Tab inserted exactly the previous chunk), so
            // the new threshold = OLD nextCommitPosition + nextChunk.count = `+= nextChunk.count`.
            //
            // TODO(progressive disclosure drift): there is a small race window during the
            // 100–200ms inter-chunk delay where a fast-typing user can fire cache.tryAdvance
            // before this update lands, causing chunkForCacheForward to see the stale
            // nextCommitPosition and advance chunkIndex one extra step. Acknowledged
            // acceptable drift; the rebase-on-cache-forward math self-corrects on the next
            // keystroke. To eliminate fully, precompute (chunk, remainder) inside acceptFull
            // and pass them through, so nextCommitPosition can be updated synchronously
            // with chunkIndex. The `insertedCharsBeforeShow` parameter is reserved for
            // that future fix.
            nextCommitPosition += nextChunk.count
            renderer.showSuggestion(next.displayText, at: next.caretRect, elementFrame: next.elementFrame, font: next.font, currentLinePrefix: next.currentLinePrefix, textAreaLeftEdge: next.textAreaLeftEdge, focusedAppBundleId: lastActiveAppBundleId)
            updateSuggestionVisibility(true)
            Log.debug("[Progressive] showNextChunk: chunkIdx=\(chunkIndex) chunk='\(nextChunk)' nextPos=\(nextCommitPosition)")
        } else {
            renderer.hideSuggestion()
            updateSuggestionVisibility(false)
            currentSuggestion = nil
            pendingRemainder = nil
            resetProgressiveState()
        }
    }

    func dismiss(caller: String = #function) {
        Log.debug("dismiss() called from \(caller)")
        cancelCurrentRequest()
        renderer.hideSuggestion()
        renderer.hideToolbar()
        updateSuggestionVisibility(false)
        currentSuggestion = nil
        pendingRemainder = nil
        resetProgressiveState()
        resetCycleState()
        debouncer.cancel()
    }

    private func resetCycleState() {
        cycleCandidates = []
        cycleActiveIndex = 0
        cycleDisplayContext = nil
    }

    /// Two-layer dedup against existing buffer entries. Returns true if `t`
    /// is functionally a duplicate of any existing candidate.
    ///
    ///  Layer 1 — normalized exact match: lowercase + collapsed whitespace +
    ///    stripped trailing punctuation. Catches surface-only variations
    ///    like "Yes I'll be there" vs "Yes, I'll be there." that the model
    ///    sometimes emits as separate alts.
    ///
    ///  Layer 2 — first-3-words match (case-insensitive, trailing-punct
    ///    stripped). Catches "Yes I'd love to come" vs "Yes I'd love to
    ///    attend" — same opening commits the alt to the same intent
    ///    direction. Premise: when the user pressed ⌥↓ they explicitly
    ///    wanted a DIFFERENT direction; if they wanted to keep the shared
    ///    opening they could have partially accepted it first and then
    ///    cycled (a refetch from that further-along prefix).
    private static func isCycleDuplicate(_ candidate: String, in existing: [String]) -> Bool {
        let candidateNorm = normalizedForCycleDedup(candidate)
        for other in existing {
            if normalizedForCycleDedup(other) == candidateNorm { return true }
            if sharesFirstNWords(candidate, other, n: 3) { return true }
        }
        return false
    }

    private static func normalizedForCycleDedup(_ s: String) -> String {
        let collapsed = s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var stripped = collapsed
        while let last = stripped.last, last.isPunctuation {
            stripped.removeLast()
        }
        return stripped
    }

    private static func sharesFirstNWords(_ a: String, _ b: String, n: Int) -> Bool {
        let wordsA = a.split(separator: " ", omittingEmptySubsequences: true).prefix(n).map { normalizedWord($0) }
        let wordsB = b.split(separator: " ", omittingEmptySubsequences: true).prefix(n).map { normalizedWord($0) }
        // Both must have at least N words to qualify; short candidates are
        // not subject to the prefix-overlap rule (only normalized-equal would
        // catch them).
        guard wordsA.count == n && wordsB.count == n else { return false }
        return wordsA == wordsB
    }

    private static func normalizedWord(_ s: Substring) -> String {
        var w = s.lowercased()
        while let last = w.last, last.isPunctuation { w.removeLast() }
        while let first = w.first, first.isPunctuation { w.removeFirst() }
        return w
    }

    /// ⌥↓ — show next alternate, wrapping to primary at end. If the cycle
    /// buffer is empty (typically right after a partial accept invalidated
    /// the prior alts) → fire a fresh cloud request instead of no-op
    /// (B-lazy refetch). When the response arrives, handleCompletionResult
    /// honors the pending direction and advances directly to alt 1 instead
    /// of landing on the new primary.
    private func cycleNext() {
        if cycleCandidates.count > 1, let dc = cycleDisplayContext {
            cycleActiveIndex = (cycleActiveIndex + 1) % cycleCandidates.count
            showCycleCandidate(at: cycleActiveIndex, displayContext: dc)
            return
        }
        triggerCycleRefetch(direction: .next)
    }

    /// ⌥↑ — show previous alternate, wrapping at start. Same lazy-refetch
    /// behavior as cycleNext when buffer is empty.
    private func cyclePrevious() {
        if cycleCandidates.count > 1, let dc = cycleDisplayContext {
            cycleActiveIndex = (cycleActiveIndex - 1 + cycleCandidates.count) % cycleCandidates.count
            showCycleCandidate(at: cycleActiveIndex, displayContext: dc)
            return
        }
        triggerCycleRefetch(direction: .previous)
    }

    /// B-lazy refetch entry point: fires a fresh cloud request via the
    /// existing requestSuggestion path. Sets `cycleRefetchPending` so
    /// handleCompletionResult knows to land on the alternate (not the
    /// primary) after the response arrives. Cloud-only — local provider
    /// returns a single completion so cycle wouldn't have alts to land on.
    private func triggerCycleRefetch(direction: CycleRefetchDirection) {
        guard settings.activeProvider != "local" else {
            Log.debug("[Cycle] refetch skipped: local provider returns single completion")
            return
        }
        if cycleRefetchPending != nil {
            Log.debug("[Cycle] refetch already in flight, ignoring keypress")
            return
        }
        Log.info("[Cycle] buffer empty — firing fresh cloud refetch (direction=\(direction))")
        cycleRefetchPending = direction
        requestSuggestion(wantsAlternates: true)
    }

    private func showCycleCandidate(at index: Int, displayContext dc: TextContext) {
        let full = cycleCandidates[index]
        // Each candidate gets its own progressive chunking from chunk[0] —
        // we don't try to track per-candidate chunk progress yet (cycling
        // resets the chunk view to the top). Acceptable for v0.
        resetProgressiveState()
        let (chunk, remainder) = PostProcessor.progressiveChunk(of: full, chunkIndex: 0, style: settings.chunkingStyle)
        pendingRemainder = remainder.isEmpty ? nil : remainder
        nextCommitPosition = chunk.count

        let suggestion = Suggestion(
            displayText: chunk,
            insertText: chunk,
            caretRect: dc.caretScreenRect,
            elementFrame: dc.elementFrame,
            font: dc.font,
            currentLinePrefix: dc.currentLinePrefix,
            textAreaLeftEdge: dc.textAreaLeftEdge
        )
        currentSuggestion = suggestion
        renderer.showSuggestion(
            suggestion.displayText,
            at: suggestion.caretRect,
            elementFrame: suggestion.elementFrame,
            font: suggestion.font,
            currentLinePrefix: suggestion.currentLinePrefix,
            textAreaLeftEdge: suggestion.textAreaLeftEdge,
            focusedAppBundleId: lastActiveAppBundleId
        )
        Log.info("[Cycle] showing candidate \(index + 1)/\(cycleCandidates.count): '\(chunk.prefix(40))'")
    }

    /// Reset chunk-index and commit-position tracking. Called on any path that
    /// hides ghost text without continuing to a next chunk (i.e., not Tab/Right-arrow
    /// commit, which already incremented chunkIndex).
    private func resetProgressiveState() {
        chunkIndex = 0
        nextCommitPosition = 0
    }

    /// Cache-forward path: applies type-through advance check, chunks the remaining
    /// suggestion at the (possibly advanced) chunkIndex, and updates nextCommitPosition.
    /// The `> 0` guard on nextCommitPosition handles the case where state was just
    /// reset (e.g., post-dismiss); without it, a 0 ≥ 0 comparison would advance idx
    /// spuriously when no chunk was previously displayed.
    private func chunkForCacheForward(remainingSuggestion: String, typedSinceCacheCount: Int) -> (chunk: String, remainder: String) {
        let advancing = nextCommitPosition > 0 && typedSinceCacheCount >= nextCommitPosition
        if advancing {
            chunkIndex += 1
        }
        let (chunk, remainder) = PostProcessor.progressiveChunk(of: remainingSuggestion, chunkIndex: chunkIndex, style: settings.chunkingStyle)
        nextCommitPosition = typedSinceCacheCount + chunk.count
        Log.debug("[Progressive] cache-forward: typed=\(typedSinceCacheCount) advancing=\(advancing) chunkIdx=\(chunkIndex) chunk='\(chunk)' nextPos=\(nextCommitPosition)")
        return (chunk, remainder)
    }

    /// After the user fully accepted a suggestion (Tab or Right-arrow consuming the
    /// last remaining text), schedule a fresh request so they don't have to type a
    /// throwaway char to wake the next suggestion. Skips if the user typed during the
    /// AX-settle delay — their keystroke handler already owns the next request, and
    /// firing both would race two inflight requests.
    private func autoTriggerNextSuggestion() {
        let acceptedAt = CFAbsoluteTimeGetCurrent()
        let waitNs: UInt64 = (textInserter.lastMethod == .m1) ? 100_000_000 : 200_000_000
        Task {
            try? await Task.sleep(nanoseconds: waitNs)
            guard self.lastKeystrokeTime <= acceptedAt else {
                Log.debug("[Progressive] auto-trigger skipped: user typed since accept")
                return
            }
            Log.debug("[Progressive] auto-trigger: requesting next suggestion after full accept")
            self.requestSuggestion(isAutoTrigger: true)
        }
    }

    /// Hide suggestion and toolbar visually but keep cache intact for re-display on caret return.
    private func dismissVisual(caller: String = #function) {
        Log.debug("dismissVisual() called from \(caller)")
        renderer.hideSuggestion()
        renderer.hideToolbar()
        updateSuggestionVisibility(false)
        currentSuggestion = nil
        pendingRemainder = nil
        resetProgressiveState()
        resetCycleState()
        debouncer.cancel()
    }

    // MARK: - Prefix Trimming

    /// Cap the prefix to `maxChars`, keeping the tail. Snaps forward to the first
    /// newline after the cut point so we don't start mid-line (makes the truncated
    /// prompt more coherent for the AI). If no newline exists in the range, falls
    /// back to a hard cut.
    private func trimPrefix(_ prefix: String, maxChars: Int) -> String {
        guard prefix.count > maxChars else { return prefix }
        let startIndex = prefix.index(prefix.endIndex, offsetBy: -maxChars)
        // Snap forward to the next newline for a cleaner boundary
        if let newlineIndex = prefix[startIndex...].firstIndex(of: "\n") {
            return String(prefix[prefix.index(after: newlineIndex)...])
        }
        return String(prefix[startIndex...])
    }

    /// Cap the suffix to `maxChars`, keeping the head (text immediately after the
    /// cursor). Snaps backward to the last newline within the range so we don't
    /// end mid-line. If no newline exists, falls back to a hard cut.
    private func trimSuffix(_ suffix: String, maxChars: Int) -> String {
        guard suffix.count > maxChars else { return suffix }
        let endIndex = suffix.index(suffix.startIndex, offsetBy: maxChars)
        // Snap backward to the previous newline for a cleaner boundary
        if let newlineIndex = suffix[..<endIndex].lastIndex(of: "\n") {
            return String(suffix[..<newlineIndex])
        }
        return String(suffix[..<endIndex])
    }

    /// The portion of the prefix the user is actually editing — what survives
    /// after per-app adapter routing. For Claude Code that's the text after
    /// the `❯` input marker; for everything else it's `context.prefix` as-is.
    ///
    /// Used by post-flight divergence checks so scrollback churn (Claude Code
    /// TUI redraws, spinner ticks, generated tokens above the input box)
    /// doesn't trigger a refetch when the user's actual edit position hasn't
    /// moved. Without this, every response while Claude Code is generating
    /// gets discarded because the RAW prefix changes in the middle even when
    /// the active edit is stable — a stable failure mode that prevents ghost
    /// text from displaying.
    private func activePartOf(_ context: TextContext) -> String {
        if ClaudeCodeAdapter.matches(windowTitle: context.windowTitle, appName: context.appName) {
            let r = ClaudeCodeAdapter.preprocess(
                rawPrefix: context.prefix,
                provider: settings.activeProvider,
                localCap: Self.maxPrefixCharsLocal
            )
            return r.trimmedPrefix
        }
        return context.prefix
    }

    // MARK: - Suggestion Visibility Sync

    private func updateSuggestionVisibility(_ visible: Bool) {
        inputMonitor?.setSuggestionVisible(visible)
        if visible {
            // Record prefix length when suggestion first becomes visible
            if let context = observeReadContext() {
                suggestionPrefixLength = context.prefix.count
            }
        }
    }

    // MARK: - Cancellation

    private func cancelCurrentRequest() {
        guard currentRequestId != nil else { return }
        if settings.activeProvider == "local" {
            // Mid-decode cancel: abort the in-flight local decode so the next
            // request isn't head-of-line blocked. Gated behind the rollout flag;
            // when off, keep the historical no-op (the in-flight request finishes
            // and the post-flight roll in handleCompletionResult serves or refetches).
            // When on, cancel() bumps generationId → the decode bails at its next
            // batch/token boundary and syncCaches any partial work.
            guard settings.isMidDecodeCancelEnabled else { return }
            llamaProvider?.cancel()
        } else {
            cloudProvider.cancel()
        }
        currentRequestId = nil
        // Drop any pending B-lazy refetch direction — a typing-driven new
        // request shouldn't inherit "advance to alt 1 on landing" semantics
        // meant for the cancelled cycle refetch.
        cycleRefetchPending = nil
    }

    // MARK: - Recent Messages History

    /// Snapshot of state captured at Return time. The 250 ms confirmation
    /// timer carries this in its closure, so rapid back-to-back Returns each
    /// confirm against their own original state instead of fighting over a
    /// shared `pendingMessage` member.
    private struct PendingMessageCandidate {
        let text: String
        let screenContext: String?
        let appName: String
        let windowTitle: String
        let appBundleId: String
        let originalLength: Int
    }

    /// On Return, snapshot the freshest field state (from `lastObserved*`,
    /// populated by the most recent keystroke's readContext) and schedule a
    /// 250 ms confirmation. We don't read AX here — by the time our handler
    /// runs, the focused app may already be processing the Return, and a
    /// fresh read could return the cleared field instead of the message.
    private func captureSentMessageCandidate() {
        // Suppress the transition-based path for ~300 ms so it doesn't
        // double-capture against the Return-confirmation path that's about
        // to schedule below.
        lastReturnTime = CFAbsoluteTimeGetCurrent()

        let prefix = lastObservedPrefix ?? ""
        let suffix = lastObservedSuffix ?? ""
        let combined = prefix + suffix
        // Normalize each component (trim + collapse whitespace), then cap
        // prefix from the tail (last N chars = most recent typing) and
        // suffix from the head (first N chars = text right after cursor).
        // See `MessageHistory.captureText` for details.
        let text = MessageHistory.captureText(prefix: prefix, suffix: suffix)
        // Need at least 2 chars to be worth recording — single-char sends are
        // almost certainly noise (one-letter Slack reactions like "k" are an
        // edge case we'd rather miss than risk false-positive captures of
        // accidental Returns on short text).
        guard text.count >= 2 else { return }
        guard let appName = lastObservedAppName,
              let appBundleId = lastObservedAppBundleId,
              let windowTitle = lastObservedWindowTitle else { return }

        let candidate = PendingMessageCandidate(
            text: text,
            screenContext: screenContextManager.currentContext,
            appName: appName,
            windowTitle: windowTitle,
            appBundleId: appBundleId,
            originalLength: combined.count
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            self?.confirmSentMessage(candidate)
        }
    }

    /// Confirm the candidate by checking either signal: focused app changed
    /// (user moved on after sending) OR focused field is now near-empty
    /// (chat send cleared it). Either is sufficient. If neither, the Return
    /// was probably just a newline in an editor — discard.
    private func confirmSentMessage(_ candidate: PendingMessageCandidate) {
        // Signal A: app switched. Cheap NSWorkspace check, no AX.
        let nowBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appSwitched = nowBundleId != candidate.appBundleId

        // Signal B: field cleared. Only check if app didn't switch — an AX
        // read against a different app's focused element would be meaningless.
        // Threshold is a quarter of the original length so we still catch
        // chat apps that leave a small placeholder/header after sending.
        // A nil context after Return is also a positive signal: the focused
        // element existed at Return time (we read it for the candidate), so
        // its disappearance 250ms later means the app tore down the input
        // (iMessage does this on send — focus bounces through Send button or
        // the field is re-created). Won't false-fire in Terminal-like apps
        // that keep their AX field intact post-Return.
        var fieldCleared = false
        var diag = "ctx=nil"
        if !appSwitched {
            if let ctx = observeReadContext() {
                let nowLength = ctx.prefix.count + ctx.suffix.count
                let threshold = max(0, candidate.originalLength / 4)
                fieldCleared = nowLength <= threshold
                diag = "nowLen=\(nowLength) threshold=\(threshold) elem='\(ctx.prefix.suffix(30))'"
            } else {
                fieldCleared = true
                diag = "ctx=nil (treated as cleared)"
            }
        }

        guard appSwitched || fieldCleared else {
            Log.debug("[MsgHistory] Return without submit — discarded ('\(candidate.text)') [origLen=\(candidate.originalLength) appSwitched=\(appSwitched) \(diag)]")
            return
        }
        let signal = appSwitched ? "app-switch" : "field-clear"
        messageHistory.record(MessageHistory.SentMessage(
            text: candidate.text,
            screenContext: candidate.screenContext,
            appName: candidate.appName,
            windowTitle: candidate.windowTitle,
            timestamp: Date()
        ))
        // DPHM: the user's own sent text is the strongest habit-learning
        // signal — consolidate it (async cold path; never blocks typing).
        habitMemory.commitSentMessage(candidate.text)
        Log.debug("[MsgHistory] captured (len=\(candidate.text.count), signal: \(signal), app: \(candidate.appName)): '\(candidate.text)'")
    }

    /// Capture the *previous* context's prefix+suffix (still held in
    /// `lastObserved*` at the moment this is called from
    /// `detectContextTransitionForMessageHistory`) as a sent-message
    /// candidate. Min length 10 chars to filter out single-char focus
    /// states, search-box scratch, etc. Records bypass the 250 ms
    /// confirmation that the Return path uses — the transition itself is
    /// the signal.
    private func captureLastObservedAsSentMessage(reason: String) {
        let prefix = lastObservedPrefix ?? ""
        let suffix = lastObservedSuffix ?? ""
        let text = MessageHistory.captureText(prefix: prefix, suffix: suffix)
        guard text.count >= 10 else { return }
        guard let appName = lastObservedAppName,
              let appBundleId = lastObservedAppBundleId,
              let windowTitle = lastObservedWindowTitle else { return }
        // Don't capture terminal content as a "sent message". A terminal's AX
        // value is the whole screen (TUI), not a chat message — and progress
        // spinners animate the window title, which the transition detector reads
        // as a window-switch, firing a fresh whole-screen capture every frame.
        // That churns the `messages` prompt section and re-decodes the local KV
        // cache on every keystroke while a TUI (e.g. Claude Code) is generating.
        // The Return-confirmation path (confirmSentMessage) is separate, captures
        // the actual sent line, and already skips terminals (field doesn't clear).
        if ClaudeCodeAdapter.isTerminal(appName: appName) {
            Log.debug("[MsgHistory] skip transition capture — terminal (app=\(appName), reason: \(reason))")
            return
        }
        _ = appBundleId  // unused — kept for symmetry with confirmSentMessage; record() doesn't need it
        messageHistory.record(MessageHistory.SentMessage(
            text: text,
            screenContext: screenContextManager.currentContext,
            appName: appName,
            windowTitle: windowTitle,
            timestamp: Date()
        ))
        // DPHM: transition-confirmed sent text — same strong habit signal
        // as the Return-confirmed path.
        habitMemory.commitSentMessage(text)
        Log.debug("[MsgHistory] captured (len=\(text.count), reason: \(reason), app: \(appName)): '\(text)'")
    }

    // MARK: - FocusMonitorDelegate

    func focusMonitorDidDetectFocusChange(_ monitor: FocusMonitor) {
        // Suppress focus-change dismiss briefly after accepting (AX mutations can re-fire focus notifications)
        if CFAbsoluteTimeGetCurrent() - lastAcceptTime < 0.3 { return }

        // Only cancel requests and dismiss on actual app switch — WKWebView apps
        // (Outlook, Slack) fire spurious AX focus notifications during normal typing
        let currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appChanged = currentApp != lastActiveAppBundleId

        if appChanged {
            if currentRequestId != nil {
                cancelCurrentRequest()
                debouncer.cancel()
            }
            if renderer.isSuggestionVisible || renderer.toolbarPanel.isVisible {
                dismiss()
            }
            cancelReplyOffer()   // drop any armed offer when the app changes
        }

        // Trigger screen context recapture on focus change (with delay for page load)
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay for page load
            if let context = self.observeReadContext(),
               !self.settings.disabledApps.contains(context.appBundleId) {
                self.focusMonitor?.updateObservedApp(pid: context.appPid)
                Log.debug("[ScreenContext] Focus changed — recapturing")
                self.screenContextManager.onClickDetected(
                    pid: context.appPid,
                    appBundleId: context.appBundleId,
                    inputBandFrame: context.inputBandFrame,
                    windowTitle: context.windowTitle
                )
                self.armReplyOffer(appBundleId: context.appBundleId, windowTitle: context.windowTitle, appName: context.appName)
            } else if let probe = self.contextReader.probeFocusedField(),
                      !self.settings.disabledApps.contains(probe.appBundleId) {
                // Same WhatsApp/iMessage-class fallback as the click path:
                // empty fields fail text extraction, so app switches into
                // these apps never recaptured. A probe-confirmed text focus
                // is enough to crop + OCR.
                self.observeProbedField(probe)
                self.focusMonitor?.updateObservedApp(pid: probe.appPid)
                Log.debug("[ScreenContext] Focus changed (probe fallback) — recapturing")
                self.screenContextManager.onClickDetected(
                    pid: probe.appPid,
                    appBundleId: probe.appBundleId,
                    inputBandFrame: probe.inputBandFrame,
                    windowTitle: probe.windowTitle
                )
                self.armReplyOffer(appBundleId: probe.appBundleId, windowTitle: probe.windowTitle, appName: probe.appName)
            } else if self.fireWeChatCaptureIfFrontmost() {
                // WeChat is AX-blind (no focused element / no text), so the context and
                // probe branches both miss it — app-switching into WeChat never armed the
                // offer (clicking did, via the click path's WeChat branch). Mirror it here.
                self.armReplyOffer(appBundleId: "com.tencent.xinWeChat", windowTitle: "", appName: "WeChat")
            }
        }

        // OCR-independent prefill trigger: focus change is a field-entry signal
        // that doesn't depend on the screen-OCR pipeline (which bails on some
        // windows, e.g. Notes). Self-gates on idle/eligible + fire-cap, so it
        // coalesces with the click / onContextReady triggers rather than stacking.
        firePrefillIfEligible()
    }

    // MARK: - Auto reply offer (idle-in-a-reply-box)

    /// Start the 5 s idle countdown after the user lands in an empty, allowlisted
    /// reply box. Cheap app-level pre-gate here; the authoritative field check
    /// (empty draft, search field, geometry) runs in ReplyController.showOffer at fire.
    private func armReplyOffer(appBundleId: String, windowTitle: String, appName: String) {
        guard settings.isReplyAutoOfferEnabled,
              AutoReplyGate.allows(appBundleId: appBundleId, windowTitle: windowTitle, appName: appName) else { return }
        // WeChat-only cooldown: skip re-arming while a recent cursor-anchored offer is
        // still within its window. Other apps fall straight through.
        if appBundleId == "com.tencent.xinWeChat", let shownAt = lastWeChatOfferShownAt,
           ProcessInfo.processInfo.systemUptime - shownAt < Self.weChatOfferCooldownSeconds { return }
        replyOfferWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireReplyOffer(expectedBundleId: appBundleId) }
        replyOfferWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyOfferIdleSeconds, execute: work)
    }

    private func fireReplyOffer(expectedBundleId: String) {
        replyOfferWork = nil
        guard settings.isReplyAutoOfferEnabled,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleId,
              !renderer.isSuggestionVisible,                 // mid-typing — autocomplete owns the badge
              replyController?.isActive != true else { return }
        // Start the WeChat cooldown only when the badge actually appears — showOffer can
        // still bail (cursor off the WeChat window, bad geometry, non-empty draft).
        if replyController?.showOffer() == true, expectedBundleId == "com.tencent.xinWeChat" {
            lastWeChatOfferShownAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// Cancel a pending arm and tear down any un-clicked offer badge (typing,
    /// click-away, app switch). No-op once a real reply is on screen.
    private func cancelReplyOffer() {
        replyOfferWork?.cancel()
        replyOfferWork = nil
        replyController?.dismissOffer()
    }

    // MARK: - ToolbarPanelDelegate

    func toolbarDidDisableForCurrentApp(_ toolbar: ToolbarPanel, duration: DisableDuration) {
        let bundleId = toolbar.currentAppBundleId
        settings.disableForApp(bundleId)
        cache.invalidate()
        dismiss()
        scheduleReEnable(duration: duration) { [weak self] in
            self?.settings.enableForApp(bundleId)
        }
    }

    func toolbarDidEnableForCurrentApp(_ toolbar: ToolbarPanel) {
        let bundleId = toolbar.currentAppBundleId
        settings.enableForApp(bundleId)
    }

    func toolbarDidDisableGlobally(_ toolbar: ToolbarPanel, duration: DisableDuration) {
        settings.isEnabled = false
        cache.invalidate()
        dismiss()
        scheduleReEnable(duration: duration) { [weak self] in
            self?.settings.isEnabled = true
        }
    }

    func toolbarDidEnableGlobally(_ toolbar: ToolbarPanel) {
        settings.isEnabled = true
    }

    func toolbarDidRequestSettings(_ toolbar: ToolbarPanel) {
        onRequestSettings?()
    }

    private var reEnableTimer: DispatchWorkItem?

    private func scheduleReEnable(duration: DisableDuration, action: @escaping () -> Void) {
        reEnableTimer?.cancel()
        reEnableTimer = nil
        let seconds: TimeInterval
        switch duration {
        case .minutes15: seconds = 15 * 60
        case .minutes60: seconds = 60 * 60
        case .indefinitely: return
        }
        let work = DispatchWorkItem { [weak self] in
            action()
            self?.reEnableTimer = nil
        }
        reEnableTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
