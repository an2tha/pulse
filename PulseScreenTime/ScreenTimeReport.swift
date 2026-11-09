import Charts
import DeviceActivity
import ExtensionKit
import SwiftUI

@main struct PulseScreenTimeReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        UsageReport { UsageView(days: $0) }
    }
}

struct UsageDay: Identifiable {
    let date: Date
    var seconds: TimeInterval = 0
    var pickups = 0
    var id: Date { date }
}

nonisolated struct UsageReport: DeviceActivityReportScene {
    let context = DeviceActivityReport.Context("Pulse daily use")
    let content: ([UsageDay]) -> UsageView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> [UsageDay] {
        var days: [Date: UsageDay] = [:]
        for await device in data {
            for await segment in device.activitySegments {
                let date = Calendar.current.startOfDay(for: segment.dateInterval.start)
                var day = days[date] ?? UsageDay(date: date)
                day.seconds += segment.totalActivityDuration
                day.pickups += segment.totalPickupsWithoutApplicationActivity
                for await category in segment.categories {
                    for await app in category.applications { day.pickups += app.numberOfPickups }
                }
                days[date] = day
            }
        }
        return days.values.sorted { $0.date < $1.date }
    }
}

struct UsageView: View {
    let days: [UsageDay]

    var body: some View {
        if days.isEmpty {
            Text("Screen Time has no activity for this period.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(Duration.seconds(days.reduce(0) { $0 + $1.seconds }).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .font(.system(.largeTitle, design: .serif)).accessibilityLabel("Total screen time")
                    .accessibilityValue(Duration.seconds(days.reduce(0) { $0 + $1.seconds }).formatted(.units(allowed: [.hours, .minutes])))
                Text("\(days.reduce(0) { $0 + $1.pickups }) pickups").font(.subheadline)
                if days.count > 1 {
                    Chart(days) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.seconds / 60))
                            .foregroundStyle(.teal).cornerRadius(3)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .frame(height: 120)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
