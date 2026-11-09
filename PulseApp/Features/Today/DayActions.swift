import PulseEngine
import SwiftUI

struct QuickCaptureScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    var namingIntention = false
    var focusSession: ActiveSession?
    var resumingSessionID: UUID?
    @State private var resolvedSessionID: UUID?
    @State private var showingDrafts = false
    @State private var inputIssue: String?
    private var isSprint: Bool { focusSession != nil || resumingSessionID != nil }
    private var slot: CaptureDraftSlot? {
        if !isSprint { return .quick }
        return (resumingSessionID ?? resolvedSessionID ?? focusSession?.sessionID).map(CaptureDraftSlot.sprint)
    }
    private var hasRoom: Bool {
        if case .sprint(let id) = slot { return store.captureDrafts.hasRoom(for: id) }
        return slot != nil
    }
    private var choosingNext: Bool { namingIntention && store.canNameIntention }
    private var text: String { slot.map { store.captureDrafts.text(for: $0) } ?? "" }
    @FocusState private var typing: Bool
    @State private var previewWork: Task<Void, Never>?
    @State private var draft: InboxCaptureDraft?
    @State private var reviewedText = ""
    @State private var reviewedReference: CaptureReference?
    private var reference: CaptureReference? { slot.flatMap { store.captureDrafts.reference(for: $0) } }
    private var useLiteral: Bool { slot.map { store.captureDrafts.literal(for: $0) } ?? false }
    private var preview: InboxCaptureDraft? { reviewedText == text && reviewedReference == reference ? draft : nil }
    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.ready && !store.restoring }
    private var saveTitle: String {
        if choosingNext { return "Add as next task" }
        if isSprint && !useLiteral && preview?.task.hasSchedulingInstruction == true { return "Add to plan" }
        return "Add to inbox"
    }
    private var prompt: String {
        if choosingNext { return "What would you like to start?" }
        return isSprint ? "What’s on your mind?" : "Task or distraction"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if hasRoom {
                    TextField(prompt, text: Binding(get: { text }, set: { value in
                        guard let slot, value != text else { return }
                        if store.captureDrafts.setText(value, for: slot) {
                            inputIssue = nil
                            updatePreview(for: value)
                        } else {
                            inputIssue = "This draft can hold up to 64 KB. Add your current text, then capture the rest separately."
                        }
                    }), axis: .vertical)
                        .font(.title2)
                        .lineLimit(2...5).focused($typing).submitLabel(.done).onSubmit(save)
                        .accessibilityIdentifier("quick-capture-input")
                    if let inputIssue { Text(inputIssue).font(.footnote).foregroundStyle(Color.moss) }
                } else if slot != nil {
                    Text("All \(CaptureDrafts.sprintLimit) sprint drafts are in use. Finish or discard a draft to make room.")
                }
                if let draft = preview, draft.interpreted {
                    VStack(alignment: .leading, spacing: 4) {
                        if !useLiteral {
                            Text(draft.task.title).font(.headline)
                            Text(draft.details).font(.subheadline).foregroundStyle(Color.moss)
                                .accessibilityIdentifier("capture-timing")
                        }
                        Button(useLiteral ? "Use suggested details" : "Use exact words instead") {
                            if let slot { store.captureDrafts.toggleLiteral(for: slot) }
                        }.font(.subheadline).frame(minHeight: 44)
                    }
                } else if preview?.unresolved == true {
                    Label("Will save as written, without a time.", systemImage: "text.alignleft")
                        .font(.subheadline).foregroundStyle(Color.moss)
                }
                if hasRoom {
                    Divider()
                    SceneButton(title: saveTitle, icon: "arrow.down.to.line") { save() }
                        .accessibilityIdentifier("save-quick-capture")
                        .disabled(!canSave).opacity(canSave ? 1 : 0.52)
                }
                if (!isSprint || !hasRoom), store.captureDrafts.sprints?.isEmpty == false {
                    Button {
                        typing = false
                        showingDrafts = true
                    } label: {
                        Label("Unfinished sprint drafts", systemImage: "doc.text")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                }
            }
            .padding(26).frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity).background(Color.paper)
        .presentationDetents(type.isAccessibilitySize || showingDrafts || resumingSessionID != nil ? [.large] : [.medium, .large])
        .navigationDestination(isPresented: $showingDrafts) { SprintDraftList() }
        .navigationTitle(choosingNext ? "Your first task" : isSprint ? "Capture distraction" : "Quick capture").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { clearDraft(); dismiss() } label: {
                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Cancel")
                .accessibilityHint("Discard this draft and close capture")
            }
        }
        .onAppear {
            if let focusSession { resolvedSessionID = store.captureSessionID(for: focusSession) }
            if let slot, !text.isEmpty, reference == nil { store.captureDrafts.recoverReference(for: slot) }
            typing = hasRoom
            updatePreview(for: text)
        }
        .onDisappear {
            previewWork?.cancel()
            store.flushCaptureDrafts()
        }
    }

    private func updatePreview(for input: String) {
        previewWork?.cancel()
        guard !input.isEmpty, let reference else {
            reviewedText = ""
            draft = nil
            return
        }
        let events = store.planningEvents
        let distraction = isSprint
        previewWork = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                InboxCaptureDraft(input, at: reference.date, calendar: reference.calendar, commitments: events, distraction: distraction)
            }.value
            guard !Task.isCancelled, text == input, self.reference == reference else { return }
            draft = result
            reviewedReference = reference
            reviewedText = input
        }
    }

    private func save() {
        guard canSave, let slot, let reference, let draft = preview ?? InboxCaptureDraft(text, at: reference.date, calendar: reference.calendar, commitments: store.planningEvents, distraction: isSprint) else { return }
        let task = useLiteral ? draft.literal : draft.task
        guard store.captureTask(task, namingIntention: namingIntention, completing: slot) != nil else { return }
        dismiss()
    }
    private func clearDraft() {
        if let slot { store.captureDrafts.clear(slot); store.flushCaptureDrafts() }
    }
}

