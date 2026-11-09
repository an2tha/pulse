import PulseEngine
import SwiftUI

struct PreparationPresentation {
    let link: TaskPreparation
    let title: String
    var undoSnapshot: PlanTask?
}

/// Both representations of a fixed block open the same saved occurrence.
struct PlanningEventButton<Label: View>: View {
    @Environment(Workspace.self) private var store
    let block: Block
    @Binding var panel: Panel?
    var editOnTap: Commitment?
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let link = store.preparationLink(for: block, at: store.now) {
            Button {
                if let event = editOnTap {
                    panel = .commitment(event, occurrence: link)
                } else {
                    panel = .preparation(PreparationPresentation(link: link, title: block.title))
                }
            } label: { label() }
            .accessibilityHint(editOnTap == nil ? "Commitment details and preparation" : "Edit commitment and manage preparation")
            .contextMenu {
                if let existing = store.preparationTask(for: link) {
                    Button("Edit prep task", systemImage: "pencil") { panel = .task(existing) }
                } else {
                    Button("Add 10-minute prep", systemImage: "plus") {
                        let existing = store.preparationTask(for: link)
                        let task = existing ?? store.addPreparation(for: link)
                        panel = .preparation(PreparationPresentation(link: link, title: block.title,
                                                                     undoSnapshot: existing == nil ? task : nil))
                    }
                }
                if !store.calendarEvents.contains(where: { $0.id == link.commitmentID }),
                   let local = store.journal.events.first(where: { $0.id == link.commitmentID }) {
                    Button("Edit commitment", systemImage: "calendar") { panel = .commitment(local, occurrence: link) }
                }
            }
        } else if let event = editOnTap {
            Button { panel = .commitment(event) } label: { label() }
        } else {
            label()
        }
    }
}

struct CommitmentPreparationScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let presentation: PreparationPresentation

    var body: some View {
        let link = presentation.link
        let event = store.planningEvents.first { $0.id == link.commitmentID }
        let start = link.resolvedStart(in: store.planningEvents)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(event?.title ?? presentation.title).font(.title2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                LabeledContent(start == nil ? "Last known start" : "Starts",
                               value: (start ?? link.lastKnownStart).formatted(date: .abbreviated, time: .shortened))
                if store.calendarEvents.contains(where: { $0.id == link.commitmentID }) {
                    Label("Apple Calendar", systemImage: "calendar").font(.subheadline).foregroundStyle(Color.moss)
                } else if let local = store.journal.events.first(where: { $0.id == link.commitmentID }) {
                    NavigationLink("Edit commitment") { EventEditor(event: local) }
                }
                Divider().padding(.vertical, 4)
                CommitmentPreparationSection(link: link, undoSnapshot: presentation.undoSnapshot)
            }
            .buttonStyle(PreparationDetailButtonStyle())
            .padding(24).frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color.paper).navigationTitle("Commitment").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "checkmark").font(.headline)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Done")
            }
        }
    }
}

private struct PreparationDetailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.journalAccent)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct CommitmentPreparationSection: View {
    @Environment(Workspace.self) private var store
    let link: TaskPreparation
    var showsOccurrenceStart = false
    @State var undoSnapshot: PlanTask?
    @State private var issue: String?
    @State private var compareTask: PlanTask?
    @State private var choosingTask = false
    @State private var attachment: PreparationAttachment?

    var body: some View {
        let tasks = store.preparationTasks(for: link)
        let start = link.resolvedStart(in: store.planningEvents)
        Section("Preparation") {
            if start != nil || !tasks.isEmpty {
                let occurrenceStart = start ?? link.lastKnownStart
                if showsOccurrenceStart {
                    LabeledContent("This occurrence", value: occurrenceStart.formatted(date: .abbreviated, time: .shortened))
                }
                let cutoff = occurrenceStart.addingTimeInterval(-Double(store.preferences.bufferMinutes) * 60)
                LabeledContent(start == nil ? "Last known prep due" : "Prep due",
                               value: min(tasks.count == 1 ? tasks.first?.due ?? cutoff : cutoff, cutoff).formatted(date: .abbreviated, time: .shortened))
            }
            ForEach(tasks) { task in
                NavigationLink {
                    TaskEditor(task: task)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                        Text(task.done ? "Completed" : "\(task.minutes) min").font(.caption).foregroundStyle(Color.moss)
                    }
                }
                .accessibilityHint("Edit prep task").accessibilityIdentifier(tasks.count == 1 ? "edit-event-prep" : "edit-event-prep-" + task.id.uuidString)
                if !task.done, store.journal.active?.taskID != task.id {
                    Button("Compare times", systemImage: "calendar.badge.clock") { compareTask = task }
                        .accessibilityLabel(tasks.count == 1 ? "Compare days and hours" : "Compare times for " + task.title)
                        .accessibilityIdentifier(tasks.count == 1 ? "compare-event-prep" : "compare-event-prep-" + task.id.uuidString)
                }
            }
            if let snapshot = undoSnapshot, store.canUndoAddedPreparation(snapshot) {
                Button("Undo added prep", systemImage: "arrow.uturn.backward") {
                    if store.undoAddedPreparation(snapshot) { undoSnapshot = nil }
                }
            }
            if tasks.isEmpty, let start, start > store.now {
                Button("Add 10-minute prep", systemImage: "plus") {
                    let existing = store.preparationTask(for: link)
                    if let created = existing ?? store.addPreparation(for: link) {
                        undoSnapshot = existing == nil ? created : nil
                        issue = nil
                    } else {
                        issue = "This commitment is no longer available for preparation."
                    }
                }
                .accessibilityIdentifier("add-event-prep")
            } else if tasks.isEmpty {
                Text(start == nil ? "This occurrence is no longer in Plan." : "This commitment has started.")
                    .font(.subheadline).foregroundStyle(Color.moss)
            }
            if let start, start > store.now, store.journal.tasks.contains(where: store.canAttachPreparation) {
                Button("Link an existing task", systemImage: "link") { choosingTask = true }
                    .accessibilityIdentifier("link-existing-prep")
            }
            if let attachment, attachment.id == store.latestPrepAttachmentID,
               tasks.contains(where: { $0.id == attachment.taskID && !$0.done && store.journal.active?.taskID != $0.id }) {
                Button("Undo linking task", systemImage: "arrow.uturn.backward") {
                    if store.undoPreparationAttachment(attachment) { self.attachment = nil }
                }
            }
            if let issue { Text(issue).font(.subheadline).foregroundStyle(Color.moss) }
        }
        .sheet(isPresented: $choosingTask) {
            NavigationStack {
                ExistingPreparationTaskPicker(link: link) { attachment = $0 }
            }
            .foregroundStyle(Color.journalInk).tint(.journalAccent)
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $compareTask) { task in
            NavigationStack { WeeklyTimingSheet(taskID: task.id, day: nil) }
                .foregroundStyle(Color.journalInk).tint(.journalAccent)
                .presentationDragIndicator(.visible)
        }
    }
}
