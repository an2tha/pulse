import PulseEngine
import SwiftUI

struct WeeklyPracticesScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WeeklyPractice?
    @State private var deleting: WeeklyPractice?

    var body: some View {
        List {
            ForEach(store.journal.practices ?? []) { practice in
                let log = practice.logged(on: store.now)
                let pending = practice.pending(in: store.journal.tasks)
                let count = practice.progress(at: store.now)
                let logTitle: String = if log != nil {
                    "Remove today’s log"
                } else if pending?.canLogPractice(at: store.now) == true {
                    "Complete and log today"
                } else {
                    "Log today"
                }
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(practice.title).font(.headline)
                            Text("\(count) of \(practice.targetDays) \(practice.targetDays == 1 ? "day" : "days") this week")
                                .font(.subheadline).foregroundStyle(Color.moss)
                        }.accessibilityElement(children: .combine)
                        Spacer()
                        Menu {
                            Button("Edit practice") { editing = practice }
                            Button("Delete practice", role: .destructive) { deleting = practice }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                        }.accessibilityLabel("Options for " + practice.title)
                    }
                    Button {
                        toggle(practice.id)
                    } label: {
                        Label(logTitle,
                              systemImage: log != nil ? "arrow.uturn.backward" : "checkmark.circle")
                    }
                    .disabled(pending != nil && pending?.id == store.journal.active?.taskID)
                    .accessibilityIdentifier("practice-log-" + practice.id.uuidString)
                    if pending != nil {
                        Label("In your plan", systemImage: "calendar.badge.checkmark").foregroundStyle(Color.moss)
                    } else if log == nil && count < practice.targetDays {
                        Button("Add a \(practice.minutes) min session to Plan", systemImage: "plus") { plan(practice.id) }
                            .accessibilityIdentifier("practice-plan-" + practice.id.uuidString)
                    }
                } footer: {
                    if log?.taskID != nil { Text("Removing the log keeps your completed task and focus history.") }
                }
            }
            if (store.journal.practices ?? []).isEmpty {
                Text("Choose how many days a week you want to practice. Any day counts.")
                    .foregroundStyle(Color.moss)
            }
            Button("New practice", systemImage: "plus") { editing = WeeklyPractice("") }
        }
        .formPaper().navigationTitle("Weekly practices").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .completionProofSheet()
        .sheet(item: $editing) { practice in
            NavigationStack { PracticeEditor(draft: practice, isNew: practice.title.isEmpty) }.preferredColorScheme(store.sky.interfaceScheme)
        }
        .alert("Delete this practice?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { practice in
            Button("Cancel", role: .cancel) {}
            Button("Delete practice", role: .destructive) {
                store.change { journal in
                    journal.practices?.removeAll { $0.id == practice.id }
                    for index in journal.tasks.indices where journal.tasks[index].practiceID == practice.id {
                        journal.tasks[index].practiceID = nil
                    }
                }
            }
        } message: { _ in Text("This removes the practice and its logs. Scheduled tasks and focus history stay in your journal.") }
    }

    private func toggle(_ id: UUID) {
        let now = Date.now
        if let practice = store.journal.practices?.first(where: { $0.id == id }), practice.logged(on: now) == nil,
           let task = practice.pending(in: store.journal.tasks), task.canLogPractice(at: now),
           store.journal.active?.taskID != task.id, store.requestProofIfNeeded(for: task) { return }
        store.change(celebrateCompletion: true) { journal in
            guard let index = journal.practices?.firstIndex(where: { $0.id == id }), let practice = journal.practices?[index] else { return }
            if practice.logged(on: now) != nil {
                journal.practices?[index].removeLog(on: now)
            } else if let task = practice.pending(in: journal.tasks), task.canLogPractice(at: now),
                      let taskIndex = journal.tasks.firstIndex(where: { $0.id == task.id }) {
                guard journal.active?.taskID != task.id else { return }
                journal.tasks[taskIndex].done = true
            } else {
                journal.practices?[index].log(at: now)
            }
        }
    }

    private func plan(_ id: UUID) {
        store.change { journal in
            guard let practice = journal.practices?.first(where: { $0.id == id }),
                  let task = practice.session(for: .now, tasks: journal.tasks) else { return }
            journal.tasks.append(task)
            journal.starterAvailable = false
        }
    }
}

private extension PlanTask {
    func canLogPractice(at now: Date) -> Bool {
        earliest <= now && (repeated == nil || repeated == .once)
    }
}

private struct PracticeEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: WeeklyPractice
    let isNew: Bool
    var body: some View {
        Form {
            TextField("Practice name", text: $draft.title).accessibilityLabel("Practice name")
            Stepper("\(draft.targetDays) \(draft.targetDays == 1 ? "day" : "days") per week", value: $draft.targetDays, in: 1...7)
            Stepper("\(draft.minutes) min per session", value: $draft.minutes, in: 1...1440)
        }
        .formPaper().navigationTitle("Weekly practice").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    store.change { journal in
                        var practices = journal.practices ?? []
                        if let i = practices.firstIndex(where: { $0.id == draft.id }) {
                            practices[i].title = title
                            practices[i].minutes = draft.minutes
                            practices[i].targetDays = draft.targetDays
                        } else if isNew {
                            draft.title = title
                            practices.append(draft)
                        }
                        journal.practices = practices
                    }
                    dismiss()
                }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