private struct SprintDraftList: View {
    @Environment(Workspace.self) private var store

    var body: some View {
        let entries = (store.captureDrafts.sprints ?? [:]).sorted { $0.value.updatedAt > $1.value.updatedAt }
        List {
            ForEach(entries, id: \.key) { id, draft in
                NavigationLink {
                    QuickCaptureScreen(resumingSessionID: id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.text).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(Color.moss)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.formPaper().navigationTitle("Unfinished sprint drafts").navigationBarTitleDisplayMode(.inline)
    }
}

struct SprintCapturesButton: View {
    @Environment(Workspace.self) private var store
    let sessionID: UUID
    var onLandscape = false
    let open: () -> Void

    var body: some View {
        let count = store.journal.tasks.count { $0.capturedDuringSessionID == sessionID } + (store.captureDrafts.sprints?[sessionID] == nil ? 0 : 1)
        if count > 0 {
            Button(action: open) {
                Label(count == 1 ? "Review 1 capture" : "Review \(count) captures", systemImage: "tray")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, onLandscape ? 12 : 0).padding(.vertical, 6)
                    .background(onLandscape ? store.sky.ground : Color.clear, in: Capsule())
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct SprintCapturesScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var timing: PlanTask?
    @State private var prepTask: PlanTask?
    @State private var attachment: PreparationAttachment?

    var body: some View {
        let tasks = store.journal.tasks.filter { $0.capturedDuringSessionID == sessionID }
        List {
            if let draft = store.captureDrafts.sprints?[sessionID] {
                NavigationLink {
                    QuickCaptureScreen(resumingSessionID: sessionID)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "pencil").accessibilityHidden(true)
                            Text("Finish draft").fixedSize(horizontal: false, vertical: true)
                        }.font(.headline)
                        Text(draft.text).lineLimit(2).foregroundStyle(Color.moss)
                    }
                }.accessibilityIdentifier("finish-sprint-draft")
            } else if tasks.isEmpty {
                Text("No captures in this sprint.")
            }
            ForEach(tasks) { task in
                HStack {
                    NavigationLink {
                        TaskEditor(task: task)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(task.title)
                            if task.done || task.archived == true {
                                Text(task.done ? "Completed" : "Archived").font(.caption).foregroundStyle(Color.moss)
                            } else if let link = task.preparation {
                                let title = store.planningEvents.first { $0.id == link.commitmentID }?.title
                                Text(title.map { "Prep for " + $0 } ?? "Linked preparation")
                                    .font(.caption).foregroundStyle(Color.moss)
                            } else if let timing = task.captureTiming ?? task.captureRecurrence() {
                                Text(timing)
                                    .font(.caption).foregroundStyle(Color.moss)
                            } else if task.isInboxOnly {
                                Text("Inbox only").font(.caption).foregroundStyle(Color.moss)
                            }
                        }
                    }
                    if task.isInboxOnly, !task.done, task.archived != true {
                        Button { timing = task } label: {
                            Image(systemName: "calendar.badge.plus")
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                        .accessibilityLabel("Schedule " + task.title)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !task.done, task.archived != true {
                        Button("Find time", systemImage: "calendar.badge.clock") { timing = task }
                    }
                }
                .contextMenu {
                    if !task.done, task.archived != true {
                        Button("Find a time this week", systemImage: "calendar.badge.clock") { timing = task }
                        if task.preparation == nil && !store.planningEvents.isEmpty {
                            Button("Prepare for a commitment", systemImage: "calendar") { prepTask = task }
                        }
                    }
                }
            }
            if let attachment, attachment.id == store.latestPrepAttachmentID,
               tasks.contains(where: { $0.id == attachment.taskID && !$0.done && $0.archived != true
                   && $0.preparation?.sameOccurrence(as: attachment.link) == true && store.journal.active?.taskID != $0.id }) {
                Button("Undo linking task", systemImage: "arrow.uturn.backward") {
                    if store.undoPreparationAttachment(attachment) { self.attachment = nil }
                }
            }
        }
        .formPaper().navigationTitle("Sprint captures")
        .sheet(item: $prepTask) { task in
            NavigationStack {
                TaskCommitmentPicker { link in
                    guard let receipt = store.attachPreparation(taskID: task.id, to: link) else { return false }
                    attachment = receipt
                    return true
                }
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button { prepTask = nil } label: {
                            Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel("Cancel")
                    } }
            }
        }
        .sheet(item: $timing) { task in
            NavigationStack { WeeklyTimingSheet(taskID: task.id, day: nil) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "checkmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Done")
            }
        }
    }
}

struct DayOverviewScreen: View {
    let openFocus: () -> Void
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    var body: some View {
        let day = Calendar.current.dateInterval(of: .day, for: store.now)!
        let completed = store.journal.tasks.filter { $0.done && $0.completedAt.map(day.contains) == true }.count
        let focused = Int(store.journal.sessions.reduce(0) { $0 + $1.seconds(in: day) } / 60)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(greeting).font(.largeTitle.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                let columns = type.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
                columns {
                    reading("Completed today", value: String(completed))
                    reading("Focused", value: "\(focused) min")
                    reading(store.capacityLabel,
                            value: store.capacity.formatted(.number.precision(.fractionLength(1))) + "/10")
                }
                Divider()
                NavigationLink {
                    SpareMomentScreen(onStart: openFocus)
                } label: {
                    overviewLink("Spare moment", symbol: "timer")
                }
                if store.blocks.isEmpty {
                    Text("Open time").foregroundStyle(Color.moss)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Remaining today").font(.headline).padding(.bottom, 10)
                        ForEach(store.blocks) { block in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(block.start, style: .time).font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.moss).frame(minWidth: 50, alignment: .leading)
                                Text(block.title).font(.body)
                            }.padding(.vertical, 6).accessibilityElement(children: .combine)
                        }
                    }
                }
                Divider()
                NavigationLink {
                    DayCloseScreen()
                } label: {
                    overviewLink("Close out today", symbol: "sunset")
                }
                Toggle("Rest for today",
                       isOn: Binding(get: { store.isRestDay }, set: { value in
                           store.change { $0.restDate = value ? .now : nil }
                       }))
                NavigationLink {
                    PlanPreferencesScreen()
                } label: {
                    overviewLink("Planning preferences", symbol: "slider.horizontal.3")
                }
            }.padding(26).frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity).background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func overviewLink(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 24).accessibilityHidden(true)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private func reading(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2)
            Text(label).font(.caption).foregroundStyle(Color.moss)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    var greeting: String {
        let h = Calendar.current.component(.hour, from: store.now)
        let salutation = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        guard let name = store.journal.preferredName, !name.isEmpty else { return salutation }
        return salutation + ", " + name
    }
}

