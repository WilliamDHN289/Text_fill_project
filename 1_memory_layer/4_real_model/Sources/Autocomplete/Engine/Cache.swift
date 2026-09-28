import Foundation

@MainActor
final class SuggestionCache {
    private var cachedSuggestion: String?
    private var cachedPrefix: String?
    private var cachedAppBundleId: String?
    private var cacheTimestamp: TimeInterval = 0
    private let timeoutInterval: TimeInterval = 15.0

    struct CacheHit {
        let remainingSuggestion: String
        /// Number of characters typed since the cache was stored.
        /// 0 for `tryExactMatch` (no chars typed since store).
        let typedSinceCacheCount: Int
    }

    /// Try to advance the cache with a new character typed
    func tryAdvance(newPrefix: String, appBundleId: String) -> CacheHit? {
        guard let suggestion = cachedSuggestion,
              let oldPrefix = cachedPrefix,
              cachedAppBundleId == appBundleId,
              !isExpired() else {
            return nil
        }

        // Check if the new prefix is the old prefix + beginning of the cached suggestion
        guard newPrefix.hasPrefix(oldPrefix) else {
            return nil
        }

        let typedSinceCache = String(newPrefix.dropFirst(oldPrefix.count))

        // Check if what was typed matches the beginning of the cached suggestion
        guard suggestion.hasPrefix(typedSinceCache) else {
            return nil
        }

        // Advance: return the remaining part of the suggestion
        let remaining = String(suggestion.dropFirst(typedSinceCache.count))
        if remaining.isEmpty {
            invalidate()
            return nil
        }

        return CacheHit(remainingSuggestion: remaining, typedSinceCacheCount: typedSinceCache.count)
    }

    /// Try to match the cache exactly (e.g., caret returned to original position)
    func tryExactMatch(prefix: String, appBundleId: String) -> CacheHit? {
        guard let suggestion = cachedSuggestion,
              let oldPrefix = cachedPrefix,
              cachedAppBundleId == appBundleId,
              oldPrefix == prefix,
              !isExpired() else {
            return nil
        }
        return CacheHit(remainingSuggestion: suggestion, typedSinceCacheCount: 0)
    }

    /// Store a new suggestion in cache
    func store(suggestion: String, prefix: String, appBundleId: String) {
        cachedSuggestion = suggestion
        cachedPrefix = prefix
        cachedAppBundleId = appBundleId
        cacheTimestamp = ProcessInfo.processInfo.systemUptime
    }

    /// Invalidate the cache
    func invalidate() {
        cachedSuggestion = nil
        cachedPrefix = nil
        cachedAppBundleId = nil
    }

    private func isExpired() -> Bool {
        ProcessInfo.processInfo.systemUptime - cacheTimestamp > timeoutInterval
    }
}
