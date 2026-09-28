import Foundation

/// All DPHM tunables, loaded from a user-editable `dphm.yaml`.
///
/// Resolution order:
///   1. `DPHM_CONFIG` environment variable (absolute path) — for experiments.
///   2. `~/Library/Application Support/Autocomplete/dphm.yaml` — written with
///      the default template on first launch so there is always a file to edit.
///
/// The parser handles the subset of YAML the template uses: two-level
/// `section:` / `  key: value` maps, `#` comments, bool/number/string scalars.
public struct DPHMConfig: Sendable {

    // MARK: master switch
    public var enabled = true

    // MARK: hot path (instant habit ghost text)
    /// Show DPHM's instant suggestion while the LLM round-trip is in flight.
    public var hotPathDisplayEnabled = true
    /// Max words in one habit ghost text.
    public var maxSuggestionWords = 4
    /// Fused log-score a first token must clear to display anything.
    public var minDisplayScore = -3.5
    /// Fused log-score required to greedily extend by one more token.
    public var minContinueScore = -2.5
    /// Candidates fetched from each trie per query.
    public var topK = 8
    /// How many chars of buffer tail are tokenized per keystroke.
    public var contextTailChars = 240

    // MARK: shallow fusion weights (Gulcehre 2015 / kNN-LM interpolation)
    public var lambdaLong = 1.0
    public var lambdaSession = 0.7
    public var betaPrefetch = 0.8
    /// Re-rank the cloud's 3-in-1 candidates by habit score (fusion at the
    /// candidate level). Off by default — the cloud already orders by intent.
    public var rerankCloudCandidates = false
    /// Margin (log-space) a candidate must beat candidate[0] by to be promoted.
    public var rerankMargin = 1.0

    // MARK: long-term trie (slow decay = durable habits)
    public var longOrder = 3
    public var longHalfLifeDays = 30.0
    public var pruneFloor = 0.05
    public var pruneIntervalSeconds = 600.0

    // MARK: session trie (fast decay = local burst context)
    public var sessionOrder = 3
    public var sessionHalfLifeMinutes = 15.0

    // MARK: habit lexicon consolidation (decayed count × PMI)
    public var promoteMinCount = 3.0
    public var promoteMinPMI = 1.5
    public var maxPhraseCandidates = 5

    // MARK: speculative prefetch
    public var prefetchEnabled = true
    public var prefetchDebounceMs = 150.0
    /// Ring buffer of recent commits mined by the default lexical retriever.
    public var prefetchRecentCommits = 50
    /// Per-token boost published by the default retriever (log-space units).
    public var prefetchBoostUnit = 0.5

    // MARK: commit weights (learning-signal strength)
    public var weightSentMessage = 1.0
    public var weightAcceptedSuggestion = 0.6

    // MARK: persistence
    public var persistenceEnabled = true
    public var saveIntervalSeconds = 60.0

    public init() {}

    // MARK: - Loading

    public static func resolveConfigURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["DPHM_CONFIG"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Autocomplete/dphm.yaml")
    }

    /// Load from `url` (default: resolved path). Writes the default template
    /// first if no file exists, so users always have something to edit.
    public static func load(from url: URL? = nil) -> DPHMConfig {
        let url = url ?? resolveConfigURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? defaultYAML.write(to: url, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return DPHMConfig()
        }
        return parse(yaml: text)
    }

    // MARK: - Minimal YAML subset parser

    static func parse(yaml: String) -> DPHMConfig {
        var config = DPHMConfig()
        var section = ""
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip comments (naive: template values never contain '#').
            let noComment = rawLine.split(separator: "#", maxSplits: 1,
                                          omittingEmptySubsequences: false)[0]
            let trimmed = noComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { continue }
            let isTopLevel = !(rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t"))
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if isTopLevel && value.isEmpty {
                section = key
                continue
            }
            if isTopLevel { section = "" }
            config.apply(section: section, key: key, value: value)
        }
        return config
    }

