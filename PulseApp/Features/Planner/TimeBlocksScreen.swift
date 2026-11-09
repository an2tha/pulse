import PulseEngine
import SwiftUI

extension WeeklyTimeBlock.Role {
    var label: String {
        switch self {
        case .protected: "Protected time"
        case .focus: "Focus time"
        case .boost: "Before focus"
        }
    }
    var symbol: String {
        switch self {
        case .protected: "lock"
        case .focus: "scope"
        case .boost: "leaf"
        }
    }
}

private extension WeeklyTimeBlock {
    var scheduleSummary: String {
        if let date = singleDate() { return date.formatted(date: .abbreviated, time: .omitted) + " · " + hours.formattedClockRange() }
        let starts = firstDate().map { " · From " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        let ends = lastDate().map { " · Through " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return hours.formattedHours() + starts + ends
    }
}

struct TimeBlocksScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    private struct Draft: Identifiable {
        let rule: WeeklyTimeBlock
        let existing: Bool
        var id: UUID { rule.id }
    }
    @State private var editing: Draft?
    var shownAsSheet = false

    var body: some View {
        List {
            let rules = store.journal.timeBlocks ?? []
            ForEach(rules) { block in
                Button { editing = Draft(rule: block, existing: true) } label: {
                    HStack {
                        Image(systemName: block.kind == .protected ? "lock" : "scope").frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.displayTitle).foregroundStyle(Color.journalInk)
                            Text(block.scheduleSummary).font(.subheadline).foregroundStyle(Color.moss)
                        }
                    }.frame(minHeight: 44)
                }
            }.onDelete { offsets in
                let ids = Set(offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil })
                store.change { journal in journal.timeBlocks?.removeAll { ids.contains($0.id) } }
            }
            Button("Add time block", systemImage: "plus") {
                let hours = TaskAvailability(weekdays: Set(2...6), startMinute: 9 * 60, endMinute: 10 * 60)!
                var rule = WeeklyTimeBlock(kind: .protected, hours: hours)
                rule.setFirstDate(.now)
                editing = Draft(rule: rule, existing: false)
            }
        }
        .navigationTitle("Time blocks").navigationBarTitleDisplayMode(.inline).formPaper()
        .toolbar { if shownAsSheet { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        .sheet(item: $editing) { draft in NavigationStack { TimeBlockEditor(block: draft.rule, existing: draft.existing) } }
    }
}

