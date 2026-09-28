import Foundation

struct CompletionRequest {
    let prefix: String
    let suffix: String
    let appName: String
    let windowTitle: String
    let provider: String
    let maxTokens: Int
    let requestId: String
    let screenContext: String?
    let userContext: String?
    /// Stable context hoisted to the front of the cloud user message (before
    /// `[APP]`) so that volatile pieces (title spinner, live typing) stay at
    /// the tail and don't invalidate the OpenAI prompt-cache prefix.
    /// Currently populated only for Claude Code, where the scrollback above
    /// the `─────\n❯` input-box border is mostly stable during typing bursts.
    let priorContext: String?
    /// Up to 3 most-recent clipboard text items (most recent first), already
    /// filtered by `ClipboardHistory` for credentials and per-item / total
    /// length caps. Sits before screenContext in the prompt — clipboard
    /// changes less often than screen, so putting it earlier keeps more of
    /// the cache valid through screen-context churn.
    let clipboardItems: [String]?
    /// Up to 3 most-recent sent-message texts (most recent first), captured
    /// by `MessageHistory` on Return + 250ms confirmation or on context
    /// transitions (app/window/empty-field). Sits between clipboard and
    /// screen context in the prompt — close enough to the prefix to weight
    /// next-token prediction toward conversational continuity, far enough
    /// to share clipboard's cache locality.
    let recentMessages: [String]?
    /// When true, the cloud request is built with the 3-in-1 cycle
    /// directive (asks for 3 numbered intent-divergent alternatives) and
    /// the response is parsed into multiple candidates. When false (the
    /// default for typing-triggered primary fetches), the prompt stays
    /// focused on producing a single best continuation — no diversity
    /// directive, no `<|cursor|>` marker, normal max_tokens budget.
    /// Set true by `Engine.triggerCycleRefetch` (B-lazy on ⌥↓ when buffer
    /// has no alternates yet).
    let wantsAlternates: Bool
    /// How the suffix should be presented (set by `MailReplyAdapter` routing in Engine).
    /// `.mailReply(quote:)` only when a mail context was recognized AND an attribution
    /// boundary was parsed from the suffix; everything else (non-mail apps, fresh
    /// composes, mid-draft edits, collapsed-quote web replies) is `.plain`.
    let suffixKind: SuffixKind
}
