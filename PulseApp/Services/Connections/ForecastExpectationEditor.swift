import PulseEngine
import SwiftUI

struct ForecastEditSelection: Identifiable {
    let date: Date
    let scope: EnergyExpectation.Scope
    var proposedScore: Double? = nil
    var id: String { scope.rawValue + String(date.timeIntervalSinceReferenceDate) }
}

extension Workspace {
    @discardableResult
    func setExpectedEnergy(at date: Date, scope: EnergyExpectation.Scope, score: Double?, now clock: Date = .now) -> Bool {
        let calendar = Calendar.current
        guard ready, !restoring,
              let edit = EnergyExpectation(at: date, scope: scope, score: score ?? 0, calendar: calendar),
              let horizon = calendar.date(byAdding: .day, value: EnergyTimeline.forecastDays + 1, to: calendar.startOfDay(for: clock)),
              edit.start > clock, edit.start < horizon else { return false }
        change { journal in
            var remaining = (journal.energyExpectations ?? []).filter {
                let existing = $0.interval(in: calendar)
                return existing.end > clock && !(existing.start == edit.start && existing.end == edit.end && $0.scope == scope)
            }
            if score != nil { remaining.append(edit) }
            journal.energyExpectations = remaining.isEmpty ? nil : remaining
        }
        return true
    }
}

struct ForecastExpectationEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    let selection: ForecastEditSelection
    @State private var scope: EnergyExpectation.Scope
    @State private var hour: Date
    @State private var score: Double = 5
    @State private var issue: String?
    private let calendar = Calendar.current

    init(selection: ForecastEditSelection) {
        self.selection = selection
        _scope = State(initialValue: selection.scope)
        _hour = State(initialValue: Calendar.current.dateInterval(of: .hour, for: selection.date)?.start ?? selection.date)
    }

    private var day: Date { calendar.startOfDay(for: selection.date) }
    private var target: Date { scope == .day ? day : hour }
    private var hours: [Date] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return stride(from: interval.start.timeIntervalSinceReferenceDate, to: interval.end.timeIntervalSinceReferenceDate, by: 3600)
            .map(Date.init(timeIntervalSinceReferenceDate:)).filter { $0 > store.now }
    }
    private var edit: EnergyExpectation? {
        store.journal.energyExpectations?.last { $0.scope == scope && $0.interval(in: calendar).start == target }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if day > store.now {
                        if type.isAccessibilitySize { windowPicker.pickerStyle(.inline) }
                        else { windowPicker.pickerStyle(.segmented) }
                    }
                    if scope == .hour {
                        Picker("Hour", selection: $hour) {
                            ForEach(hours, id: \.self) { time in
                                Text(hourLabel(time)).tag(time)
                            }
                        }.accessibilityIdentifier("expected-energy-hour")
                    }
                } header: { Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day())) }
                Section {
                    let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout())
                    layout {
                        Text("Expected energy")
                        if !type.isAccessibilitySize { Spacer() }
                        Text("\(Int(score)) / 10").font(.title3.monospacedDigit()).foregroundStyle(Color.journalInk)
                    }.accessibilityHidden(true)
                    Slider(value: $score, in: 0...10, step: 1)
                        .accessibilityLabel("Expected energy")
                        .accessibilityValue("\(Int(score)) out of ten")
                        .accessibilityIdentifier("expected-energy-level")
                } footer: {
                    Text("Plan uses this estimate for the selected time. Your check-ins stay in your energy history.")
                }
                if selection.proposedScore != nil, let existing = edit {
                    LabeledContent("Current adjustment", value: existing.score.formatted() + "/10")
                }
                if edit != nil {
                    Button("Remove adjustment", role: .destructive) { save(nil) }
                }
                if let issue { Text(issue).foregroundStyle(Color.clay) }
            }
            .formPaper().navigationTitle("Adjust forecast").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(score) } }
            }
            .onAppear {
                if selection.scope == .day {
                    hour = calendar.date(bySettingHour: store.journal.planningStartHour ?? 9, minute: 0, second: 0, of: day) ?? day
                }
                load()
            }
            .onChange(of: scope) { load() }
            .onChange(of: hour) { load() }
        }.presentationDetents(type.isAccessibilitySize ? [.large] : [.medium, .large])
    }
    private var windowPicker: some View {
        Picker("Window", selection: $scope) {
            Text("Whole day").tag(EnergyExpectation.Scope.day)
            Text("One hour").tag(EnergyExpectation.Scope.hour)
        }.labelsHidden()
    }

    private func hourLabel(_ date: Date) -> String {
        let label = date.formatted(date: .omitted, time: .shortened)
        let repeated = [-3600.0, 3600].contains {
            calendar.component(.hour, from: date) == calendar.component(.hour, from: date.addingTimeInterval($0))
        }
        return repeated ? label + " " + (calendar.timeZone.abbreviation(for: date) ?? "") : label
    }
    private func load() {
        issue = nil
        let suggested = scope == .day ? store.energyTimeline.daily(on: day) : store.energyTimeline.estimate(at: hour)
        let selectedHour = calendar.dateInterval(of: .hour, for: selection.date)?.start
        let proposed = selection.scope == scope && scope == .hour && hour == selectedHour ? selection.proposedScore : nil
        score = min(10, max(0, (proposed ?? edit?.score ?? suggested?.score ?? 5).rounded()))
    }
    private func save(_ value: Double?) {
        if store.setExpectedEnergy(at: target, scope: scope, score: value) { dismiss() }
        else { issue = "This time is no longer in the forecast. Choose an upcoming hour." }
    }
}
