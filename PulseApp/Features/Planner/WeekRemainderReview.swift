import PulseEngine
import SwiftUI

/// Work that still needs time after replaying this week, with a direct path to the
/// time chooser or the constraint that the person wants to change.
struct WeekRemainderReview: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var remaining: [WeekRemainder]
    @State private var query = ""
    @State private var destination: Destination?

    private enum Destination: Hashable { case timing(UUID), edit(UUID) }

    var body: some View {
        let tasks = Dictionary(uniqueKeysWithValues: store.journal.tasks.map { ($0.id, $0) })
        List {
            if remaining.isEmpty {
                Text("All the work in this review has a time.")
            }
            ForEach(remaining) { item in
                if let task = tasks[item.id], query.isEmpty || task.title.localizedCaseInsensitiveContains(query) {
                    Button { destination = .timing(task.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title).font(.headline)
                            Text(item.plannedMinutes > 0
                                 ? "\(item.plannedMinutes) min planned · \(item.remainingMinutes) min left"
                                 : "\(item.remainingMinutes) min to place")
                                .font(.subheadline).foregroundStyle(Color.moss)
                            Text(reason(for: item, task: task, tasks: tasks)).font(.footnote)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Compare available days and hours")
                    .swipeActions {
                        Button("Edit", systemImage: "pencil") { destination = .edit(task.id) }
                    }
                    .contextMenu {
                        Button("Edit task", systemImage: "pencil") { destination = .edit(task.id) }
                    }
                }
            }
            if !query.isEmpty && !remaining.contains(where: { tasks[$0.id]?.title.localizedCaseInsensitiveContains(query) == true }) {
                ContentUnavailableView.search(text: query)
            }
        }
        .formPaper()
        .searchable(text: $query, prompt: "Find a task")
        .navigationTitle("Still to schedule").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Image(systemName: "checkmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("Done")
        } }
        .navigationDestination(item: $destination) { route in
            switch route {
            case .timing(let id): WeeklyTimingSheet(taskID: id, day: nil)
            case .edit(let id):
                if let task = store.journal.tasks.first(where: { $0.id == id }) { TaskEditor(task: task) }
                else { ContentUnavailableView("Task unavailable", systemImage: "tray") }
            }
        }
    }

    private func reason(for item: WeekRemainder, task: PlanTask, tasks: [UUID: PlanTask]) -> String {
        switch item.reason {
        case .earliest(let date): return "Available " + date.formatted(date: .abbreviated, time: .shortened)
        case .prerequisite(let id): return tasks[id].map { "After “" + $0.title + "”" } ?? "The prerequisite is unavailable."
        case .preparation(let cutoff): return "Prep must finish by " + cutoff.formatted(date: .abbreviated, time: .shortened)
        case .availability: return task.availability.map { "Available " + $0.formattedHours() } ?? "No opening in the task’s hours."
        case .atCapacity: return "All seven days have reached your daily work limit."
        case .zeroLimit: return "Your daily work limit is zero."
        case .noFurtherBlock: return "No further block in this week’s plan."
        }
    }
}
