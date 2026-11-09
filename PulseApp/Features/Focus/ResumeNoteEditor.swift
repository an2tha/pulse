import PulseEngine
import SwiftUI

struct FocusResumeNoteScreen: View {
    @Environment(Workspace.self) private var store
    let session: ActiveSession
    let finishAfterSaving: Bool

    var body: some View {
        if let task = store.journal.tasks.first(where: { $0.id == session.taskID }), sameSession {
            ResumeNoteEditor(note: task.resumeNote, saveTitle: finishAfterSaving ? "Save and finish" : "Save") { text in
                guard sameSession else { return }
                if finishAfterSaving {
                    store.finish(done: false, leavingResumeNote: text)
                } else {
                    store.change { journal in
                        if let index = journal.tasks.firstIndex(where: { $0.id == task.id }) {
                            journal.tasks[index].setResumeNote(text)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("This session has ended", systemImage: "hourglass")
        }
    }

    private var sameSession: Bool {
        store.journal.active?.taskID == session.taskID && store.journal.active?.started == session.started
    }
}

struct ResumeNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var text: String
    let saveTitle: String
    let save: (String) -> Void

    init(note: String?, saveTitle: String, save: @escaping (String) -> Void) {
        _text = State(initialValue: note ?? "")
        self.saveTitle = saveTitle
        self.save = save
    }

    var body: some View {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        Form {
            Section {
                TextField("Where will you pick up?", text: $text, axis: .vertical)
                    .lineLimit(3...7)
                    .focused($editing)
                    .accessibilityLabel("Resume note")
                    .accessibilityIdentifier("resume-note-input")
                    .privacySensitive()
            } footer: {
                if count >= PlanTask.resumeNoteLimit - 20 {
                    Text("\(count) / \(PlanTask.resumeNoteLimit) characters")
                        .foregroundStyle(count > PlanTask.resumeNoteLimit ? Color.clay : Color.moss)
                }
            }
            if !text.isEmpty {
                Button("Clear note", role: .destructive) { text = "" }
            }
        }
        .formPaper()
        .navigationTitle("Resume note").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    save(text)
                    dismiss()
                }.disabled(count > PlanTask.resumeNoteLimit)
            }
        }
        .onAppear { editing = true }
    }
}
