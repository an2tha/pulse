import PulseEngine
import SwiftUI

struct TaskEditor: View {
    @Environment(Workspace.self) var store
    @Environment(\.dismiss) var dismiss
    @State var task: PlanTask
    var isNew = false
    var closeAll: (() -> Void)?
    @State private var chooseNext = false
    @State private var original: PlanTask?
    @State private var originallyNext = false
    @State private var saved = false
    @State private var choosingCommitment = false
    @State private var draftPhoto: Data?
    @State private var deleteRequest: TaskDeleteRequest?
    var body: some View {
        Form {
            Section("Task") {
                TaskTitleField(task: $task)
                Picker("Category", selection: $task.category) {
                    ForEach(PulseEngine.Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: task.category) { old, new in
                    if isNew && task.minutes == old.estimate { task.minutes = new.estimate }
                }
                Stepper("\(task.minutes) min", value: $task.minutes, in: 1...1440)
                Toggle("Completed", isOn: $task.done)
                if missingCompletionPhoto {
                    Text("Add a completion photo below to save this task as completed.")
                        .font(.footnote).foregroundStyle(Color.moss)
                    photoInput
                }
            }
            Section("Schedule") {
                TaskRepeatPicker(task: $task)
                optionalDate("Set a start time", date: $task.plannedStart, initialOffset: 900)
                optionalDate("Deadline", date: $task.due)
                optionalDate("Remind me", date: $task.reminder, initialOffset: 900)
                if invalidReminder {
                    Text("Choose a future reminder.").font(.caption).foregroundStyle(Color.clay)
                }
            }
            if let preparation = task.preparation {
                Section("Preparation") {
                    if let event = store.planningEvents.first(where: { $0.id == preparation.commitmentID }) {
                        LabeledContent("Commitment", value: event.title)
                    } else {
                        LabeledContent("Last known start", value: preparation.lastKnownStart.formatted(date: .abbreviated, time: .shortened))
                    }
                    let cutoff = task.planningCopy(with: store.planningEvents, bufferMinutes: store.preferences.bufferMinutes).due
                    if let cutoff { LabeledContent("Prep due", value: cutoff.formatted(date: .abbreviated, time: .shortened)) }
                    if let cutoff, let pin = task.plannedStart, pin >= cutoff {
                        Text("Your time block falls after prep is due. Pulse will look for an earlier opening.")
                            .font(.footnote).foregroundStyle(Color.moss)
                    }
                    Button("Unlink commitment", systemImage: "link.badge.minus") { task.preparation = nil }
                        .accessibilityHint("Save to keep this task without its commitment")
                }
            }
            Section("Placement") {
                if task.inboxOnly != nil && task.plannedStart == nil {
                    Toggle("Include in plan", isOn: Binding(get: { !task.isInboxOnly }, set: { task.inboxOnly = !$0 }))
                }
                if !task.done { Toggle("Schedule first when available", isOn: $chooseNext) }
                if task.preparation == nil, !task.done, task.archived != true,
                   store.journal.active?.taskID != task.id, !store.planningEvents.isEmpty {
                    Button("Prepare for a commitment", systemImage: "calendar.badge.clock") { choosingCommitment = true }
                }
                optionalDate("Start no earlier than", date: $task.after)
                TaskAvailabilityRow(availability: $task.availability)
                if let pin = task.plannedStart, let window = task.availability, window.interval(containing: pin) == nil {
                    Text("This time block is outside your available hours. Pulse will look for an opening after it.")
                        .font(.footnote).foregroundStyle(Color.moss)
                }
                Picker("Depends on", selection: $task.dependency) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(store.journal.tasks.filter { allowsDependency($0) }) { t in
                        Text(t.title).tag(Optional(t.id))
                    }
                }
            }
            if !isNew { TaskSkipDetails(taskID: task.id) }
            Section("Photos") {
                Toggle("Require completion photo", isOn: Binding(
                    get: { task.requiresPhotoProof == true },
                    set: { task.requiresPhotoProof = $0 ? true : nil }))
                    .accessibilityIdentifier("task-photo-proof")
                if task.requiresPhotoProof == true, store.journal.photoProofEnabled == false {
                    Text("Photo requirements are paused in Settings.")
                        .font(.footnote).foregroundStyle(Color.moss)
                }
                if let draftPhoto, let image = UIImage(data: draftPhoto) {
                    Image(uiImage: image).resizable().scaledToFit().privacySensitive()
                    Button("Remove pending photo") { self.draftPhoto = nil }
                }
                if !missingCompletionPhoto {
                    photoInput
                }
                if (store.journal.photos ?? []).contains(where: { $0.taskID == task.id }) {
                    NavigationLink("Task photos") { PictureLogScreen(taskID: task.id) }
                }
            }
            Section { TaskDetails(task: $task) }
            DisclosureGroup("Planning preferences") {
                Meter(title: "Importance", icon: "flag", value: $task.importance)
                Meter(title: "Anticipated effort", icon: "mountain.2", value: $task.effort)
                Meter(title: "Overwhelm", icon: "water.waves", value: $task.overwhelm)
                Meter(title: "Setup effort", icon: "wrench", value: $task.setup)
            }
            if !isNew {
                Button(task.archived == true ? "Return to inbox" : "Archive task") {
                    store.change { j in
                        if let i = j.tasks.firstIndex(where: { $0.id == task.id }) {
                            j.tasks[i].archived = j.tasks[i].archived != true
                        }
                    }
                    close()
                }.disabled(store.journal.active?.taskID == task.id)
            }
            if !isNew, let original {
                Button("Delete task", role: .destructive) {
                    deleteRequest = TaskDeleteRequest(task: original, epoch: store.journalEpoch)
                }.disabled(store.journal.active?.taskID == task.id)
            }
        }.formPaper().navigationTitle(isNew ? "New task" : "Edit task").navigationBarTitleDisplayMode(
            .inline
        )
        .navigationDestination(isPresented: $choosingCommitment) {
            TaskCommitmentPicker { link in
                guard let start = link.resolvedStart(in: store.planningEvents), start > .now else { return false }
                task.preparation = link.refreshed(in: store.planningEvents)
                return true
            }
        }
        .onAppear {
            if original == nil {
                original = task
                originallyNext = store.journal.nextTaskID == task.id
                chooseNext = originallyNext
            }
        }
        .toolbar {
            if !isNew { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!task.hasValidDetails || missingCompletionPhoto || invalidReminder || saved || !store.ready
                              || store.restoring || store.journal.active?.taskID == task.id)
            }
        }
        .modifier(TaskDeleteConfirmation(request: $deleteRequest, onDeleted: close))
    }
    private func save() {
        guard let original, !saved, !missingCompletionPhoto, !invalidReminder, store.ready, !store.restoring,
              store.journal.active?.taskID != task.id else { return }
        let current = store.journal.tasks.first { $0.id == task.id }
        guard isNew || current != nil else {
            store.notice = "This task was removed while it was open."
            close()
            return
        }
        if let draftPhoto, !JournalPhoto.fits(draftPhoto, in: store.journal) {
            store.notice = "Picture log is full. Remove an older photo first."
            return
        }
        var result = task
        if let current {
            result = task.applyingEdits(from: original, to: current, at: .now)
        } else {
            result.originalMinutes = result.minutes
            result.alignFirstRepeatDay(at: .now)
        }
        if let dependency = result.dependency {
            guard let prerequisite = store.journal.tasks.first(where: { $0.id == dependency }), allowsDependency(prerequisite) else {
                store.notice = "The prerequisite changed. Choose another task or remove the dependency."
                return
            }
        }
        if let link = result.preparation, link != original.preparation, task.preparation != original.preparation {
            guard let start = link.resolvedStart(in: store.planningEvents), start > .now else {
                store.notice = "This commitment changed. Choose an upcoming commitment or unlink it before saving."
                return
            }
            result.preparation = link.refreshed(in: store.planningEvents)
        }
        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Returning a task keeps its deadline and reminders. Editing its title must preserve the hold.
        let newlyScheduled = (!original.hasSchedulingInstruction && result.hasSchedulingInstruction)
            || (task.plannedStart != original.plannedStart && result.plannedStart != nil)
            || (task.repeated != original.repeated && (result.repeated ?? .once) != .once)
        if newlyScheduled || (chooseNext && !originallyNext) { result.inboxOnly = nil }
        if result.done, current?.done != true, draftPhoto == nil, store.needsCompletionPhoto(for: result) {
            task.requiresPhotoProof = true
            store.notice = "Add a completion photo before saving."
            return
        }
        saved = true
        store.change(celebrateCompletion: result.done) { journal in
            if let index = journal.tasks.firstIndex(where: { $0.id == result.id }) { journal.tasks[index] = result }
            else { journal.tasks.append(result) }
            if let draftPhoto {
                let photo = JournalPhoto(taskID: result.id, title: result.title, completion: result.done, jpeg: draftPhoto)
                journal.photos = (journal.photos ?? []) + [photo]
            }
            if chooseNext != originallyNext, chooseNext && !result.done {
                journal.nextTaskID = result.id
            } else if ((!chooseNext && originallyNext) || result.done) && journal.nextTaskID == result.id {
                journal.nextTaskID = nil
            }
            journal.starterAvailable = false
        }
        close()
    }

    private var photoInput: some View {
        PhotoInput { data in
            if JournalPhoto.fits(data, in: store.journal) { draftPhoto = data }
            else { store.notice = "Picture log is full. Remove an older photo first." }
        }
    }

    private var missingCompletionPhoto: Bool {
        task.done && original?.done != true && draftPhoto == nil && store.needsCompletionPhoto(for: task)
    }

    private var invalidReminder: Bool {
        guard let reminder = task.reminder, reminder <= .now else { return false }
        return original?.reminder != reminder
    }
    func allowsDependency(_ proposed: PlanTask) -> Bool {
        var next: UUID? = proposed.id
        var visited: Set<UUID> = [task.id]
        while let id = next {
            guard visited.insert(id).inserted else { return false }
            next = store.journal.tasks.first(where: { $0.id == id })?.dependency
        }
        return true
    }
    func close() { if let closeAll { closeAll() } else { dismiss() } }
    @ViewBuilder func optionalDate(
        _ title: String, date: Binding<Date?>, initialOffset: TimeInterval = 0
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { date.wrappedValue != nil },
                set: { date.wrappedValue = $0 ? .now.addingTimeInterval(initialOffset) : nil }))
        if date.wrappedValue != nil {
            DatePicker(
                title,
                selection: Binding(get: { date.wrappedValue ?? .now }, set: { date.wrappedValue = $0 })
            )
            .labelsHidden().accessibilityLabel(title)
        }
    }
}

