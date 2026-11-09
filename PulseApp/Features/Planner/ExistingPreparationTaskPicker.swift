import PulseEngine
import SwiftUI

struct ExistingPreparationTaskPicker: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let link: TaskPreparation
    let attached: (PreparationAttachment) -> Void
    @State private var search = ""
    @State private var issue: String?

    var body: some View {
        let matches = store.journal.tasks.filter {
            store.canAttachPreparation($0) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
        let ordered = matches.filter(\.isInboxOnly) + matches.filter { !$0.isInboxOnly }
        List {
            if let issue { Text(issue).foregroundStyle(Color.clay) }
            if ordered.isEmpty {
                if search.isEmpty { ContentUnavailableView("No available tasks", systemImage: "tray") }
                else { ContentUnavailableView.search(text: search) }
            }
            ForEach(ordered) { task in
                Button {
                    if let receipt = store.attachPreparation(taskID: task.id, to: link) {
                        attached(receipt)
                        dismiss()
                    } else {
                        issue = "The task or commitment changed. Choose an available task again."
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(task.isInboxOnly ? "\(task.minutes) min · Inbox only" : "\(task.minutes) min")
                            .font(.caption).foregroundStyle(Color.moss)
                        if let pin = task.plannedStart, let event = link.resolvedStart(in: store.planningEvents),
                           pin >= event.addingTimeInterval(-Double(store.preferences.bufferMinutes) * 60) {
                            Text("Linking will move work before its saved time of " + pin.formatted(date: .abbreviated, time: .shortened) + ".")
                                .font(.footnote).foregroundStyle(Color.moss)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Schedule this task before the commitment")
            }
        }
        .formPaper()
        .searchable(text: $search, prompt: "Find a task")
        .navigationTitle("Link a prep task").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("Cancel")
        } }
    }
}
