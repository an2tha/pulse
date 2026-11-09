import PulseEngine
import SwiftUI

extension PlanTask {
    var hasValidDetails: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (steps ?? []).allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }
}

struct TaskDetails: View {
    @Environment(Workspace.self) private var store
    @Binding var task: PlanTask
    @State private var newStep = ""
    @State private var templateSaved = false

    var body: some View {
        DisclosureGroup("Energy · \(task.energyCost(at: store.capacity))/10 today") {
            Stepper("Usual demand · \(Int(task.energyDemand.rounded()))/10",
                    value: Binding(get: { Int(task.energyDemand.rounded()) },
                                   set: { task.energyOverride = Double($0) }), in: 0...10)
            if task.energyOverride != nil {
                Button("Use automatic estimate") { task.energyOverride = nil }
            }
        }
        if let url = task.sourceURL {
            Link(destination: url) { Label(url.host ?? "Open source", systemImage: "arrow.up.right.square") }
        }
        DisclosureGroup("Project and notes") {
            TextField("Project", text: text(\.project))
            let projects = Set(
                store.journal.tasks.compactMap(\.project) + (store.journal.goals ?? []).map(\.title)
            ).sorted()
            if !projects.isEmpty {
                Menu("Choose existing project") {
                    ForEach(projects, id: \.self) { project in Button(project) { task.project = project } }
                }
            }
            TextField("Notes", text: text(\.notes), axis: .vertical).lineLimit(2...6)
            NavigationLink {
                ResumeNoteEditor(note: task.resumeNote, saveTitle: "Save") { task.setResumeNote($0) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resume note")
                    if let note = task.resumeNote {
                        Text(note).font(.caption).foregroundStyle(Color.moss).lineLimit(2).privacySensitive()
                    }
                }
            }
            Toggle(
                "Personally meaningful",
                isOn: Binding(get: { task.meaningful == true }, set: { task.meaningful = $0 }))
        }
        DisclosureGroup("Steps\((task.steps ?? []).isEmpty ? "" : " · \(task.steps!.count)")") {
            ForEach(task.steps ?? []) { step in
                HStack {
                    Button {
                        update(step.id) { $0.done.toggle() }
                    } label: {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless).accessibilityLabel(
                        (step.done ? "Reopen " : "Complete ") + step.title)
                    TextField(
                        "Step",
                        text: Binding(
                            get: { task.steps?.first(where: { $0.id == step.id })?.title ?? "" },
                            set: { value in update(step.id) { $0.title = value } }))
                    Button {
                        task.steps?.removeAll { $0.id == step.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless).accessibilityLabel("Remove " + step.title)
                }
            }
            HStack {
                TextField("New step", text: $newStep).onSubmit { append() }
                Button("Add", action: append).disabled(
                    newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if (task.steps ?? []).isEmpty && !task.title.isEmpty {
                Button("Suggest a smaller start") {
                    task.steps = TaskBreakdown.suggestions(for: task).map(TaskStep.init)
                }
            }
        }
        Button(templateSaved ? "Template saved" : "Save as template") {
            store.change { j in
                var items = j.templates ?? []
                items.append(task.duplicate())
                j.templates = items
            }
            templateSaved = true
        }.disabled(templateSaved || !task.hasValidDetails)
    }
    private func text(_ path: WritableKeyPath<PlanTask, String?>) -> Binding<String> {
        Binding(
            get: { task[keyPath: path] ?? "" }, set: { task[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private func append() {
        let value = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        task.steps = (task.steps ?? []) + [TaskStep(value)]
        newStep = ""
    }
    private func update(_ id: UUID, _ action: (inout TaskStep) -> Void) {
        if let i = task.steps?.firstIndex(where: { $0.id == id }) { action(&task.steps![i]) }
    }
}

struct TaskLibrary: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PlanTask?
    var closeAll: () -> Void
    private var builtins: [PlanTask] {
        [
            (
                "Morning routine",
                ["Get a glass of water", "Check the calendar", "Choose one thing for today"],
                Recurrence.daily
            ),
            (
                "Weekly planning", ["Review last week", "Check commitments", "Choose one priority"], .weekly
            ),
            ("Study session", ["Open the material", "Read one section", "Write a question"], .once),
        ].map { name, steps, repeatRule in
            var t = PlanTask(name, minutes: 10, category: .personal)
            t.repeated = repeatRule
            t.steps = steps.map(TaskStep.init)
            return t
        }
    }
    var body: some View {
        List {
            Section("Routines") { ForEach(builtins, id: \.title) { t in row(t) } }
            if let saved = store.journal.templates, !saved.isEmpty {
                Section("Your templates") {
                    ForEach(saved) { t in row(t) }.onDelete { indices in
                        store.change { $0.templates?.remove(atOffsets: indices) }
                    }
                }
            }
        }.formPaper().navigationTitle("Templates").sheet(item: $selected) { item in
            NavigationStack { TaskEditor(task: item, isNew: true, closeAll: closeAll) }
        }
    }
    private func row(_ t: PlanTask) -> some View {
        Button {
            selected = t.duplicate()
        } label: {
            VStack(alignment: .leading) {
                Text(t.title)
                Text("\(t.minutes) min · \(t.captureRecurrence() ?? "Once")").font(.caption).foregroundStyle(
                    Color.moss)
            }
        }
    }
}

struct PlanPreferencesScreen: View {
    @Environment(Workspace.self) private var store
    var body: some View {
        Form {
            Section("Today") {
                Toggle(
                    "Minimum day",
                    isOn: Binding(
                        get: { store.tuning.minimumDay },
                        set: { value in
                            var t = store.tuning
                            t.minimumDay = value
                            store.change { $0.tuning = t }
                        }))
                Text("One flexible task, up to five minutes. Fixed commitments stay in place.").font(
                    .caption)
                Toggle(
                    "Set capacity myself",
                    isOn: Binding(
                        get: { store.tuning.manualCapacity != nil },
                        set: { value in
                            var t = store.tuning
                            t.manualCapacity = value ? store.capacity.rounded() : nil
                            store.change { $0.tuning = t }
                        }))
                if store.tuning.manualCapacity != nil {
                    Stepper(
                        "Capacity · \(Int(store.capacity)) / 10",
                        value: Binding(
                            get: { Int(store.capacity) },
                            set: { v in
                                var t = store.tuning
                                t.manualCapacity = Double(v)
                                store.change { $0.tuning = t }
                            }), in: 0...10)
                } else {
                    LabeledContent(
                        store.capacityLabel,
                        value: store.capacity.formatted(.number.precision(.fractionLength(1))) + " / 10")
                }
            }
            Section("Preferences") {
                TextField(
                    "Name for greetings",
                    text: Binding(
                        get: { store.journal.preferredName ?? "" },
                        set: { v in store.change { $0.preferredName = v } })
                )
                Stepper(
                    "Transition buffer · \(store.journal.bufferMinutes ?? 0) min",
                    value: Binding(
                        get: { store.journal.bufferMinutes ?? 0 },
                        set: { v in store.change { $0.bufferMinutes = v } }),
                    in: 0...30, step: 5)
                Stepper(
                    "Preview days from \(store.journal.planningStartHour ?? 9):00",
                    value: Binding(
                        get: { store.journal.planningStartHour ?? 9 },
                        set: { v in store.change { $0.planningStartHour = v } }), in: 0...23)
                NavigationLink("Time blocks") { TimeBlocksScreen() }
                Toggle("Wrap up by", isOn: Binding(
                    get: { store.journal.wrapUpMinute != nil },
                    set: { enabled in store.change { $0.wrapUpMinute = enabled ? 18 * 60 : nil } }
                ))
                .accessibilityHint("Set a daily end time for planned tasks.")
                if store.journal.wrapUpMinute != nil {
                    DatePicker("End time", selection: wrapUpTime, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, .gmt)
                }
                Toggle(
                    "Continue unfinished tasks first",
                    isOn: Binding(
                        get: { store.journal.continueTask == true },
                        set: { v in store.change { $0.continueTask = v } })
                )
                Toggle(
                    "Rain sound during focus",
                    isOn: Binding(
                        get: { store.journal.ambientSound == true },
                        set: { v in store.change { $0.ambientSound = v } })
                )
            }
        }.formPaper().navigationTitle("Planning preferences")
    }

    // This picker edits a wall-clock minute, independent of the current day's DST transition.
    private var wrapUpTime: Binding<Date> {
        Binding(get: {
            Date(timeIntervalSinceReferenceDate: Double(store.journal.wrapUpMinute ?? 18 * 60) * 60)
        }, set: { date in
            var clock = Calendar(identifier: .gregorian)
            clock.timeZone = .gmt
            let minute = clock.component(.hour, from: date) * 60 + clock.component(.minute, from: date)
            store.change { $0.wrapUpMinute = minute }
        })
    }
}
