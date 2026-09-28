import Foundation

/// How ghost text is split into chunks for progressive disclosure.
/// - progressive: cap grows per chunk (15→30→45→60→75→90→105 wu).
/// - natural:     cap is fixed at 70 wu for every chunk; chunker prefers
///                breaking at any natural punctuation within that window.
enum ChunkingStyle: String {
    case progressive
    case natural
}

@MainActor
final class SettingsManager {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let isEnabled = "autocomplete.isEnabled"
        static let disabledApps = "autocomplete.disabledApps"
        static let activeProvider = "autocomplete.activeProvider"
        static let debounceMs = "autocomplete.debounceMs"
        static let maxSuggestionTokens = "autocomplete.maxSuggestionTokens"
        static let triggerMode = "autocomplete.triggerMode"
        static let isScreenContextEnabled = "autocomplete.screenContextEnabled"
        static let userContext = "autocomplete.userContext"
        static let ghostTextStyle = "autocomplete.ghostTextStyle"
        static let chunkingStyle = "autocomplete.chunkingStyle"
        static let didSeedDefaultDisabledApps = "autocomplete.didSeedDefaultDisabledApps"
        static let isEagerPrefillEnabled = "autocomplete.eagerPrefillEnabled"
        static let isMidDecodeCancelEnabled = "autocomplete.midDecodeCancelEnabled"
        static let isReplyAutoOfferEnabled = "autocomplete.replyAutoOfferEnabled"
    }

    // Apps with their own autocomplete where ours should stay out of the way by default.
    // Seeded once per install; users can re-enable any of these from the menu bar.
    static let defaultDisabledAppBundleIds: [String] = [
        // Apple
        "com.apple.dt.Xcode",
        // JetBrains
        "com.jetbrains.intellij", "com.jetbrains.intellij-EAP",
        "com.jetbrains.intellij.ce", "com.jetbrains.intellij.ce-EAP",
        "com.jetbrains.AppCode",
        "com.jetbrains.PhpStorm", "com.jetbrains.PhpStorm-EAP",
        "com.jetbrains.CLion", "com.jetbrains.CLion-EAP",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm-EAP",
        "com.jetbrains.pycharm.ce", "com.jetbrains.pycharm.ce-EAP",
        "com.jetbrains.goland", "com.jetbrains.goland-EAP",
        "com.jetbrains.rider", "com.jetbrains.rider-EAP",
        "com.jetbrains.rubymine", "com.jetbrains.rubymine-EAP",
        // VS Code family / Electron editors
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        // Android Studio
        "com.google.android.studio", "com.google.android.studio-EAP",
        // Text editors
        "com.sublimetext.2", "com.sublimetext.3",
    ]

    init() {
        // Register defaults
        defaults.register(defaults: [
            Keys.isEnabled: true,
            Keys.disabledApps: [String](),
            Keys.activeProvider: "openai",
            Keys.debounceMs: 300,
            Keys.maxSuggestionTokens: 50,
            Keys.triggerMode: "always",
            Keys.isScreenContextEnabled: true,
            Keys.didSeedDefaultDisabledApps: false,
            Keys.isMidDecodeCancelEnabled: true,
            Keys.isReplyAutoOfferEnabled: true,
        ])
        seedDefaultDisabledAppsIfNeeded()
    }

    private func seedDefaultDisabledAppsIfNeeded() {
        guard !defaults.bool(forKey: Keys.didSeedDefaultDisabledApps) else { return }
        var apps = disabledApps
        apps.formUnion(Self.defaultDisabledAppBundleIds)
        disabledApps = apps
        defaults.set(true, forKey: Keys.didSeedDefaultDisabledApps)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.isEnabled) }
        set { defaults.set(newValue, forKey: Keys.isEnabled) }
    }

    var disabledApps: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledApps) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.disabledApps) }
    }

    var activeProvider: String {
        get { defaults.string(forKey: Keys.activeProvider) ?? "openrouter" }
        set { defaults.set(newValue, forKey: Keys.activeProvider) }
    }

    var debounceMs: Int {
        get { defaults.integer(forKey: Keys.debounceMs) }
        set { defaults.set(newValue, forKey: Keys.debounceMs) }
    }

    var maxSuggestionTokens: Int {
        get { defaults.integer(forKey: Keys.maxSuggestionTokens) }
        set { defaults.set(newValue, forKey: Keys.maxSuggestionTokens) }
    }

    var triggerMode: String {
        get { defaults.string(forKey: Keys.triggerMode) ?? "always" }
        set { defaults.set(newValue, forKey: Keys.triggerMode) }
    }

    var isScreenContextEnabled: Bool {
        get { defaults.bool(forKey: Keys.isScreenContextEnabled) }
        set { defaults.set(newValue, forKey: Keys.isScreenContextEnabled) }
    }

    /// Auto-offer the reply badge after the user idles in a known reply box.
    /// Default on; the badge only appears (no generation) until clicked.
    var isReplyAutoOfferEnabled: Bool {
        get { defaults.bool(forKey: Keys.isReplyAutoOfferEnabled) }
        set { defaults.set(newValue, forKey: Keys.isReplyAutoOfferEnabled) }
    }

    /// Speculative KV-cache prefill on context-settle. Default OFF: deliberately
    /// NOT registered in `init`'s defaults, so an unset value reads false.
    /// Toggle via `defaults write` for live A/B; no Settings UI.
    var isEagerPrefillEnabled: Bool {
        get { defaults.bool(forKey: Keys.isEagerPrefillEnabled) }
        set { defaults.set(newValue, forKey: Keys.isEagerPrefillEnabled) }
    }

    /// Q1 mid-decode cancellation. Default ON (registered `true` in `init`).
    /// Acts as a kill-switch: `defaults write … false` restores the old
    /// run-to-completion behavior. A superseded local decode bails at the next
    /// batch boundary and syncCache reconciles the partial. Validated by
    /// MidDecodeCancelStress (8/8 deterministic bail+recover, 0 drift) + live soak.
    var isMidDecodeCancelEnabled: Bool {
        get { defaults.bool(forKey: Keys.isMidDecodeCancelEnabled) }
        set { defaults.set(newValue, forKey: Keys.isMidDecodeCancelEnabled) }
    }

    var userContext: String {
        get { defaults.string(forKey: Keys.userContext) ?? "" }
        set { defaults.set(newValue, forKey: Keys.userContext) }
    }

    /// Returns the normalized user-context string, or nil when empty.
    /// Mirrors the normalization Engine applies before building a CompletionRequest.
    var userContextOrNil: String? {
        let normalized = TextNormalize.collapsePerLine(userContext)
        return normalized.isEmpty ? nil : normalized
    }

    var ghostTextStyle: String {
        get { defaults.string(forKey: Keys.ghostTextStyle) ?? "gray" }
        set { defaults.set(newValue, forKey: Keys.ghostTextStyle) }
    }

    var chunkingStyle: ChunkingStyle {
        get {
            let raw = defaults.string(forKey: Keys.chunkingStyle) ?? ChunkingStyle.natural.rawValue
            return ChunkingStyle(rawValue: raw) ?? .natural
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.chunkingStyle) }
    }

    // MARK: - Per-App Controls

    func disableForApp(_ bundleId: String) {
        var apps = disabledApps
        apps.insert(bundleId)
        disabledApps = apps
    }

    func enableForApp(_ bundleId: String) {
        var apps = disabledApps
        apps.remove(bundleId)
        disabledApps = apps
    }

    func isAppDisabled(_ bundleId: String) -> Bool {
        disabledApps.contains(bundleId)
    }
}
