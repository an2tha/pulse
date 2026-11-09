import PulseEngine
import SwiftUI

struct PictureEntryForm: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID?
    @State private var selectedID: UUID?
    @State private var initialized = false
    @State private var name = ""
    @State private var caption = ""
    @State private var jpeg: Data?
    @State private var complete = false
    @State private var issue: String?

    private var existing: PlanTask? {
        guard let selectedID else { return nil }
        return store.journal.tasks.first { $0.id == selectedID }
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        jpeg != nil && store.ready && !store.restoring && (selectedID != nil ? existing != nil : !trimmedName.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                if let jpeg, let image = UIImage(data: jpeg) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 235)
                        .frame(maxWidth: .infinity).accessibilityLabel("Selected photo").privacySensitive()
                }
                PhotoInput { data in
                    if JournalPhoto.fits(data, in: store.journal) { jpeg = data; issue = nil }
                    else { issue = "The picture log is full. Remove an older photo and try again." }
                }
            }
            Section {
                if taskID == nil {
                    NavigationLink {
                        PhotoTaskChoice(selected: $selectedID)
                    } label: {
                        LabeledContent("Task", value: existing?.title ?? "New task")
                    }
                } else if let existing {
                    LabeledContent("Task", value: existing.title)
                }
                if selectedID == nil {
                    TextField("Task name", text: $name)
                        .accessibilityIdentifier("picture-task-name").submitLabel(.done)
                } else if existing == nil {
                    Text("This task is no longer available.").foregroundStyle(Color.moss)
                }
                if existing?.done == true {
                    Label("Completed", systemImage: "checkmark.circle").foregroundStyle(Color.moss)
                } else if selectedID == nil || selectedID != store.journal.active?.taskID {
                    Toggle("Mark task complete", isOn: $complete)
                }
            }
            if jpeg != nil {
                Section {
                    TextField("Caption (optional)", text: $caption, axis: .vertical).lineLimit(1...4)
                        .accessibilityLabel("Photo caption")
                }
            }
            if let issue { Text(issue).foregroundStyle(Color.clay) }
        }
        .formPaper().navigationTitle("Add photo").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(complete ? "Save and complete" : "Save photo") { save() }.disabled(!valid)
            }
        }
        .onAppear {
            guard !initialized else { return }
            let activeTask = store.journal.active.flatMap { $0.isOpenSprint ? nil : $0.taskID }
            selectedID = taskID ?? activeTask ?? store.next.flatMap { next in
                store.journal.tasks.first { $0.id == next.0.id }?.id
            } ?? store.journal.tasks.last(where: { $0.archived != true })?.id
            initialized = true
        }
        .onChange(of: selectedID) { complete = false; issue = nil }
    }

    private func save() {
        guard valid, let jpeg else { return }
        guard JournalPhoto.fits(jpeg, in: store.journal) else {
            issue = "The picture log is full. Remove an older photo and try again."
            return
        }
        if complete, selectedID != nil, selectedID == store.journal.active?.taskID {
            issue = "Finish the running session in Focus, or save this photo with the task."
            complete = false
            return
        }
        store.change(celebrateCompletion: complete) { journal in
            var task: PlanTask
            if let selectedID {
                guard let i = journal.tasks.firstIndex(where: { $0.id == selectedID }) else { return }
                if complete { journal.tasks[i].done = true }
                task = journal.tasks[i]
            } else {
                task = PlanTask(trimmedName, minutes: PulseEngine.Category.personal.estimate, category: .personal)
                task.done = complete
                journal.tasks.append(task)
                journal.starterAvailable = false
            }
            let note = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = JournalPhoto(taskID: task.id, title: task.title, completion: task.done, jpeg: jpeg,
                                     caption: note.isEmpty ? nil : note)
            journal.photos = (journal.photos ?? []) + [entry]
        }
        dismiss()
    }
}

private struct PhotoTaskChoice: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: UUID?
    @State private var search = ""
    var body: some View {
        List {
            Section {
                Button("New task", systemImage: "plus") { choose(nil) }
            }
            let tasks = store.journal.tasks.filter {
                $0.archived != true && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
            }
            ForEach([false, true], id: \.self) { done in
                let matching = tasks.filter { $0.done == done }.reversed()
                if !matching.isEmpty {
                    Section(done ? "Completed" : "To do") {
                        ForEach(matching) { task in
                            Button { choose(task.id) } label: {
                                HStack {
                                    Text(task.title)
                                    Spacer()
                                    if task.id == selected { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Find a task")
        .formPaper().navigationTitle("Choose task").navigationBarTitleDisplayMode(.inline)
    }
    private func choose(_ id: UUID?) { selected = id; dismiss() }
}
