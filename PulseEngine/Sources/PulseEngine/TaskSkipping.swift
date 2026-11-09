import Foundation

public enum TaskSkipReason: String, CaseIterable, Codable, Identifiable, Sendable {
    case lowEnergy = "Low energy"
    case notEnoughTime = "Not enough time"
    case interrupted = "Interrupted"
    case blocked = "Waiting on something"
    case prioritiesChanged = "Priorities changed"
    case unwell = "Feeling unwell"
    case other = "Something else"

    public var id: Self { self }
}

public struct TaskSkipRecord: Identifiable, Codable, Equatable, Sendable {
    public static let noteLimit = 500
    public let id: UUID
    public let taskID: UUID
    public let seriesID: UUID?
    public let title: String
    public let scheduledStart: Date
    public let skippedAt: Date
    public let reason: TaskSkipReason
    public let energy: Int
    public let focus: Int?
    public let notes: String

    public init(taskID: UUID, title: String, scheduledStart: Date, skippedAt: Date,
                reason: TaskSkipReason, energy: Int, focus: Int? = nil, notes: String = "", seriesID: UUID? = nil) {
        self.id = UUID()
        self.taskID = taskID
        self.seriesID = seriesID
        self.title = title
        self.scheduledStart = scheduledStart
        self.skippedAt = skippedAt
        self.reason = reason
        self.energy = energy
        self.focus = focus
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        scheduledStart <= skippedAt && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (0...10).contains(energy) && focus.map { (0...10).contains($0) } != false
            && notes.count <= Self.noteLimit && (reason != .other || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

public enum TaskSkipping {
    /// An unpinned task's future start follows the displayed plan. Once it arrives,
    /// remember it even if the planner pushes the unfinished task later.
    public static func automaticStarts(_ previous: [UUID: Date], tasks: [PlanTask], blocks: [Block], at now: Date, activeTask: UUID? = nil) -> [UUID: Date] {
        let eligible = tasks.filter { task in
            !task.done && task.archived != true && !task.isInboxOnly &&
                (task.plannedStart.map { $0 < (task.after ?? .distantPast) } ?? true)
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        var starts = previous.filter { id, start in
            guard let task = byID[id] else { return false }
            return (start <= now || id == activeTask) && start >= (task.after ?? .distantPast)
        }
        for block in blocks {
            guard case .task(let id) = block.kind, let task = byID[id],
                  block.start >= (task.after ?? .distantPast) else { continue }
            starts[id] = min(starts[id] ?? block.start, block.start)
        }
        return starts
    }

    public static func eligibleStart(for task: PlanTask, automaticStart: Date?, activeStart: Date? = nil, at now: Date) -> Date? {
        let release = task.after ?? .distantPast
        let pin = task.plannedStart.flatMap { $0 >= release ? $0 : nil }
        guard !task.done, task.archived != true, (!task.isInboxOnly || activeStart != nil),
              let start = pin ?? automaticStart ?? activeStart, start <= now, start >= release else { return nil }
        return start
    }

    /// A one-off goes back into planning tomorrow. A skipped repeat releases
    /// the next occurrence without registering today's one as completed.
    @discardableResult public static func skip(_ id: UUID, in tasks: inout [PlanTask], scheduledStart: Date,
                                               at now: Date, activeStart: Date? = nil, calendar: Calendar = .current) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              eligibleStart(for: tasks[index], automaticStart: scheduledStart, activeStart: activeStart, at: now) == scheduledStart,
              let nextDay = calendar.dateInterval(of: .day, for: now)?.end else { return false }
        if let cadence = tasks[index].repeated, cadence != .once {
            if tasks[index].routineAnchor == nil {
                tasks[index].routineAnchor = tasks[index].plannedStart ?? tasks[index].after ?? scheduledStart
            }
            TaskRoutines.advance(&tasks, at: now, calendar: calendar, releasing: id)
            tasks[index].archived = true
        } else {
            tasks[index].plannedStart = nil
            tasks[index].after = nextDay
            tasks[index].timelineDurations?.removeAll { $0.start < nextDay }
            if tasks[index].timelineDurations?.isEmpty == true { tasks[index].timelineDurations = nil }
        }
        if let reminder = tasks[index].reminder, reminder < nextDay { tasks[index].reminder = nil }
        return true
    }
}