    private mutating func apply(section: String, key: String, value: String) {
        func bool() -> Bool? {
            switch value.lowercased() {
            case "true", "yes", "on": return true
            case "false", "no", "off": return false
            default: return nil
            }
        }
        func num() -> Double? { Double(value) }
        func int() -> Int? { Int(value) ?? num().map { Int($0) } }

        switch (section, key) {
        case ("", "enabled"):                           enabled = bool() ?? enabled
        case ("hot_path", "display_enabled"):           hotPathDisplayEnabled = bool() ?? hotPathDisplayEnabled
        case ("hot_path", "max_suggestion_words"):      maxSuggestionWords = int() ?? maxSuggestionWords
        case ("hot_path", "min_display_score"):         minDisplayScore = num() ?? minDisplayScore
        case ("hot_path", "min_continue_score"):        minContinueScore = num() ?? minContinueScore
        case ("hot_path", "top_k"):                     topK = int() ?? topK
        case ("hot_path", "context_tail_chars"):        contextTailChars = int() ?? contextTailChars
        case ("fusion", "lambda_long"):                 lambdaLong = num() ?? lambdaLong
        case ("fusion", "lambda_session"):              lambdaSession = num() ?? lambdaSession
        case ("fusion", "beta_prefetch"):               betaPrefetch = num() ?? betaPrefetch
        case ("fusion", "rerank_cloud_candidates"):     rerankCloudCandidates = bool() ?? rerankCloudCandidates
        case ("fusion", "rerank_margin"):               rerankMargin = num() ?? rerankMargin
        case ("long_term", "order"):                    longOrder = int() ?? longOrder
        case ("long_term", "half_life_days"):           longHalfLifeDays = num() ?? longHalfLifeDays
        case ("long_term", "prune_floor"):              pruneFloor = num() ?? pruneFloor
        case ("long_term", "prune_interval_s"):         pruneIntervalSeconds = num() ?? pruneIntervalSeconds
        case ("session", "order"):                      sessionOrder = int() ?? sessionOrder
        case ("session", "half_life_minutes"):          sessionHalfLifeMinutes = num() ?? sessionHalfLifeMinutes
        case ("habits", "promote_min_count"):           promoteMinCount = num() ?? promoteMinCount
        case ("habits", "promote_min_pmi"):             promoteMinPMI = num() ?? promoteMinPMI
        case ("habits", "max_phrase_candidates"):       maxPhraseCandidates = int() ?? maxPhraseCandidates
        case ("prefetch", "enabled"):                   prefetchEnabled = bool() ?? prefetchEnabled
        case ("prefetch", "debounce_ms"):               prefetchDebounceMs = num() ?? prefetchDebounceMs
        case ("prefetch", "recent_commits"):            prefetchRecentCommits = int() ?? prefetchRecentCommits
        case ("prefetch", "boost_unit"):                prefetchBoostUnit = num() ?? prefetchBoostUnit
        case ("commit", "weight_sent_message"):         weightSentMessage = num() ?? weightSentMessage
        case ("commit", "weight_accepted_suggestion"):  weightAcceptedSuggestion = num() ?? weightAcceptedSuggestion
        case ("persistence", "enabled"):                persistenceEnabled = bool() ?? persistenceEnabled
        case ("persistence", "save_interval_s"):        saveIntervalSeconds = num() ?? saveIntervalSeconds
        default: break
        }
    }

    // MARK: - Default template (kept in sync with the struct defaults)

    public static let defaultYAML = """
    # DPHM (Dual-Path Habit Memory) — FlowIn memory-layer tuning.
    # Edit and restart the app to apply. Delete this file to regenerate defaults.
    # Override location with the DPHM_CONFIG environment variable.

    enabled: true

    hot_path:                        # synchronous, per-keystroke; O(1) lookups only
      display_enabled: true          # show instant habit ghost text while the LLM runs
      max_suggestion_words: 4        # longest habit ghost text, in words
      min_display_score: -3.5        # fused log-score gate for showing anything
      min_continue_score: -2.5       # gate for greedily extending by one more token
      top_k: 8                       # candidates fetched from each trie per query
      context_tail_chars: 240        # buffer tail tokenized per keystroke

    fusion:                          # shallow fusion: score = λ_long·s_long + λ_sess·s_sess + β·prefetch
      lambda_long: 1.0               # weight of long-term habit trie
      lambda_session: 0.7            # weight of session cache trie
      beta_prefetch: 0.8             # weight of the speculative-prefetch boost
      rerank_cloud_candidates: false # re-rank cloud 3-in-1 alternates by habit score
      rerank_margin: 1.0             # log-score margin needed to displace cloud's primary

    long_term:                       # durable habits (slow forgetting)
      order: 3                       # n-gram order
      half_life_days: 30             # Ebbinghaus half-life; recurring patterns survive
      prune_floor: 0.05              # decayed count below this is deleted
      prune_interval_s: 600          # background prune cadence

    session:                         # short-term burst context (fast forgetting)
      order: 3
      half_life_minutes: 15

    habits:                          # phrase promotion (decayed count × PMI)
      promote_min_count: 3.0         # phrase must recur this many (decayed) times
      promote_min_pmi: 1.5           # collocation cohesion threshold
      max_phrase_candidates: 5       # habits considered per anchor token

    prefetch:                        # speculative prefetch (off the keystroke path)
      enabled: true
      debounce_ms: 150               # word-boundary debounce before retrieval fires
      recent_commits: 50             # commit ring buffer mined by the lexical retriever
      boost_unit: 0.5                # per-token boost published (log-space)

    commit:                          # learning-signal strength per source
      weight_sent_message: 1.0       # user's own sent text — strongest habit evidence
      weight_accepted_suggestion: 0.6  # accepted AI text — endorsed, weaker evidence

    persistence:
      enabled: true
      save_interval_s: 60            # min seconds between background snapshots
    """
}
