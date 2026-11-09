import PulseEngine
import SwiftUI

struct DayCloseScreen: View {
    @Environment(Workspace.self) private var store
    @State private var selected = Set<UUID>()
    @State private var confirmationDay: Date?
    @State private var message: String?
    @State private var saving = false
    @State private var unsavedCount: Int?

    private var day: DateInterval { Calendar.current.dateInterval(of: .day, for: store.now)! }

    private func plannedIDs(on day: DateInterval) -> Set<UUID> {
        let saved =
            store.journal.planHistory?.filter { $0.day >= day.start && $0.day < day.end }
            .flatMap(\.tasks) ?? []
        let current: [UUID] = store.blocks.compactMap { block in
            guard block.start < day.end, block.end > day.start, case .task(let id) = block.kind else { return nil }
            return id
        }
        return Set(saved + current)
    }

    var body: some View {
        let planned = plannedIDs(on: day)
        let candidates = DayClose.candidates(
            in: store.journal.tasks, planned: planned, active: store.journal.active?.taskID, day: day)
        let completed = store.journal.tasks.filter {
            $0.done && $0.completedAt.map { $0 >= day.start && $0 < day.end } == true
        }.count
        let focusMinutes = Int(store.journal.sessions.reduce(0) { $0 + $1.seconds(in: day) } / 60)
        let picked = selected.intersection(candidates.map(\.id))
        Form {
            Section {
                LabeledContent("Completed today", value: String(completed))
                LabeledContent("Focused today", value: "\(focusMinutes) min")
            }
            Section("Move to tomorrow") {
                if candidates.isEmpty {
                    Text("No unfinished tasks to move.").foregroundStyle(Color.moss)
                } else {
                    ForEach(candidates) { task in
                        Button {
                            if selected.contains(task.id) { selected.remove(task.id) } else { selected.insert(task.id) }
                            message = nil
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(task.id) ? Color.journalInk : Color.moss)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).foregroundStyle(Color.journalInk)
                                    if let due = task.due {
                                        Text("Due " + due.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(Color.moss)
                                    }
                                }
                                Spacer()
                                Text("\(task.minutes) min").font(.caption).foregroundStyle(Color.moss)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selected.contains(task.id) ? .isSelected : [])
                        .accessibilityIdentifier("day-close-task-" + task.id.uuidString)
                    }
                    Button("Move selected (\(picked.count))") { confirmationDay = day.start }
                        .disabled(picked.isEmpty || unsavedCount != nil)
                        .accessibilityIdentifier("day-close-move")
                }
            }
            if let message {
                Section {
                    Text(message)
                    if let unsavedCount {
                        Button("Retry save") { Task { await persistMove(unsavedCount) } }
                    }
                }
            }
        }
        .disabled(saving || store.restoring)
        .formPaper().navigationTitle("Close out today").navigationBarTitleDisplayMode(.inline)
        .alert(
            "Move \(picked.count) \(picked.count == 1 ? "task" : "tasks") to tomorrow?",
            isPresented: Binding(get: { confirmationDay != nil }, set: { if !$0 { confirmationDay = nil } }),
            presenting: confirmationDay
        ) { reviewedDay in
            Button("Move to tomorrow") { move(picked, reviewedDay: reviewedDay) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deadlines stay as set. Earlier pinned times and reminders move to the same local time tomorrow.")
        }
        .onChange(of: day.start) {
            selected.removeAll()
            confirmationDay = nil
        }
    }

    private func move(_ ids: Set<UUID>, reviewedDay: Date) {
        guard !saving, unsavedCount == nil, store.ready, !store.restoring else { return }
        let now = Date.now
        guard Calendar.current.isDate(reviewedDay, inSameDayAs: now) else {
            selected.removeAll()
            store.now = now
            message = "A new day has started. Review today's tasks again."
            return
        }
        let planned = plannedIDs(on: day)
        var count = 0
        store.change { journal in
            count = DayClose.move(
                ids, in: &journal.tasks, planned: planned, active: journal.active?.taskID,
                reviewedDay: reviewedDay, now: now)
        }
        selected.removeAll()
        guard count > 0 else {
            message = "Your plan changed. Review the remaining tasks."
            return
        }
        unsavedCount = count
        Task { await persistMove(count) }
    }

    private func persistMove(_ count: Int) async {
        saving = true
        defer { saving = false }
        do {
            if !store.isDemo { try await store.saveForShortcut() }
            unsavedCount = nil
            message = count == 1 ? "1 task moved to tomorrow." : "\(count) tasks moved to tomorrow."
        } catch {
            message = "The move couldn’t be saved. Retry to keep it on this device."
        }
    }
}