struct TimeBlockEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var rule: WeeklyTimeBlock
    private let original: WeeklyTimeBlock
    private let originallySaved: Bool
    private var onSave: (() -> Void)?
    @State private var chosenDate: Date
    @State private var selectedTask: UUID?
    @State private var savingTask: UUID?
    @State private var saveIssue: String?
    @State private var epoch: UUID?

    init(block: WeeklyTimeBlock, existing: Bool = true) {
        original = block
        originallySaved = existing
        _rule = State(initialValue: block)
        _chosenDate = State(initialValue: block.singleDate() ?? block.firstDate() ?? .now)
    }

    init(newOn day: Date, startHour: Int, onSave: (() -> Void)? = nil) {
        let calendar = Calendar.current
        let now = Date.now
        let currentMinute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let start = calendar.isDate(day, inSameDayAs: now) ? min(1439, (currentMinute / 15 + 1) * 15) : min(23, max(0, startHour)) * 60
        let hours = TaskAvailability(weekdays: [calendar.component(.weekday, from: day)],
                                     startMinute: start, endMinute: (start + 30) % 1440)!
        var block = WeeklyTimeBlock(kind: .focus, hours: hours)
        block.setSingleDate(day)
        self.init(block: block, existing: false)
        self.onSave = onSave
    }

    private func minuteBinding(start: Bool) -> Binding<Int> {
        Binding(get: { start ? rule.hours.startMinute : rule.hours.endMinute }, set: { minute in
            if let hours = TaskAvailability(weekdays: rule.hours.weekdays,
                                            startMinute: start ? minute : rule.hours.startMinute,
                                            endMinute: start ? rule.hours.endMinute : minute) {
                rule.hours = hours
            }
        })
    }

    private var taskDate: Date? {
        if let date = rule.singleDate() { return date }
        let now = Date.now
        if let day = Calendar.current.dateInterval(of: .day, for: now),
           rule.blocks(on: day).contains(where: { $0.start <= now && now < $0.end }) {
            return now
        }
        return rule.nextOpening(after: now)
    }

    var body: some View {
        Form {
            Section {
                Picker("Time block", selection: $rule.kind) {
                    Text("Protected time").tag(WeeklyTimeBlock.Kind.protected)
                    Text("Focus time").tag(WeeklyTimeBlock.Kind.focus)
                }.pickerStyle(.segmented)
                TextField("Name (optional)", text: $rule.title)
            } footer: {
                Text(rule.kind == .protected ? "Pulse keeps this time free of focus sessions." :
                        "Pulse reserves this time for Focus and Study tasks, or an open sprint.")
            }
            if rule.kind == .focus {
                if originallySaved {
                    AssignedFocusTasks(ruleID: rule.id)
                } else {
                    FocusBlockTaskChoice(selection: $selectedTask, rule: rule, occurrence: taskDate)
                }
            }
            Section("Schedule") {
                BlockRepeatFields(rule: $rule, anchor: chosenDate, editingStart: $chosenDate)
                WindowClockFields(startMinute: minuteBinding(start: true), endMinute: minuteBinding(start: false))
                if rule.hours.startMinute == rule.hours.endMinute {
                    Text("24 hours").font(.footnote).foregroundStyle(Color.moss)
                }
            }
            if rule.kind == .focus {
                Picker("Before focus", selection: $rule.boostActivityID) {
                    Text("No activity").tag(Optional<UUID>.none)
                    ForEach(store.energyActivities.filter { $0.kind == .boost }) { activity in
                        Text("\(activity.title) · \(activity.minutes) min").tag(Optional(activity.id))
                    }
                }
                if rule.boostActivityID == nil, let next = rule.nextOpening(after: .now) {
                    PreFocusSuggestionRow(rule: $rule, occurrence: next)
                }
            }
            if let saveIssue { Text(saveIssue).foregroundStyle(Color.clay) }
            if originallySaved {
                Button("Delete time block", role: .destructive) {
                    store.change { $0.timeBlocks?.removeAll { $0.id == rule.id } }
                    dismiss()
                }
            }
        }
        .formPaper().navigationTitle(originallySaved ? "Time block" : "New time block").navigationBarTitleDisplayMode(.inline)
        .onAppear { if epoch == nil { epoch = store.journalEpoch } }
        .onChange(of: selectedTask) { saveIssue = nil }
        .onChange(of: rule.kind) {
            if rule.kind == .protected {
                selectedTask = nil
                saveIssue = nil
            }
        }
        .task(id: savingTask) {
            guard let savingTask else { return }
            defer { self.savingTask = nil }
            guard epoch == store.journalEpoch else {
                saveIssue = "The journal changed. Open the block again."
                return
            }
            guard let taskDate else {
                saveIssue = "Choose an upcoming focus block for this task."
                return
            }
            var saved = rule
            saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try await store.assignTask(savingTask, to: saved, on: taskDate, creating: true)
                if let onSave { onSave() } else { dismiss() }
            } catch {
                saveIssue = error.localizedDescription
            }
        }
        .interactiveDismissDisabled(savingTask != nil)
        .disabled(savingTask != nil)
        .navigationBarBackButtonHidden(onSave != nil || savingTask != nil)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(savingTask != nil) }
            ToolbarItem(placement: .confirmationAction) {
                Button(savingTask == nil ? "Save" : "Saving…") {
                    guard rule.hasOpeningInRange else { saveIssue = "Choose a repeat day inside this date range."; return }
                    guard epoch == store.journalEpoch else {
                        saveIssue = "The journal changed. Open the block again."
                        return
                    }
                    if !originallySaved, rule.kind == .focus, let selectedTask {
                        saveIssue = nil
                        savingTask = selectedTask
                        return
                    }
                    var saved = rule
                    saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if saved.kind == .protected { saved.boostActivityID = nil }
                    store.change { journal in
                        var rules = journal.timeBlocks ?? []
                        if let index = rules.firstIndex(where: { $0.id == saved.id }) {
                            if original.title != saved.title { rules[index].title = saved.title }
                            if original.kind != saved.kind { rules[index].kind = saved.kind }
                            if original.hours != saved.hours { rules[index].hours = saved.hours }
                            if original.singleDay != saved.singleDay || original.firstDay != saved.firstDay || original.lastDay != saved.lastDay {
                                rules[index].setSingleDate(saved.singleDate())
                                rules[index].setFirstDate(saved.firstDate())
                                rules[index].setLastDate(saved.lastDate())
                            }
                            if original.boostActivityID != saved.boostActivityID { rules[index].boostActivityID = saved.boostActivityID }
                            if rules[index].kind == .protected { rules[index].boostActivityID = nil }
                        } else if !originallySaved {
                            rules.append(saved)
                        }
                        journal.timeBlocks = rules
                    }
                    if let onSave { onSave() } else { dismiss() }
                }.disabled(savingTask != nil || rule.title.count > 140 || !store.ready || store.restoring)
            }
        }
    }
}
