import PulseEngine
import SwiftUI

struct TaskTimingSheet: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var placements: [TaskPlacement] = []
    @State private var selected: Date?
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?

    private var block: Block? { store.blocks.first { $0.kind == .task(taskID) } }
    private var chosen: TaskPlacement? { placements.first { $0.start == selected } }
    private var recommended: TaskPlacement? { placements.first(where: \.recommended) }

    var body: some View {
        Form {
            if let task = store.offeredTasks.first(where: { $0.id == taskID && !$0.done }) {
                let effective = task.planningCopy(with: store.planningEvents, bufferMinutes: store.preferences.bufferMinutes)
                Section {
                    TaskIconTitle(title: task.title, icon: task.icon).font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                    if let message { Text(message).font(.subheadline.weight(.medium)) }
                    if let move = store.undoableTimeMove(for: taskID) {
                        Button("Undo time change", systemImage: "arrow.uturn.backward") {
                            if store.undoTimeMove(move) { message = "Previous timing restored." }
                        }
                    }
                    if let block {
                        if message == nil {
                            LabeledContent("Scheduled", value: time(block.start) + " · \(block.minutes) min")
                        }
                    }
                    if let pin = store.releasablePin(for: taskID) {
                        Button(pin.title, systemImage: "pin.slash") {
                            if store.releaseTimePin(pin) {
                                selected = nil
                                placements = []
                                loading = true
                                message = pin.confirmation
                            }
                        }
                    }
                }
                Section("Move today") {
                    if loading && placements.isEmpty {
                        ProgressView("Finding available times")
                    } else if placements.isEmpty {
                        Text("No move is available in today’s remaining plan.")
                    } else {
                        if recommended != nil {
                            Button("Let Pulse pick", systemImage: "sparkles") { apply(nil) }
                                .accessibilityIdentifier("timing-pick")
                        }
                        if let selected, let day = Calendar.current.dateInterval(of: .day, for: store.now) {
                            DatePicker("Start time", selection: Binding(get: { selected }, set: { self.selected = $0 }),
                                       in: day.start...day.end.addingTimeInterval(-1), displayedComponents: .hourAndMinute)
                                .accessibilityIdentifier("timing-hour")
                            Button("Schedule for " + time(selected)) { apply(selected) }
                                .accessibilityIdentifier("timing-apply")
                        }
                    }
                }
                Section {
                    NavigationLink("Compare days this week") {
                        WeeklyTimingSheet(taskID: taskID, day: block?.start)
                    }
                    NavigationLink("Edit task") { TaskEditor(task: task) }
                }
                Section {
                    DisclosureGroup("Why this time?") {
                        if let block {
                            Text(placementReason(task, effective: effective, block: block)).font(.subheadline)
                            let capacity = store.preferences.capacity(at: block.start, reports: store.journal.reports, calendar: .current)
                            LabeledContent("Estimated effort", value: "\(task.energyCost(at: capacity)) / 10")
                        }
                        LabeledContent("Usual energy demand", value: rating(task.energyDemand))
                        if let due = effective.due { LabeledContent(task.preparation == nil ? "Due" : "Prep due", value: localTiming(due)) }
                        if let hours = task.availability { LabeledContent("Available hours", value: hours.formattedHours()) }
                        if let block { projectedEnergy(at: block.start) }
                        if let chosen {
                            LabeledContent("Available block", value: "\(chosen.minutes) min")
                            LabeledContent("Planning capacity", value: rating(chosen.capacity))
                        }
                        if let recommended {
                            if let reason = recommended.skipTimingReason {
                                Text(reason).font(.subheadline)
                            }
                            Text("At " + time(recommended.start) + ", " + recommended.basisLabel + " is " + rating(recommended.rankingCapacity) + ".")
                                .font(.caption).foregroundStyle(Color.moss)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "calendar")
            }
        }
        .formPaper()
        .navigationTitle("Task timing").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .disabled(saving)
        .task(id: store.now) { await reload() }
    }

    private func placementReason(_ task: PlanTask, effective: PlanTask, block: Block) -> String {
        if effective.plannedStart == nil, let pin = task.plannedStart, effective.preparation != nil {
            return "The saved time of " + localTiming(pin) + " is too late for this commitment."
        }
        if let pin = effective.plannedStart {
            if block.start > pin.addingTimeInterval(60) {
                return "Pinned for " + time(pin) + ". The next available block starts at " + time(block.start) + "."
            }
            return "Pinned for " + time(pin) + "."
        }
        let buffer = TimeInterval(store.preferences.bufferMinutes * 60)
        let previous = store.blocks.last { $0.end <= block.start && $0.id != block.id }
        var constraints: [String] = []
        if let previous {
            let gap = block.start.timeIntervalSince(previous.end)
            switch previous.kind {
            case .fixed where abs(gap - buffer) < 60:
                constraints.append(buffer > 0 ? "After “" + previous.title + "” and its transition buffer." : "Starts when “" + previous.title + "” ends.")
            case .rest where gap < 60:
                constraints.append("Starts at the end of your break.")
            case .task where gap < 60:
                constraints.append("Follows “" + previous.title + "” on your timeline.")
            default: break
            }
        }
        if let after = task.after, abs(after.timeIntervalSince(block.start)) < 60 {
            constraints.append("Available from " + time(after) + ".")
        }
        constraints.append(store.scheduleExplanation(task, block: block))
        return constraints.joined(separator: " ")
    }

    @ViewBuilder private func projectedEnergy(at date: Date) -> some View {
        if let point = store.energyTimeline.estimate(at: date) {
            LabeledContent("Energy at " + time(date), value: rating(point.score))
            if store.tuning.manualCapacity != nil {
                Text("Your capacity override sets the block length.").font(.caption).foregroundStyle(Color.moss)
            } else if store.preferences.energyTimeline == nil && point.source != .corrected {
                Text("Automatic adjustments are off. Pulse can still use this forecast when you ask it to pick a time.")
                    .font(.caption).foregroundStyle(Color.moss)
            }
        } else {
            Text("No hourly estimate here yet. Pulse uses the available planning capacity.").font(.caption)
                .foregroundStyle(Color.moss)
        }
    }

    private func localTiming(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDate(date, inSameDayAs: store.now) ? .omitted : .abbreviated,
                       time: .shortened)
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private func rating(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " / 10"
    }

    private func reload() async {
        let options = await store.timingOptions(for: taskID)
        guard !Task.isCancelled else { return }
        placements = options
        if selected.map({ !Calendar.current.isDate($0, inSameDayAs: store.now) }) ?? true {
            selected = options.first(where: { option in
                block.map { Calendar.current.isDate(option.start, equalTo: $0.start, toGranularity: .hour) } ?? false
            })?.start ?? options.first?.start
        }
        loading = false
    }

    private func apply(_ selection: Date?) {
        guard !saving else { return }
        saving = true
        Task {
            let start = selection.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970 / 60) * 60) }
            let moved = await store.moveTask(taskID, toHour: start, exact: start != nil)
            if moved, let start = store.journal.tasks.first(where: { $0.id == taskID })?.plannedStart {
                selected = start
                message = "Scheduled for " + time(start) + "."
            } else {
                message = store.blockedDropMessage(taskID: taskID, day: store.now, hour: start, exact: start != nil)
            }
            await reload()
            saving = false
        }
    }
}

extension TaskPlacement {
    var basisLabel: String {
        let basis = switch energyBasis {
        case .expected: "your expected energy"
        case .manual: "your capacity override"
        case .correction: "your energy update"
        case .hour: "hour forecast"
        case .day: "day forecast"
        case .capacity: "planning capacity"
        }
        return inFocusTime ? "Focus time · " + basis : basis
    }
}
