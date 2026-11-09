import Charts
import PulseEngine
import SwiftUI

struct ForecastHistoryScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    @State private var rows: [ForecastComparison] = []
    @State private var loading = true
    private struct Input: Equatable {
        let day: Date
        let records: [DayAheadForecast]
        let reports: [CheckIn]
        let corrections: [EnergyCorrection]
    }

    var body: some View {
        let input = Input(day: Calendar.current.startOfDay(for: store.now), records: store.journal.forecastHistory ?? [],
                          reports: store.journal.reports, corrections: store.journal.energyCorrections ?? [])
        let pairs = rows.filter { $0.observed != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView("No saved forecasts yet", systemImage: "chart.dots.scatter",
                        description: Text("Pulse saves tomorrow’s forecast as it plans your day, once enough check-in history is available."))
                } else {
                    if !pairs.isEmpty {
                        let recent = Array(pairs.prefix(28))
                        if recent.count >= 3 {
                            let errors = recent.compactMap { row in row.observed.map { abs($0 - row.forecast.score) } }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(format(errors.reduce(0, +) / Double(errors.count)) + " points")
                                    .font(.largeTitle.weight(.regular)).monospacedDigit()
                                Text("Average difference across \(errors.count) recorded days")
                                    .font(.subheadline).foregroundStyle(Color.moss)
                            }
                        }
                        Chart(recent) { item in
                            if let observed = item.observed {
                                RuleMark(x: .value("Day", item.forecast.day),
                                         yStart: .value("Forecast", item.forecast.score), yEnd: .value("Recorded", observed))
                                    .foregroundStyle(Color.moss.opacity(0.6))
                                PointMark(x: .value("Day", item.forecast.day), y: .value("Forecast", item.forecast.score))
                                    .symbol { Circle().strokeBorder(Color.clay, lineWidth: 2).frame(width: 12, height: 12) }
                                PointMark(x: .value("Day", item.forecast.day), y: .value("Recorded", observed))
                                    .symbol { Circle().fill(Color.journalInk).frame(width: 6, height: 6) }
                            }
                        }
                        .chartYScale(domain: 0...10)
                        .chartYAxis { AxisMarks(position: .leading, values: [0, 5, 10]) }
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                        .frame(height: 155).accessibilityHidden(true)
                        HStack(spacing: 16) {
                            Label("Forecast", systemImage: "circle").foregroundStyle(Color.clay)
                            Label("Recorded", systemImage: "circle.fill").foregroundStyle(Color.journalInk)
                        }.font(.caption).accessibilityHidden(true)
                    }
                    Text("The first forecast saved the day before is compared with your check-ins and energy updates.")
                        .font(.subheadline).foregroundStyle(Color.moss)
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Divider()
                            let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                                AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
                            layout {
                                Text(dayTitle(row.forecast)).font(.headline)
                                if !type.isAccessibilitySize { Spacer() }
                                Text("Forecast " + format(row.forecast.score) + "/10").font(.subheadline)
                                Text(row.observed.map { "Recorded " + format($0) + "/10" } ??
                                     (row.forecast.day > store.now ? "Upcoming" : row.forecast.end > store.now ? "In progress" : "No check-in"))
                                    .font(.caption).foregroundStyle(Color.moss)
                            }.padding(.vertical, 5)
                        }.accessibilityElement(children: .combine)
                    }
                }
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.background(Color.paper).navigationTitle("Past forecasts").navigationBarTitleDisplayMode(.inline)
        .task(id: input) {
            let now = store.now
            let result = await Task.detached(priority: .userInitiated) {
                ForecastHistory.compare(input.records, reports: input.reports, corrections: input.corrections, now: now)
            }.value
            guard !Task.isCancelled else { return }
            rows = result
            loading = false
        }
    }

    private func format(_ score: Double) -> String { score.formatted(.number.precision(.fractionLength(0...1))) }
    private func dayTitle(_ record: DayAheadForecast) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        return record.day.formatted(style)
    }
}