struct EventEditor: View {
    @Environment(Workspace.self) var store
    @Environment(\.dismiss) var dismiss
    @State var event: Commitment
    var occurrence: TaskPreparation?
    var isNew = false
    var closeAll: (() -> Void)?
    @State var deletion = false
    var body: some View {
        Form {
            Section("Commitment") {
                TextField("Name", text: $event.title)
                DatePicker("Starts", selection: $event.start)
                DatePicker("Ends", selection: $event.end)
                Picker("Repeats", selection: $event.recurrence) {
                    ForEach(Recurrence.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                let overlaps = ScheduleConflicts.overlapping(event, in: store.planningEvents)
                if !overlaps.isEmpty {
                    Text("Overlaps " + overlaps.map(\.title).joined(separator: ", ")).font(.subheadline)
                        .foregroundStyle(Color.clay)
                    Button("Find a free time") {
                        if let free = ScheduleConflicts.nextFree(event, in: store.planningEvents) {
                            event = free
                        } else {
                            store.notice = "No matching opening in the next day. Choose another time."
                        }
                    }
                }
                if event.end <= event.start {
                    Text("Choose an end after the start.").font(.caption).foregroundStyle(Color.clay)
                }
            }
            if let occurrence {
                if let saved = store.journal.events.first(where: { $0.id == event.id }),
                   saved.start != event.start || saved.end != event.end || saved.recurrence != event.recurrence {
                    Section("Preparation") { Text("Save the new time to update preparation.").foregroundStyle(Color.moss) }
                } else {
                    CommitmentPreparationSection(link: occurrence, showsOccurrenceStart: event.recurrence != .once)
                }
            }
            if !isNew { Button("Delete commitment", role: .destructive) { deletion = true } }
        }.formPaper().navigationTitle(isNew ? "New commitment" : "Edit commitment")
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                if !isNew { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.change { j in
                            if let i = j.events.firstIndex(where: { $0.id == event.id }) {
                                j.events[i] = event
                            } else {
                                j.events.append(event)
                            }
                        }
                        close()
                    }.disabled(
                        event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || event.end <= event.start
                            || (event.recurrence != .once && event.end.timeIntervalSince(event.start) >= 86400))
                }
            }
            .confirmationDialog(
                "Delete this commitment?", isPresented: $deletion, titleVisibility: .visible
            ) {
                Button("Delete commitment", role: .destructive) {
                    store.change { $0.events.removeAll { $0.id == event.id } }
                    close()
                }
            }
    }
    func close() { if let closeAll { closeAll() } else { dismiss() } }
}
