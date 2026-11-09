import PulseEngine
import SwiftUI

struct InboxTriageScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    var inboxOnly = false
    @State private var prioritized = false
    @State private var changed = false

    private var candidate: PlanTask? {
        InboxTriage.candidate(tasks: store.journal.tasks, next: store.journal.nextTaskID,
                              active: store.journal.active?.taskID, blocks: store.blocks, now: store.now, inboxOnly: inboxOnly)
    }

    var body: some View {
        Form {
            if let task = candidate, !prioritized {
                Section {
                    TaskIconTitle(title: task.title, icon: task.icon).font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                    Text("\(task.minutes) min · Energy \(task.energyCost(at: store.capacity))/10")
                        .font(.subheadline).foregroundStyle(Color.moss)
                    if let due = task.due {
                        LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Button("Prioritize next", systemImage: "arrow.up.to.line") { decide(.prioritize, task: task) }
                    NavigationLink("Find a time this week") { WeeklyTimingSheet(taskID: task.id, day: nil) }
                    Button("Move to tomorrow", systemImage: "sunrise") { decide(.tomorrow, task: task) }
                    Button("Archive", systemImage: "archivebox") { decide(.archive, task: task) }
                }
            } else if !prioritized {
                Section { Text("No more inbox tasks to review today.") }
            }
            if let receipt = store.journal.inboxUndo,
               let task = store.journal.tasks.first(where: { $0.id == receipt.taskID }),
               InboxTriage.canUndo(receipt, tasks: store.journal.tasks, next: store.journal.nextTaskID, active: store.journal.active?.taskID) {
                Section {
                    Text(result(receipt.action, title: task.title))
                    Button("Undo", systemImage: "arrow.uturn.backward") { undo(receipt) }
                }
            } else if prioritized { Text("Your plan has changed.") }
            if changed { Text("That task has changed. Review the current plan.").font(.footnote) }
        }
        .disabled(store.restoring).formPaper().navigationTitle("Review inbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func result(_ action: InboxTriage.Action, title: String) -> String {
        switch action {
        case .prioritize: "“" + title + "” is first when available."
        case .tomorrow: "“" + title + "” moved to tomorrow."
        case .archive: "“" + title + "” archived."
        }
    }

    private func decide(_ action: InboxTriage.Action, task: PlanTask) {
        guard store.ready, !store.restoring else { return }
        var accepted = false
        store.change { journal in
            if let receipt = InboxTriage.apply(action, to: task.id, tasks: &journal.tasks,
                                               next: &journal.nextTaskID, active: journal.active?.taskID, now: .now) {
                journal.inboxUndo = receipt
                accepted = true
            }
        }
        prioritized = accepted && action == .prioritize
        changed = !accepted
    }

    private func undo(_ receipt: InboxTriage.Receipt) {
        guard store.ready, !store.restoring else { return }
        var restored = false
        store.change { journal in
            guard journal.inboxUndo == receipt else { return }
            restored = InboxTriage.undo(receipt, tasks: &journal.tasks, next: &journal.nextTaskID, active: journal.active?.taskID)
            journal.inboxUndo = nil
        }
        prioritized = false
        changed = !restored
    }
}
