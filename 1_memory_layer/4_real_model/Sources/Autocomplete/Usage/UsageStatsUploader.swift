import Foundation

/// Ships the local usage tally to the relay (write-only sink) so the founder can
/// see aggregate engagement. Fires once on launch and every 6h thereafter,
/// guarded to at most one rollup per local day. The 6h cadence ensures a
/// long-running (never-quit) app still uploads after the day rolls over.
///
/// Uploads anonymous per-day counts only (installId + keystrokes/words saved +
/// app version) — no typed text. Runs for all users, including on-device ones.
@MainActor
final class UsageStatsUploader {
    private let store: UsageStatsStore
    private let cloud: CloudProvider
    private var timer: Timer?

    init(store: UsageStatsStore = .shared, cloud: CloudProvider) {
        self.store = store
        self.cloud = cloud
    }

    func start() {
        Task { await uploadIfNeeded() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.uploadIfNeeded() }
            }
        }
    }

    private func uploadIfNeeded() async {
        let today = store.currentDayKey
        guard store.lastUploadedDay != today else { return }
        let buckets = store.recentBuckets(limit: 31)
        guard !buckets.isEmpty else { return }
        let rollups = buckets.map {
            ["day": $0.day, "keystrokes": $0.stat.keystrokes, "words": $0.stat.words] as [String: Any]
        }
        if await cloud.uploadUsage(rollups: rollups, appVersion: Self.appVersion) {
            store.lastUploadedDay = today
        }
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
