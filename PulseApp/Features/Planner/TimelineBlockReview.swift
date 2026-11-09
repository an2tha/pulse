import PulseEngine
import SwiftUI

struct TimelineBlockReview: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let original: WeeklyTimeBlock?
    let onSaved: () -> Void
    private let occurrence: DateInterval
    private let rangeIssue: String?
    @State private var draft: WeeklyTimeBlock?
    @State private var saveIssue: String?
    @State private var epoch: UUID?
    @Binding private var selectedTask: UUID?
    @State private var savingTask: UUID?

    init(kind: WeeklyTimeBlock.Kind, interval: DateInterval, original: WeeklyTimeBlock?, displayedSlice: DateInterval?,
         selectedTask: Binding<UUID?>, onSaved: @escaping () -> Void = {}) {
        _selectedTask = selectedTask
        self.original = original
        self.onSaved = onSaved
        do {
            let proposal = try TimelineBlockProposal(kind: kind, interval: interval, original: original, displayedSlice: displayedSlice)
            occurrence = proposal.occurrence
            _draft = State(initialValue: proposal.rule)
            rangeIssue = nil
        } catch {
            occurrence = interval
            _draft = State(initialValue: nil)
            rangeIssue = error.localizedDescription
        }
    }

    private var opening: Date? {
        guard original == nil, let draft, draft.singleDay == nil else { return occurrence.start }
        return draft.nextOpening(after: occurrence.start.addingTimeInterval(-1))
    }

    private var displayedTime: String {
        if original == nil, let draft, draft.singleDay == nil, let opening {
            return opening.formatted(date: .abbreviated, time: .omitted) + " · " + draft.hours.formattedClockRange()
        }
        let sameDay = Calendar.current.isDate(occurrence.start, inSameDayAs: occurrence.end)
        let start = occurrence.start.formatted(date: .abbreviated, time: .shortened)
        let end = occurrence.end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return start + " – " + end
    }

    var body: some View {
        Form {
            if let rule = Binding($draft) {
                Section {
                    Text(rule.wrappedValue.displayTitle).font(.title2.weight(.medium))
                    Text(displayedTime)
                        .font(.body.monospacedDigit())
                } footer: {
                    if original != nil && rule.wrappedValue.singleDay == nil {
                        Text("Changes every occurrence · " + rule.wrappedValue.hours.formattedHours())
                    }
                }
                if original == nil {
                    Section {
                        BlockRepeatFields(rule: rule, anchor: occurrence.start)
                    }
                }
                if rule.wrappedValue.kind == .focus {
                    if original == nil {
                        FocusBlockTaskChoice(selection: $selectedTask, rule: rule.wrappedValue, occurrence: opening)
                    } else if let original {
                        AssignedFocusTasks(ruleID: original.id, occurrence: occurrence)
                    }
                    Section("Before focus") {
                        if let opening { PreFocusSuggestionRow(rule: rule, occurrence: opening) }
                        Picker("Activity", selection: rule.boostActivityID) {
                            Text("No activity").tag(Optional<UUID>.none)
                            ForEach(store.energyActivities.filter { $0.kind == .boost }) { activity in
                                Text("\(activity.title) · \(activity.minutes) min").tag(Optional(activity.id))
                            }
                        }
                    }
                }
            }
            if let issue = saveIssue ?? rangeIssue { Text(issue).foregroundStyle(Color.journalInk) }
        }
        .formPaper().navigationTitle(original == nil ? "New time block" : "Resize block").navigationBarTitleDisplayMode(.inline)
        .onAppear { if epoch == nil { epoch = store.journalEpoch } }
        .onChange(of: selectedTask) { saveIssue = nil }
        .task(id: savingTask) {
            guard let savingTask, let draft else { return }
            defer { self.savingTask = nil }
            guard epoch == store.journalEpoch else {
                saveIssue = "The journal changed. Open the block again."
                return
            }
            guard let opening else { saveIssue = "Choose an upcoming day for this task."; return }
            do {
                _ = try await store.assignTask(savingTask, to: draft, on: opening, creating: true)
                dismiss()
                onSaved()
            } catch {
                saveIssue = error.localizedDescription
            }
        }
        .interactiveDismissDisabled(savingTask != nil)
        .disabled(savingTask != nil)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(savingTask != nil) }
            ToolbarItem(placement: .confirmationAction) {
                Button(savingTask == nil ? "Save" : "Saving…") {
                    guard let draft, epoch == store.journalEpoch, store.ready, !store.restoring else {
                        saveIssue = "The journal changed. Open the timeline again."
                        return
                    }
                    guard draft.hasOpeningInRange else { saveIssue = "Choose a repeat day inside this date range."; return }
                    if let id = draft.boostActivityID, !store.energyActivities.contains(where: { $0.id == id && $0.kind == .boost }) {
                        saveIssue = "This activity changed. Choose another activity."
                        return
                    }
                    if let original, store.journal.timeBlocks?.first(where: { $0.id == original.id }) != original {
                        saveIssue = "This block changed. Open it again to resize it."
                        return
                    }
                    if original == nil, draft.kind == .focus, let selectedTask {
                        saveIssue = nil
                        savingTask = selectedTask
                        return
                    }
                    store.change { journal in
                        var blocks = journal.timeBlocks ?? []
                        if let i = blocks.firstIndex(where: { $0.id == draft.id }) { blocks[i] = draft }
                        else { blocks.append(draft) }
                        journal.timeBlocks = blocks
                    }
                    dismiss()
                    onSaved()
                }.disabled(savingTask != nil || draft == nil || !store.ready || store.restoring)
                .accessibilityIdentifier("save-timeline-block")
            }
        }
    }
}
