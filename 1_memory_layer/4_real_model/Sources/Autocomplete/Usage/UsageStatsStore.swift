import Foundation
import Combine

/// One day's accumulated savings from accepted suggestions and reply drafts.
struct DayStat: Codable, Equatable {
    var keystrokes: Int   // characters inserted on the user's behalf
    var words: Int        // whitespace-delimited tokens in that text
}

/// Which quantity the dashboard plots.
enum UsageMetric: String, CaseIterable, Identifiable {
    case keystrokes, words
    var id: String { rawValue }
    var label: String { self == .keystrokes ? "Keystrokes" : "Words" }
}

/// How day buckets are grouped into bars.
enum UsageGranularity: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// The canonical bucket-start date the given day belongs to.
    func bucketStart(for day: Date, calendar: Calendar) -> Date {
        switch self {
        case .day:   return calendar.startOfDay(for: day)
        case .week:  return calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
        case .month: return calendar.dateInterval(of: .month, for: day)?.start ?? calendar.startOfDay(for: day)
        }
    }
}

/// How far back the chart reaches.
enum UsageRange: String, CaseIterable, Identifiable {
    case days7   = "7 Days"
    case days30  = "30 Days"
    case months3 = "3 Months"
    case year    = "Year"
    case all     = "All"
    var id: String { rawValue }
    var label: String { rawValue }

    /// Inclusive lower bound for the range, or nil for "all time".
    func startDate(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .days7:   return calendar.date(byAdding: .day, value: -6, to: today)
        case .days30:  return calendar.date(byAdding: .day, value: -29, to: today)
        case .months3: return calendar.date(byAdding: .month, value: -3, to: today)
        case .year:    return calendar.date(byAdding: .year, value: -1, to: today)
        case .all:     return nil
        }
    }
}

/// One plotted bar (a bucket's summed metric).
struct UsageBar: Identifiable {
    let date: Date
    let value: Int
    var id: Date { date }
}

/// Local, on-device tally of how much typing FlowIn saved the user. Written
/// from the accept paths (completion + reply), read by the Settings dashboard.
/// Persisted in UserDefaults so it survives launches and version updates.
@MainActor
final class UsageStatsStore: ObservableObject {
    static let shared = UsageStatsStore()

    @Published private(set) var days: [String: DayStat]

    private let defaults = UserDefaults.standard
    private let storeKey = "autocomplete.usageStats.daily"
    private static let lastUploadKey = "autocomplete.usageStats.lastUploadDay"

    /// 'yyyy-MM-dd' in the user's local calendar — the day boundary they experience.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        if let data = defaults.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([String: DayStat].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
    }

    // MARK: - Recording

    /// Count one accepted insertion toward today's savings. `savedText` is
    /// exactly the text inserted on the user's behalf (a completion chunk, a
    /// single word, or a reply draft).
    func record(savedText: String) {
        let chars = savedText.count
        guard chars > 0 else { return }
        let words = savedText.split { $0.isWhitespace }.count
        let key = Self.dayFormatter.string(from: Date())
        var stat = days[key] ?? DayStat(keystrokes: 0, words: 0)
        stat.keystrokes += chars
        stat.words += words
        days[key] = stat
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(days) {
            defaults.set(data, forKey: storeKey)
        }
    }

    // MARK: - Reading

    /// Today's tally so far.
    var todayStat: DayStat {
        days[Self.dayFormatter.string(from: Date())] ?? DayStat(keystrokes: 0, words: 0)
    }

    /// The current local day key ('yyyy-MM-dd').
    var currentDayKey: String { Self.dayFormatter.string(from: Date()) }

    /// The most recent `limit` day buckets (newest first) — the cloud upload
    /// window. Day keys sort chronologically as strings, so this is a top-N.
    func recentBuckets(limit: Int) -> [(day: String, stat: DayStat)] {
        days.sorted { $0.key > $1.key }.prefix(limit).map { (day: $0.key, stat: $0.value) }
    }

    /// Local day key of the last successful cloud upload (nil if never).
    /// Throttles uploads to ~once per local day.
    var lastUploadedDay: String? {
        get { defaults.string(forKey: Self.lastUploadKey) }
        set { defaults.set(newValue, forKey: Self.lastUploadKey) }
    }

    /// Bars for the chart: bucket the chosen range by the chosen granularity,
    /// summing the chosen metric. Ordered oldest → newest.
    func bars(metric: UsageMetric, granularity: UsageGranularity, range: UsageRange) -> [UsageBar] {
        let calendar = Calendar.current
        let start = range.startDate(now: Date(), calendar: calendar)
        let value: (DayStat) -> Int = { metric == .keystrokes ? $0.keystrokes : $0.words }

        var buckets: [Date: Int] = [:]
        for (key, stat) in days {
            guard let day = Self.dayFormatter.date(from: key) else { continue }
            if let start, day < start { continue }
            let bucket = granularity.bucketStart(for: day, calendar: calendar)
            buckets[bucket, default: 0] += value(stat)
        }
        return buckets
            .map { UsageBar(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }
}
