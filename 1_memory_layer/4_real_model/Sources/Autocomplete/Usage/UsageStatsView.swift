import SwiftUI
import Charts

/// Local usage dashboard shown in the Settings window. Reads the shared
/// `UsageStatsStore` and updates live (today's tally) while the window is open.
struct UsageStatsView: View {
    @ObservedObject var store: UsageStatsStore

    @State private var metric: UsageMetric = .keystrokes
    @State private var granularity: UsageGranularity = .day
    @State private var range: UsageRange = .days30

    private var bars: [UsageBar] {
        store.bars(metric: metric, granularity: granularity, range: range)
    }

    /// Up to ~7 evenly-spaced bar dates to label on the x-axis — one per bar
    /// when there are few, thinned out as the range grows so labels stay legible.
    private var axisDates: [Date] {
        let dates = bars.map(\.date)
        guard dates.count > 8 else { return dates }
        let step = Int(ceil(Double(dates.count) / 7.0))
        return dates.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    private func xAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        switch granularity {
        case .day, .week: formatter.setLocalizedDateFormatFromTemplate("Md")
        case .month:      formatter.setLocalizedDateFormatFromTemplate("MMM")
        }
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let today = store.todayStat
            VStack(alignment: .leading, spacing: 2) {
                Text("Today so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(today.keystrokes) keystrokes · \(today.words) words saved")
                    .font(.headline)
            }

            Picker("", selection: $metric) {
                ForEach(UsageMetric.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if bars.isEmpty {
                Text("No usage yet — accept a suggestion to start counting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart(bars) { bar in
                    BarMark(
                        x: .value("Date", bar.date),
                        y: .value(metric.label, bar.value)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(xAxisLabel(date))
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Group by")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $granularity) {
                    ForEach(UsageGranularity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $range) {
                    ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}
