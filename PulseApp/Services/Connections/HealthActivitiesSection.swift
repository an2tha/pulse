import PulseEngine
import SwiftUI

struct HealthActivitiesSection: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    var date: Date = .now

    private enum Filter: String, CaseIterable { case boosts = "Boosts", drains = "Drains", history = "History" }
    @State private var filter = Filter.boosts
    @State private var expanded = false
    @State private var historyLimit = 8
    @State private var logging: EnergyActivity?
    @State private var detail: EnergyActivityLog?
    @State private var creating = false

    private var kind: EnergyActivity.Kind { filter == .drains ? .drain : .boost }
    private var logs: [EnergyActivityLog] {
        let end = Calendar.current.dateInterval(of: .day, for: date)?.end ?? date
        return (store.journal.energyActivityLogs ?? []).filter { $0.started < end }
            .sorted { $0.started > $1.started }
    }
    private var entryDate: Date {
        let calendar = Calendar.current
        let now = Date.now
        if calendar.isDate(date, inSameDayAs: now) || date > now { return now }
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        return calendar.date(bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0, second: 0, of: date) ?? date
    }

    var body: some View {
        let history = logs
        let matching = history.filter { $0.activity.kind == kind }
        let end = Calendar.current.dateInterval(of: .day, for: date)?.end ?? date
        let rated = matching.filter { $0.finished.map { $0 < end } == true }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Energy activities").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("health-activities-heading")
                Spacer(minLength: 4)
                Button { creating = true } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }.accessibilityLabel("Create activity")
            }
            Picker("Energy activities", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).environment(\.colorScheme, .dark)
            .onChange(of: filter) { expanded = false; historyLimit = 8 }

            if filter == .history {
                if history.isEmpty {
                    Text("No activities logged yet.").font(.subheadline).foregroundStyle(Color.surface.opacity(0.78))
                }
                ForEach(history.prefix(historyLimit)) { log in entryRow(log) }
                if history.count > historyLimit {
                    Button("Show more entries") { historyLimit += 16 }.frame(minHeight: 44)
                }
            } else {
                if let pending = matching.first(where: { $0.after == nil }) { entryRow(pending) }
                if !rated.isEmpty {
                    HStack {
                        Text("Recent ratings").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("Before → after").font(.caption).foregroundStyle(Color.surface.opacity(0.78))
                    }.padding(.top, 6)
                    ForEach(rated.prefix(3)) { log in comparison(log) }
                }
                let custom = store.journal.customEnergyActivities ?? []
                let choices = (Array(custom.reversed()) + EnergyActivity.presets).filter { $0.kind == kind }
                ForEach(choices.prefix(expanded ? choices.count : 3)) { activity in
                    Button { logging = activity } label: {
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(Color.trailAmber)
                            Text(activity.title).multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            Text("\(activity.minutes) min").font(.caption.monospacedDigit())
                                .foregroundStyle(Color.surface.opacity(0.78))
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Log " + activity.title)
                        .accessibilityValue("\(activity.minutes) minutes")
                }
                if choices.count > 3 {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? "Show fewer" : "All \(choices.count) " + filter.rawValue.lowercased(),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }
            }
        }
        .onChange(of: date) { historyLimit = 8 }
        .sheet(item: $logging) { activity in
            NavigationStack { EnergyActivityLogEditor(activity: activity, started: entryDate) }.tint(.journalAccent)
        }
        .sheet(item: $detail) { log in NavigationStack { ActivityHistoryDetail(id: log.id) }.tint(.journalAccent) }
        .sheet(isPresented: $creating) {
            NavigationStack { ActivityEditor(initial: EnergyActivity(title: "", minutes: 5, kind: kind)) }.tint(.journalAccent)
        }
    }

    private func entryRow(_ log: EnergyActivityLog) -> some View {
        Button { detail = log } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(log.activity.title).font(.subheadline.weight(.medium))
                let rating = log.after.map { "\(log.before) → \($0)" } ?? "Add after rating"
                Text(log.started.formatted(date: .abbreviated, time: .shortened) + " · " + rating)
                    .font(.caption).foregroundStyle(log.after == nil ? Color.trailAmber : Color.surface.opacity(0.78))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func comparison(_ log: EnergyActivityLog) -> some View {
        let after = log.after ?? log.before
        let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        return Button { detail = log } label: {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.activity.title).font(.subheadline).multilineTextAlignment(.leading)
                    Text(log.started, format: .dateTime.month(.abbreviated).day()).font(.caption2)
                        .foregroundStyle(Color.surface.opacity(0.78))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Canvas { context, size in
                    func x(_ n: Int) -> CGFloat { 5 + CGFloat(n) / 10 * (size.width - 10) }
                    let y = size.height / 2
                    func segment(_ begin: CGFloat, _ end: CGFloat, color: Color, width: CGFloat) {
                        var line = Path()
                        line.move(to: CGPoint(x: begin, y: y))
                        line.addLine(to: CGPoint(x: end, y: y))
                        context.stroke(line, with: .color(color), lineWidth: width)
                    }
                    segment(x(0), x(10), color: .surface.opacity(0.25), width: 1)
                    segment(x(log.before), x(after), color: .trailAmber, width: 2)
                    let first = CGRect(x: x(log.before) - 4, y: y - 4, width: 8, height: 8)
                    let last = CGRect(x: x(after) - 3, y: y - 3, width: 6, height: 6)
                    context.stroke(Path(ellipseIn: first), with: .color(.surface), lineWidth: 1.5)
                    context.fill(Path(ellipseIn: last), with: .color(.trailAmber))
                }.frame(width: 80, height: 18).accessibilityHidden(true)
                Text("\(log.before) → \(after)").font(.subheadline.monospacedDigit())
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(log.activity.title + ", " + log.started.formatted(date: .abbreviated, time: .shortened))
            .accessibilityValue("Energy before \(log.before), after \(after), out of ten")
    }
}
