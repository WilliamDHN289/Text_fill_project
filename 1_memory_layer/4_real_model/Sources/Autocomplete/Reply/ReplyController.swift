import AppKit

@MainActor
final class ReplyController {
    private let contextReader: ContextReader
    private let screenContext: ScreenContextManager
    private let cloud: CloudProvider
    private let inserter: TextInserter
    private let settings: SettingsManager
    private let messageHistory: MessageHistory
    private let clipboardHistory: ClipboardHistory
    private let toolbar: ToolbarPanel        // hosts the whole reply surface (chips + preview)
    // Weak reference so we can update the event-tap flag without a retain cycle.
    private weak var inputMonitor: InputMonitor?

    private var intents: [ReplyIntent] = []
    private var conversation = ""
    private var appName = ""
    private var windowTitle = ""
    private var recentMessages: [String] = []
    private var clipboardItems: [String] = []
    private var draftPrefix = ""
    private var draftSuffix = ""
    private var suffixKind: SuffixKind = .plain
    private var scrollback = ""                        // terminal prior context (Claude Code split)
    private var expansions: [Int: String] = [:]      // per-chip cache
    private var generation = 0                        // invalidates stale async work
    private var stage: ReplyCardPhase = .chips        // chips (pill) vs preview (grown-down)
    private var active = false                         // a reply is on screen (chips/preview/error)
    private var editingCustom = false                  // the ✎ custom-intent field is open

    /// Whitespace/newlines + zero-width characters. A contenteditable "empty"
    /// field (e.g. Discord) often holds a zero-width placeholder, which a plain
    /// .whitespacesAndNewlines trim leaves behind — making prefix/suffix look
    /// non-empty.
    private static let effectivelyBlank = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{2060}"))

    init(contextReader: ContextReader, screenContext: ScreenContextManager, cloud: CloudProvider,
         inserter: TextInserter, settings: SettingsManager,
         messageHistory: MessageHistory, clipboardHistory: ClipboardHistory,
         toolbar: ToolbarPanel, inputMonitor: InputMonitor? = nil) {
        self.contextReader = contextReader
        self.screenContext = screenContext
        self.cloud = cloud
        self.inserter = inserter
        self.settings = settings
        self.messageHistory = messageHistory
        self.clipboardHistory = clipboardHistory
        self.toolbar = toolbar
        self.inputMonitor = inputMonitor
        toolbar.onReplyChipSelected = { [weak self] idx in self?.preview(idx) }
        toolbar.onReplyAccept = { [weak self] in self?.accept() }
        toolbar.onCustomIntentSubmit = { [weak self] text in self?.submitCustomInput(text) }
        toolbar.onCustomIntentCancel = { [weak self] in self?.cancelCustomInput() }
    }

    var isActive: Bool { active }

    /// Reply drafting always runs on a cloud model. When the app is set to the
    /// local provider, fall back to Cloud — Fast (openrouter) rather than
    /// blocking — the local model isn't wired into the reply path.
    private var replyProvider: String {
        settings.activeProvider == "local" ? "openrouter" : settings.activeProvider
    }

    /// Show the badge as a reply offer (no generation) when the user has idled in a
    /// known reply box. Clicking the badge runs trigger() — the normal first stage.
    /// The authoritative gate lives here so a stale arm (app switched mid-idle) is
    /// rejected against fresh context.
    /// Returns true only when the offer badge was actually shown — the caller uses this to
    /// start the WeChat cooldown, so it must not fire on the early-bail paths below.
    func showOffer() -> Bool {
        guard settings.isReplyAutoOfferEnabled, !active else { return false }
        guard let ctx = contextReader.readContextForReply() else { return false }
        guard ctx.caretScreenRect.origin.y.isFinite, ctx.elementFrame.origin.x.isFinite,
              abs(ctx.caretScreenRect.origin.y) < 1e9, abs(ctx.elementFrame.origin.x) < 1e9 else { return false }
        guard AutoReplyGate.allows(appBundleId: ctx.appBundleId, windowTitle: ctx.windowTitle, appName: ctx.appName),
              !ctx.isSearchField else { return false }
        // Only offer when nothing has been drafted yet. prefix is the text before the
        // caret — empty means the user hasn't started typing a reply (a mail quote
        // sits in the suffix, so requiring an empty prefix still offers on Gmail).
        guard ctx.prefix.trimmingCharacters(in: Self.effectivelyBlank).isEmpty else { return false }
        toolbar.showReplyOffer(near: ctx.elementFrame, caret: ctx.caretScreenRect, appBundleId: ctx.appBundleId)
        return true
    }

    /// Dismiss an un-clicked offer badge (typing / click-away / app switch). No-op
    /// once a real reply is on screen.
    func dismissOffer() {
        toolbar.dismissReplyOffer()
    }

