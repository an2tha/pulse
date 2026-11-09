import PulseEngine
import SwiftUI

struct WeeklyReview: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let interval: DateInterval
    var body: some View {
        let range = interval.start..<interval.end
        let history = store.journal.reports.filter { $0.date < interval.end }
        let cal = Calendar.current
        let reports = history.filter { range.contains($0.date) }
        let tasks = store.journal.tasks.filter { $0.completedAt.map { range.contains($0) } == true && $0.done }
        let sessions = store.journal.sessions.filter { $0.seconds(in: interval) > 0 }
        let plans = (store.journal.planHistory ?? []).filter { range.contains($0.day) }
        Form {
            Section(
                (range.lowerBound..<range.upperBound.addingTimeInterval(-1)).formatted(
                    .interval.month(.abbreviated).day().year())
            ) {
                LabeledContent("Completed tasks", value: "\(tasks.count)")
                LabeledContent("Meaningful tasks completed", value: "\(tasks.filter{$0.meaningful==true}.count)")
                LabeledContent("Recorded focus", value: "\(Int(sessions.reduce(0){$0+$1.seconds(in:interval)}/60)) min")
                LabeledContent(
                    "Days with check-ins", value: "\(Set(reports.map{cal.startOfDay(for:$0.date)}).count) / 7")
                ForEach(PulseEngine.Category.allCases, id: \.self) { c in
                    let count = tasks.filter { $0.category == c }.count
                    if count > 0 { LabeledContent(c.rawValue, value: "\(count) completed") }
                }
            }
            Section("Plan and actual") {
                if plans.isEmpty { Text("No saved day plans in this week.") }
                ForEach(plans.sorted { $0.day > $1.day }, id: \.day) { p in
                    let day = cal.dateInterval(of: .day, for: p.day)!
                    let actual = Int(sessions.reduce(0) { $0 + $1.seconds(in: day) } / 60)
                    LabeledContent(
                        p.day.formatted(.dateTime.weekday(.abbreviated)),
                        value: "\(p.minutes) min planned · \(actual) min logged")
                }
                Text(
                    "Planned minutes come from the first saved schedule that day. Focus time counts recorded sessions."
                ).font(.caption)
            }
            Section("Personal rhythm") {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    let sample = reports.filter { (hour..<(hour + 6)).contains(cal.component(.hour, from: $0.date)) }
                    if !sample.isEmpty {
                        LabeledContent(
                            String(format: "%02d:00–%02d:00", hour, (hour + 6) % 24),
                            value:
                                "\((sample.map(\.energy).reduce(0,+)/Double(sample.count)).formatted(.number.precision(.fractionLength(1)))) / 10 · \(sample.count) reports"
                        )
                    }
                }
                if reports.isEmpty { Text("No energy reports this week.") }
                if let change = ReviewStats.longerChange(
                    history, at: min(store.now, interval.end.addingTimeInterval(-1)))
                {
                    Text(
                        "Average reported energy changed by \(change.formatted(.number.sign(strategy:.always()).precision(.fractionLength(1)))) points across the last two 14-day periods."
                    )
                }
            }
            Section("Sleep and recovery") {
                if let pair = ReviewStats.sleepAssociation(history) {
                    Text(
                        "Sleep quality and energy correlation: \(pair.correlation.formatted(.number.precision(.fractionLength(2)))) across \(pair.days) paired days. The cause is unknown."
                    )
                } else {
                    Text("A sleep comparison needs at least five days with paired, varying sleep and energy ratings.")
                }
                let worse = reports.filter { $0.feltWorseAfterActivity == true }
                LabeledContent("Reported feeling worse after activity", value: "\(worse.count)")
                let afterFocus = worse.filter { r in
                    let day = DateInterval(start: cal.startOfDay(for: r.date), end: r.date)
                    return sessions.contains { $0.seconds(in: day) > 0 }
                }
                LabeledContent("With earlier recorded focus that day", value: "\(afterFocus.count)")
            }
            if !reports.isEmpty {
                Section("Check-in history") {
                    ForEach(reports.sorted { $0.date > $1.date }) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            Text("Energy \(Int(r.energy)) · clarity \(Int(r.clarity)) · interest \(Int(r.interest))")
                                .font(.caption)
                            if let note = r.fatigueNote { Text(note).font(.subheadline) }
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
        }.formPaper().navigationTitle("Weekly review")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
