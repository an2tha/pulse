import PulseEngine
import SwiftUI

struct WeekDayTimeSelection: Identifiable {
    let id = UUID()
    let taskID: UUID
    let title: String
    let day: DateInterval
    let source: Date?
    let initial: Date
    let epoch: UUID
}

struct WeekDayTimePicker: View {
    let target: WeekDayTimeSelection
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Date
    @State private var saving = false
    @State private var message: String?
    @State private var alternative: Date?
    @State private var saveRequest: Task<Void, Never>?

    init(target: WeekDayTimeSelection) {
        self.target = target
        _selected = State(initialValue: target.initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(target.title).font(.headline)
                    Text(target.day.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .foregroundStyle(.secondary)
                    DatePicker("Start time", selection: $selected,
                               in: target.day.start...target.day.end.addingTimeInterval(-1),
                               displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("week-exact-start")
                }
                if let message {
                    Section {
                        Text(message).font(.subheadline)
                        if let alternative {
                            Button("Use " + alternative.formatted(date: .omitted, time: .shortened)) { save(alternative) }
                        }
                    }
                }
            }
            .formPaper()
            .navigationTitle("Set time").navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Scheduling…" : "Schedule") { save(selected) }
                        .disabled(saving || target.epoch != store.journalEpoch)
                        .accessibilityIdentifier("week-exact-save")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: selected) { message = nil; alternative = nil }
        .onDisappear { saveRequest?.cancel() }
    }

    private func save(_ time: Date) {
        guard !saving else { return }
        let start = Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / 60) * 60)
        saving = true
        message = nil
        alternative = nil
        saveRequest = Task { @MainActor in
            defer { saving = false }
            guard target.epoch == store.journalEpoch, store.timingTask(target.taskID) != nil else {
                message = "This task is no longer available."
                return
            }
            if !store.calendarReadyForStart { _ = await store.refreshLiveCalendar() }
            guard !Task.isCancelled, target.epoch == store.journalEpoch else { return }
            guard store.calendarReadyForStart else {
                message = "Calendar couldn’t update. Try scheduling again."
                return
            }
            if await store.moveWeekTask(target.taskID, day: target.day.start, hour: start, sourceDay: target.source, exactStart: true) {
                dismiss()
            } else {
                let options = await store.weekPlacements(for: target.taskID, sourceDay: target.source)
                guard !Task.isCancelled, target.epoch == store.journalEpoch else { return }
                message = store.blockedDropMessage(taskID: target.taskID, day: target.day.start, hour: start, exact: true)
                alternative = options.filter { target.day.start <= $0.start && $0.start < target.day.end && $0.start != start }
                    .min { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) }?.start
            }
        }
    }
}