    func trigger() {
        // readContextForReply (not readContext): falls back to a frames-only probe for
        // WhatsApp / Messages, whose empty fields fail AX text extraction — the reply needs
        // the frames + screen OCR, not the field's own text.
        guard let ctx = contextReader.readContextForReply() else { return }
        // Degenerate AX geometry — e.g. a focused browser web-area reporting a junk caret
        // y≈1.8e20 — isn't a real reply target and would clamp the badge into a screen
        // corner. Bail silently, the same as non-text focus (no badge, no bubble).
        guard ctx.caretScreenRect.origin.y.isFinite, ctx.elementFrame.origin.x.isFinite,
              abs(ctx.caretScreenRect.origin.y) < 1e9, abs(ctx.elementFrame.origin.x) < 1e9 else { return }
        generation += 1; let gen = generation
        stage = .chips
        appName = ctx.appName; windowTitle = ctx.windowTitle
        expansions = [:]
        recentMessages = messageHistory.snapshot().map { $0.text }
        clipboardItems = clipboardHistory.snapshot()
        let provider = replyProvider
        // Route the raw prefix/suffix through the same per-app adapters the autocomplete
        // Engine uses (Engine.buildPromptSections): the terminal scrollback and the mail
        // quoted-thread become first-class reply context, not dumped into the draft section.
        if ClaudeCodeAdapter.matches(windowTitle: ctx.windowTitle, appName: ctx.appName) {
            let r = ClaudeCodeAdapter.preprocess(rawPrefix: ctx.prefix, provider: provider, localCap: 1500)
            scrollback = (r.priorContext ?? "").trimmingCharacters(in: Self.effectivelyBlank)
            draftPrefix = r.trimmedPrefix.trimmingCharacters(in: Self.effectivelyBlank)
            draftSuffix = r.trimmedSuffix.trimmingCharacters(in: Self.effectivelyBlank)
            suffixKind = .plain
        } else if MailReplyAdapter.matches(appBundleId: ctx.appBundleId, windowTitle: ctx.windowTitle, appName: ctx.appName) {
            scrollback = ""
            draftPrefix = ctx.prefix.trimmingCharacters(in: Self.effectivelyBlank)
            draftSuffix = ctx.suffix.trimmingCharacters(in: Self.effectivelyBlank)
            suffixKind = MailReplyAdapter.preprocess(rawSuffix: ctx.suffix).map { .mailReply(quote: $0) } ?? .plain
        } else {
            scrollback = ""
            draftPrefix = ctx.prefix.trimmingCharacters(in: Self.effectivelyBlank)
            draftSuffix = ctx.suffix.trimmingCharacters(in: Self.effectivelyBlank)
            suffixKind = .plain
        }
        // Pulse the real badge while the first stage generates; it then expands into the chips.
        toolbar.startLoadingPulse(near: ctx.elementFrame, caret: ctx.caretScreenRect, appBundleId: ctx.appBundleId)
        Task {
            // Screen OCR is just one source — and often the least useful (window chrome, mail
            // subject/recipients). Capture it only when enabled; otherwise rely on the suffix
            // (mail thread), prefix (draft), and scrollback (terminal prior context).
            var convo = ""
            if settings.isScreenContextEnabled {
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                // The cropper derives the crop WIDTH from inputBandFrame.width, so a zero-width
                // caret rect yields an empty crop — use the full input-band frame.
                convo = (await screenContext.captureNow(
                    pid: pid,
                    appBundleId: ctx.appBundleId,
                    inputBandFrame: ctx.inputBandFrame,
                    windowTitle: ctx.windowTitle
                )) ?? ""
                guard gen == generation else { return }
            }
            conversation = convo
            // Draft if ANY context source has content; otherwise dismiss the loading badge
            // silently — no "nothing to reply" bubble (it reads as noise, and lands in a
            // screen corner whenever the caret geometry is junk).
            guard !convo.isEmpty || !draftSuffix.isEmpty || !draftPrefix.isEmpty || !scrollback.isEmpty else {
                toolbar.stopLoadingPulse()
                toolbar.hide()
                return
            }
            do {
                let raw = try await cloud.generateReplyIntents(
                    conversation: convo,
                    userContext: settings.userContextOrNil,
                    appName: appName,
                    windowTitle: windowTitle,
                    provider: provider,
                    recentMessages: recentMessages,
                    clipboardItems: clipboardItems,
                    prefix: draftPrefix,
                    suffix: draftSuffix,
                    suffixKind: suffixKind,
                    scrollback: scrollback
                )
                guard gen == generation else { return }
                intents = raw.map { ReplyIntent(text: $0) }
                toolbar.showReplyChips(intents.map { $0.text })   // badge expands into the chip strip
                active = true
                inputMonitor?.setReplyActive(true)
            } catch {
                guard gen == generation else { return }
                toolbar.stopLoadingPulse()
                showError("Couldn't draft replies. Tap again to retry.", ctx: ctx)
            }
        }
    }

    /// Show an error/info message below a collapsed badge (the badge grows down to show it).
    private func showError(_ message: String, ctx: TextContext) {
        toolbar.showCollapsed(near: ctx.elementFrame, caret: ctx.caretScreenRect, appBundleId: ctx.appBundleId)
        toolbar.setReplyPreviewError(message)
        active = true
        inputMonitor?.setReplyActive(true)
    }

