import PulseEngine
import SwiftUI

struct FocusBlockTaskChoice: View {
    @Environment(Workspace.self) private var store
    @Binding var selection: UUID?
    let rule: WeeklyTimeBlock
    let occurrence: Date?

    var body: some View {
        Section {
            NavigationLink {
                FocusBlockTaskPicker(selection: $selection)
            } label: {
                LabeledContent("Task") {
                    Text(selection.map { id in store.journal.tasks.first { $0.id == id }?.title ?? "Task unavailable" } ?? "Choose a task")
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityIdentifier("focus-block-task-choice")
        } footer: {
            if rule.singleDay == nil, selection != nil, let occurrence {
                Text("Scheduled once, on " + occurrence.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) + ".")
            }
        }
    }
}

struct FocusBlockTaskPicker: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UUID?
    var presentedAsSheet = false
    @State private var search = ""

    var body: some View {
        let available = store.journal.tasks.filter {
            !$0.done && $0.archived != true && $0.id != store.journal.active?.taskID &&
                (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
        List {
            Button {
                selection = nil
                dismiss()
            } label: {
                HStack {
                    Text("No task")
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark").accessibilityHidden(true) }
                }.frame(minHeight: 44)
            }
            .accessibilityAddTraits(selection == nil ? .isSelected : [])
            if available.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No open tasks", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                let inbox = available.filter(\.belongsToInbox)
                let other = available.filter { !$0.belongsToInbox }
                if !inbox.isEmpty { Section("Inbox") { taskRows(inbox) } }
                if !other.isEmpty { Section("Other tasks") { taskRows(other) } }
            }
        }
        .formPaper().navigationTitle("Choose a task").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a task")
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func taskRows(_ tasks: [PlanTask]) -> some View {
        ForEach(tasks) { task in
            Button {
                selection = task.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        TaskIconTitle(title: task.title, icon: task.icon).font(.body).multilineTextAlignment(.leading)
                        let duration = "\(task.minutes) min"
                        Text(task.plannedStart.map { duration + " · Scheduled " + $0.formatted(date: .abbreviated, time: .shortened) } ?? duration)
                            .font(.caption).foregroundStyle(Color.moss)
                    }
                    Spacer()
                    if selection == task.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.title)
            .accessibilityValue("\(task.minutes) minutes")
            .accessibilityAddTraits(selection == task.id ? .isSelected : [])
        }
    }
}

struct AssignedFocusTasks: View {
    @Environment(Workspace.self) private var store
    let ruleID: UUID
    var occurrence: DateInterval?

    var body: some View {
        let tasks = store.tasksAssigned(to: ruleID, during: occurrence)
        if !tasks.isEmpty {
            Section("Scheduled tasks") {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                        if let start = task.plannedStart {
                            Text(start.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(Color.moss)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }
}

extension Workspace {
    func tasksAssigned(to ruleID: UUID, during occurrence: DateInterval?) -> [PlanTask] {
        journal.tasks.filter { task in
            guard task.assignedFocusBlockID == ruleID, !task.done, task.archived != true, let start = task.plannedStart else { return false }
            return occurrence.map { $0.start <= start && start < $0.end } ?? true
        }.sorted { ($0.plannedStart ?? .distantFuture) < ($1.plannedStart ?? .distantFuture) }
    }

    func focusTaskSummary(for block: Block) -> String? {
        guard case .timeBlock(let id, .focus) = block.kind else { return nil }
        let tasks = tasksAssigned(to: id, during: DateInterval(start: block.start, end: block.end))
        guard let first = tasks.first else { return nil }
        return tasks.count == 1 ? first.title : first.title + " +\(tasks.count - 1)"
    }
}
