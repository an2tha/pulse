import PulseEngine
import SwiftUI

struct WeeklyTimingSheet: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let day: Date?

    private struct SearchKey: Equatable {
        let now: Date
        let sourceDay: Date?
        let energyRevision: Int
    }
    @State private var movedSourceDay: Date?
    @State private var releasedSource = false
    @State private var options: [TaskPlacement] = []
    @State private var selectedStart: Date?
    @State private var loading = true
    @State private var saving = false
    @State private var showImpact = false
    @State private var receipt: String?

    private var calendar: Calendar { .current }
    private var sourceDay: Date? { movedSourceDay ?? (releasedSource ? nil : day) }
    private var task: PlanTask? { store.timingTask(taskID) }
    private var isProjected: Bool { store.projectedRoutines[taskID] != nil && !store.journal.tasks.contains { $0.id == taskID } }
    private var days: [Date] { Set(options.map { calendar.startOfDay(for: $0.start) }).sorted() }
    private var selection: TaskPlacement? { options.first { $0.start == selectedStart } }
    private var selectedDay: Date { calendar.startOfDay(for: selectedStart ?? day ?? store.now) }
    private var hours: [TaskPlacement] { options.filter { calendar.isDate($0.start, inSameDayAs: selectedDay) } }

    var body: some View {
        Form {
            if let task {
                let effective = task.planningCopy(with: store.planningEvents, bufferMinutes: store.preferences.bufferMinutes)
                Section {
                    TaskIconTitle(title: task.title, icon: task.icon).font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                    if isProjected {
                        Text("Available after the previous occurrence. Choose a time before the next one.")
                            .font(.footnote).foregroundStyle(Color.moss)
                    }
                    if let receipt {
                        Text(receipt).font(.subheadline.weight(.medium))
                    } else if let start = effective.plannedStart {
                        LabeledContent("Pinned for", value: fullTime(start))
                    }
                    if let move = store.undoableTimeMove(for: taskID) {
                        Button("Undo time change", systemImage: "arrow.uturn.backward") {
                            if store.undoTimeMove(move) {
                                movedSourceDay = day == nil ? nil : Calendar.current.startOfDay(for: move.sourceDay)
                                selectedStart = nil
                                receipt = "Previous timing restored."
                            }
                        }
                        .accessibilityIdentifier("week-timing-undo")
                    }
                    if let pin = store.releasablePin(for: taskID) {
                        Button(pin.title, systemImage: "pin.slash") {
                            if store.releaseTimePin(pin) {
                                movedSourceDay = nil
                                releasedSource = true
                                selectedStart = nil
                                options = []
                                loading = true
                                showImpact = false
                                receipt = pin.confirmation
                            }
                        }
                    }
                    LabeledContent("Usual energy demand", value: rating(task.energyDemand))
                    if let hours = task.availability { LabeledContent("Available hours", value: hours.formattedHours()) }
                    if let due = effective.due { LabeledContent(task.preparation == nil ? "Due" : "Prep due", value: fullTime(due)) }
                    if effective.plannedStart == nil, let pin = task.plannedStart, task.preparation != nil {
                        Text("The saved time of " + fullTime(pin) + " is too late for this commitment.")
                            .font(.footnote).foregroundStyle(Color.moss)
                    }
                }
                if loading {
                    ProgressView("Checking the week")
                } else if let selection {
                    if let best = options.first(where: \.recommended) {
                        Section {
                            Button { apply(nil) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles").accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Let Pulse pick").font(.headline)
                                        Text(fullTime(best.start) + " · " + best.basisLabel + " " + rating(best.rankingCapacity))
                                            .font(.caption).foregroundStyle(Color.moss)
                                    }
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Let Pulse pick")
                            .accessibilityValue(fullTime(best.start) + ", " + best.basisLabel + " " + rating(best.rankingCapacity))
                            .accessibilityIdentifier("week-timing-pick")
                            if let reason = best.skipTimingReason {
                                Text(reason).font(.footnote).foregroundStyle(Color.moss)
                            }
                            if let due = effective.due {
                                if let finish = best.projectedFinish {
                                    if finish > due {
                                        Label("Projected finish \(fullTime(finish)), after your deadline.", systemImage: "clock")
                                            .font(.footnote).foregroundStyle(Color.moss)
                                    } else if !calendar.isDate(finish, inSameDayAs: best.start) {
                                        LabeledContent("Projected finish", value: fullTime(finish)).font(.footnote)
                                    }
                                } else {
                                    Text("Only part of this task fits in the next seven days.")
                                        .font(.footnote).foregroundStyle(Color.moss)
                                }
                            }
                        }
                    }
                    Section("Available times") {
                        Picker("Day", selection: Binding(get: { selectedDay }, set: { day in
                            selectedStart = options.first { calendar.isDate($0.start, inSameDayAs: day) }?.start
                            receipt = nil
                        })) {
                            ForEach(days, id: \.self) { date in Text(dayLabel(date)).tag(date) }
                        }
                        .accessibilityIdentifier("week-timing-day")
                        Picker("Start time", selection: Binding(get: { selection.start }, set: { start in
                            selectedStart = start
                            receipt = nil
                        })) {
                            ForEach(hours) { option in Text(hourLabel(option.start)).tag(option.start) }
                        }
                        .accessibilityIdentifier("week-timing-hour")
                        if selection.minutes < task.minutes {
                            LabeledContent("First block", value: "\(selection.minutes) of \(task.minutes) min remaining")
                        } else {
                            LabeledContent("Block", value: "\(selection.minutes) min")
                        }
                        if let predicted = selection.forecastScore {
                            LabeledContent(selection.forecastSource == .expected ? "Your expected energy" :
                                            (selection.forecastIsDaily ? "Day forecast" : "Hour forecast"), value: rating(predicted))
                        } else {
                            LabeledContent("Planning capacity", value: rating(selection.capacity))
                            Text("No forecast for this hour.").font(.caption).foregroundStyle(Color.moss)
                        }
                        WeekImpactDisclosure(expanded: $showImpact, taskID: taskID, slot: selection, fullTime: fullTime)
                        Button("Move to " + fullTime(selection.start)) { apply(selection) }
                            .accessibilityIdentifier("week-timing-apply")
                    }
                } else {
                    Text("No available time fits this task in the next seven days.")
                    if let saved = store.journal.tasks.first(where: { $0.id == taskID }) {
                        NavigationLink("Edit scheduling details") { TaskEditor(task: saved) }
                    }
                }
            } else if releasedSource, let receipt {
                Text(receipt)
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "calendar")
            }
        }
        .formPaper().navigationTitle("Week timing").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .task(id: SearchKey(now: store.now, sourceDay: sourceDay, energyRevision: store.healthController.revision)) {
            let pinnedHere = task?.plannedStart.flatMap { pin in
                sourceDay.map { calendar.isDate(pin, inSameDayAs: $0) } != false ? pin : nil
            }
            loading = true
            let result = await store.weekPlacements(for: taskID, sourceDay: sourceDay)
            guard !Task.isCancelled else { return }
            let preferred = selectedStart ?? pinnedHere ?? (releasedSource ? result.first?.originalStart : nil)
            options = result
            selectedStart = result.first { $0.start == preferred }?.start
                ?? result.first { calendar.isDate($0.start, inSameDayAs: preferred ?? sourceDay ?? store.now) }?.start
                ?? result.first?.start
            loading = false
        }
    }

    private func apply(_ placement: TaskPlacement?) {
        guard !saving, !loading else { return }
        saving = true
        Task {
            let moved = await store.moveWeekTask(taskID, day: placement?.start, hour: placement?.start, sourceDay: sourceDay, exactStart: placement != nil)
            if moved, let pin = task?.plannedStart {
                movedSourceDay = calendar.startOfDay(for: pin)
                selectedStart = pin
                receipt = (isProjected ? "Time saved for " : "Scheduled for ") + fullTime(pin) + "."
            } else {
                receipt = "The plan changed. Choose an available time again."
                store.regenerate()
            }
            saving = false
        }
    }

    private func rating(_ score: Double) -> String {
        score.formatted(.number.precision(.fractionLength(0...1))) + " / 10"
    }
    private func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    private func hourLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        // Distinguish both occurrences of the repeated hour on a daylight-saving transition.
        let clockHour = calendar.component(.hour, from: date)
        let repeated = [-3600.0, 3600.0].contains {
            calendar.component(.hour, from: date.addingTimeInterval($0)) == clockHour
        }
        return repeated ? time + " " + (calendar.timeZone.abbreviation(for: date) ?? "") : time
    }
    private func fullTime(_ date: Date) -> String { dayLabel(date) + " · " + hourLabel(date) }
}
