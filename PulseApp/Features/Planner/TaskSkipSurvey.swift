import PulseEngine
import SwiftUI

struct TaskSkipSurvey: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let candidate: TaskSkipCandidate
    @State private var reason: TaskSkipReason?
    @State private var energy: Int?
    @State private var focus: Int?
    @State private var notes = ""
    @State private var showDetails = false
    @State private var issue: String?

    var body: some View {
        Form {
            Section {
                Text(candidate.title).font(.title2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Label(candidate.scheduledStart.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    .font(.subheadline)
            } footer: {
                if candidate.session != nil { Text("Saving the skip ends this focus session and keeps your progress.") }
                if let task = store.journal.tasks.first(where: { $0.id == candidate.taskID }), (task.repeated ?? .once) != .once {
                    Text("Skip this occurrence and keep the next one on its usual schedule.")
                } else {
                    Text("Leave this task unfinished and take it off today’s plan. Pulse can schedule it again from tomorrow.")
                }
            }
            Section("What got in the way?") {
                ForEach(TaskSkipReason.allCases) { option in
                    Button {
                        reason = option
                    } label: {
                        HStack {
                            Text(option.rawValue).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: reason == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(reason == option ? Color.journalAccent : Color.secondary)
                                .accessibilityHidden(true)
                        }.frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reason == option ? .isSelected : [])
                }
            }
            Section {
                if reason == .other {
                    TextField("What happened?", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                rating("Energy", selection: $energy)
                    .accessibilityIdentifier("skip-energy")
                DisclosureGroup("More detail", isExpanded: $showDetails) {
                    rating("Focus", selection: $focus)
                    if reason != .other {
                        TextField("Anything else? (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
                    }
                }
                if notes.count > TaskSkipRecord.noteLimit {
                    Text("Keep your note to \(TaskSkipRecord.noteLimit) characters.").font(.caption).foregroundStyle(Color.clay)
                }
            } footer: {
                Text("Rate how you felt when you skipped, from 0 (low) to 10 (high).")
            }
            if let issue { Text(issue).foregroundStyle(Color.clay).accessibilityLabel(issue) }
        }
        .formPaper()
        .navigationTitle("Skip task").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save skip", action: save)
                    .disabled(reason == nil || energy == nil || notes.count > TaskSkipRecord.noteLimit ||
                              (reason == .other && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("save-task-skip")
            }
        }
    }

    private func rating(_ name: String, selection: Binding<Int?>) -> some View {
        Picker(name, selection: selection) {
            Text("Choose").tag(Int?.none)
            ForEach(0...10, id: \.self) { score in
                Text(score == 0 ? "0 · Low" : score == 10 ? "10 · High" : String(score)).tag(Optional(score))
            }
        }.pickerStyle(.menu)
    }

    private func save() {
        guard let reason, let energy else { return }
        do {
            try store.skipTask(candidate, reason: reason, energy: energy, focus: focus, notes: notes)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

struct TaskSkipDetails: View {
    @Environment(Workspace.self) private var store
    let taskID: UUID
    @State private var survey: TaskSkipCandidate?

    var body: some View {
        let records = (store.journal.taskSkips ?? []).filter { $0.taskID == taskID }
        let candidate = store.skipCandidate(for: taskID)
        if candidate != nil || !records.isEmpty {
            Section {
                if let candidate {
                    Button("Skip for today", systemImage: "forward.end") { survey = candidate }
                }
                if !records.isEmpty {
                    NavigationLink("Skip history (\(records.count))") { TaskSkipHistory(taskID: taskID) }
                }
            }
            .sheet(item: $survey) { candidate in
                NavigationStack { TaskSkipSurvey(candidate: candidate) }
                    .foregroundStyle(Color.journalInk).tint(.journalAccent)
                    .preferredColorScheme(store.sky.interfaceScheme)
            }
        }
    }
}

struct TaskSkipHistory: View {
    @Environment(Workspace.self) private var store
    let taskID: UUID?

    var body: some View {
        let records = (store.journal.taskSkips ?? []).filter { taskID == nil || $0.taskID == taskID }
        let byDay = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.skippedAt) }
        List {
            if records.isEmpty {
                ContentUnavailableView("No skipped tasks", systemImage: "forward.end",
                                       description: Text("When you skip a scheduled task, your reason and energy rating appear here."))
            }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                Section(day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach((byDay[day] ?? []).sorted { $0.skippedAt > $1.skippedAt }) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).font(.headline)
                            Text(record.reason.rawValue)
                            Text("Energy \(record.energy)/10" + (record.focus.map { " · Focus \($0)/10" } ?? ""))
                                .font(.subheadline).foregroundStyle(Color.moss)
                            Text("Scheduled " + record.scheduledStart.formatted(date: .abbreviated, time: .shortened)
                                 + " · Skipped " + record.skippedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(Color.moss)
                            if !record.notes.isEmpty { Text(record.notes).font(.subheadline) }
                        }.padding(.vertical, 4).privacySensitive()
                    }
                }
            }
        }.formPaper().navigationTitle("Skip history")
    }
}

struct DueTaskSkipList: View {
    @Environment(Workspace.self) private var store
    let choose: (TaskSkipCandidate) -> Void

    var body: some View {
        let candidates = store.skipCandidates()
        List {
            if candidates.isEmpty {
                ContentUnavailableView("No tasks to skip", systemImage: "clock",
                                       description: Text("A task can be skipped once its scheduled time arrives."))
            }
            ForEach(candidates) { candidate in
                Button { choose(candidate) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.title).font(.headline)
                        Text(candidate.scheduledStart.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(Color.moss)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.formPaper().navigationTitle("Skip a task").navigationBarTitleDisplayMode(.inline)
    }
}