struct FocusSetupScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let initiallyTiny: Bool
    var opened: () -> Void
    @State private var minutes = 1
    @State private var tiny = false
    @State private var firstStep = ""
    var body: some View {
        Form {
            if let (task, block) = store.next, task.id == taskID {
                Section(task.title) {
                    Stepper("\(minutes) min", value: $minutes, in: 1...max(1, block.minutes))
                    Toggle("Tiny first step", isOn: $tiny)
                    if tiny {
                        TextField("First small action", text: $firstStep)
                        Text("Start with up to two minutes.").font(.caption)
                    }
                    Button(tiny ? "Start first step" : "Start focus") {
                        var step: TaskStep?
                        if tiny {
                            let name = firstStep.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            if let saved = task.resumeStep, saved.title == name {
                                step = saved
                            } else {
                                step = task.steps?.first(where: { !$0.done && $0.title == name }) ?? TaskStep(name)
                            }
                        }
                        store.start(task, block: block, minutes: tiny ? min(2, minutes) : minutes, step: step)
                        if store.journal.active != nil {
                            dismiss()
                            opened()
                        }
                    }.disabled(
                        !store.canStart(block)
                            || (tiny && firstStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                Section("Why this task") {
                    Text(store.scheduleExplanation(task, block: block))
                    Button("This fits") {
                        store.recordVote(.fits, task: task)
                        dismiss()
                    }
                    Button("Too much right now") {
                        store.recordVote(.tooMuch, task: task)
                        tiny = true
                        minutes = min(minutes, 2)
                    }
                    Button(store.needsCompletionPhoto(for: task) ? "Complete with photo" : "Mark task complete") {
                        store.markDone(task)
                        if store.pendingCompletionProof == nil { dismiss() }
                    }
                }
            } else {
                Text("Your plan has changed. Return to Today for the next available task.")
            }
        }.formPaper().navigationTitle("Starting point").navigationBarTitleDisplayMode(.inline)
            .completionProofSheet {
                if store.journal.tasks.first(where: { $0.id == taskID })?.done == true { dismiss() }
            }
            .onAppear {
                if let (t, b) = store.next {
                    tiny = initiallyTiny
                    minutes = initiallyTiny ? min(2, b.minutes) : b.minutes
                    firstStep =
                        t.nextSmallStep?.title ?? TaskBreakdown.suggestions(for: t).first
                        ?? t.title
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
}