    func handleArrow(left: Bool) {
        guard active, toolbar.replyChipCount > 0 else { return }
        toolbar.highlightReplyChip(index: toolbar.highlightedReplyChip + (left ? -1 : 1))
        // In preview stage, moving the highlight must re-expand the newly selected
        // intent — otherwise the preview stays stale and Enter would accept the
        // wrong reply. In chips stage, arrows only move the highlight (Enter previews).
        if stage == .preview { preview(toolbar.highlightedReplyChip) }
    }

    func choose() {
        if stage == .preview { accept() }
        else { preview(toolbar.highlightedReplyChip) }
    }

    private func preview(_ index: Int) {
        if index == intents.count {           // the trailing ✎ chip → open the custom-intent input
            openCustomInput()
            return
        }
        guard index < intents.count else { return }
        if editingCustom {                    // leaving the field to expand a real chip instead
            editingCustom = false
            inputMonitor?.setCustomEditing(false)
        }
        stage = .preview
        if let cached = expansions[index] {
            toolbar.showReplyPreview(cached)
            return
        }
        let gen = generation
        let provider = replyProvider
        toolbar.showReplyPreview("…")
        Task {
            do {
                let reply = try await cloud.expandReply(
                    intent: intents[index].text,
                    conversation: conversation,
                    userContext: settings.userContextOrNil,
                    appName: appName,
                    windowTitle: windowTitle,
                    provider: provider,
                    recentMessages: recentMessages,
                    clipboardItems: clipboardItems,
                    prefix: draftPrefix,
                    suffix: draftSuffix,
                    suffixKind: suffixKind,
                    scrollback: scrollback
                )
                guard gen == generation, active else { return }
                expansions[index] = reply
                if toolbar.highlightedReplyChip == index { toolbar.showReplyPreview(reply) }
            } catch {
                guard gen == generation, active else { return }
                toolbar.setReplyPreviewError("Couldn't draft that reply.")
            }
        }
    }

    /// Open the ✎ input. Route keys to the panel's field (not the Engine) while it's open.
    private func openCustomInput() {
        editingCustom = true
        inputMonitor?.setCustomEditing(true)
        toolbar.beginCustomIntent()
    }

    /// Clipboard edits (Cmd-V/C/X/A) routed from InputMonitor — the host app's menu would
    /// otherwise claim them while our panel is merely key.
    func performCustomFieldEdit(_ edit: CustomFieldEdit) {
        guard editingCustom else { return }
        toolbar.performCustomFieldEdit(edit)
    }

    /// Enter in the field: the typed text becomes the chosen intent → stage-2 expansion.
    private func submitCustomInput(_ text: String) {
        editingCustom = false
        inputMonitor?.setCustomEditing(false)
        guard active else { return }
        stage = .preview
        previewCustom(text)
    }

    /// Esc in the field: drop back to the chip strip (the toolbar shrinks itself).
    private func cancelCustomInput() {
        editingCustom = false
        inputMonitor?.setCustomEditing(false)
        stage = .chips
    }

    /// Expand a user-typed custom intent through the same stage-2 path as the chips,
    /// caching the draft under the ✎ index so accept() picks it up unchanged.
    private func previewCustom(_ text: String) {
        let gen = generation
        let provider = replyProvider
        toolbar.showReplyPreview("…")
        Task {
            do {
                let reply = try await cloud.expandReply(
                    intent: text,
                    conversation: conversation,
                    userContext: settings.userContextOrNil,
                    appName: appName,
                    windowTitle: windowTitle,
                    provider: provider,
                    recentMessages: recentMessages,
                    clipboardItems: clipboardItems,
                    prefix: draftPrefix,
                    suffix: draftSuffix,
                    suffixKind: suffixKind,
                    scrollback: scrollback
                )
                guard gen == generation, active else { return }
                expansions[intents.count] = reply
                if toolbar.highlightedReplyChip == intents.count { toolbar.showReplyPreview(reply) }
            } catch {
                guard gen == generation, active else { return }
                toolbar.setReplyPreviewError("Couldn't draft that reply.")
            }
        }
    }

    private func accept() {
        guard stage == .preview, let reply = expansions[toolbar.highlightedReplyChip] else { return }
        toolbar.dropKeyForInsertion()   // if the ✎ field made the panel key, hand focus back before inserting
        if inserter.insert(reply) {
            UsageStatsStore.shared.record(savedText: reply)
        }
        dismiss()
    }

    /// Dismiss if the user clicked outside the reply surface (the badge pill / preview).
    func handleOutsideClick() {
        guard active else { return }
        if toolbar.containsPoint(NSEvent.mouseLocation) { return }
        dismiss()
    }

    func dismiss() {
        generation += 1
        active = false
        stage = .chips
        editingCustom = false
        inputMonitor?.setCustomEditing(false)
        toolbar.endReplyMode()
        inputMonitor?.setReplyActive(false)
    }
}
