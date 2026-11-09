import Foundation

public struct CheckIn: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var date: Date
    public var energy, clarity, interest: Double
    public var stress: Double?
    public var fatigueNote: String?
    public var feltWorseAfterActivity: Bool?
    public var sleep, workload: Double?
    public init(
        date: Date = .now, energy: Double, clarity: Double, interest: Double, sleep: Double? = nil,
        workload: Double? = nil, feltWorseAfterActivity: Bool = false
    ) {
        id = UUID()
        self.date = date
        self.energy = Capacity.scale(energy)
        self.clarity = Capacity.scale(clarity)
        self.interest = Capacity.scale(interest)
        self.feltWorseAfterActivity = feltWorseAfterActivity
        self.sleep = sleep.map(Capacity.scale)
        self.workload = workload.map(Capacity.scale)
    }
}

public enum Category: String, Codable, CaseIterable, Sendable {
    case focus = "Focus"
    case personal = "Personal"
    case study = "Study"
    case recovery = "Recovery"
    public var estimate: Int {
        switch self {
        case .focus: 25
        case .personal: 10
        case .study: 20
        case .recovery: 5
        }
    }
}

public struct PlanTask: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var minutes: Int { didSet { partMinute = nil } }
    private var partMinute: Double?
    /// Explicit slice lengths for this occurrence, keyed by the local planning day.
    public var timelineDurations: [TimelineTaskDuration]?

    mutating func resizeRemaining(by delta: Int) {
        let partial = partMinute
        minutes += delta
        partMinute = partial
    }

    public var remainingSeconds: Double { max(0, Double(minutes) * 60 - (partMinute ?? 0)) }

    public var focusedSeconds: Double?
    public mutating func recordFocus(seconds: Double, completed: Bool) {
        if seconds.isFinite, seconds > 0 { focusedSeconds = (focusedSeconds ?? 0) + seconds }
        let remaining = max(0, remainingSeconds - max(0, seconds))
        done = completed
        guard !completed else { return }
        // If the estimate ran out but the person still needs time, offer a one-minute restart.
        minutes = max(1, Int(ceil(remaining / 60)))
        if remaining > 0 { partMinute = Double(minutes) * 60 - remaining }
    }
    public var category: Category
    public var icon: TaskIcon?
    public var requiresPhotoProof: Bool?
    public var importance: Double = 5
    public var practiceID: UUID?
    public var availability: TaskAvailability?
    public var preparation: TaskPreparation?
    public var energyOverride: Double?
    public var effort: Double = 5
    public var overwhelm: Double = 5
    public var setup: Double = 5
    public var due: Date?
    public var after: Date?
    public var dependency: UUID?
    public var project: String?
    public var notes: String?
    public var sourceURL: URL?
    public var capturedDuringSessionID: UUID?
    /// Untimed distractions can be kept for review without reserving any work time.
    public var inboxOnly: Bool?
    public var hasSchedulingInstruction: Bool {
        after != nil || due != nil || plannedStart != nil || reminder != nil ||
            availability != nil || preparation != nil || (repeated ?? .once) != .once
    }
    // Forecast replay can add temporary start constraints. Only an explicit
    // scheduling choice releases a thought from the inbox.
    public var isInboxOnly: Bool { inboxOnly == true }

    public var belongsToInbox: Bool {
        !done && archived != true && (isInboxOnly || (project ?? "").isEmpty)
    }
    public private(set) var resumeNote: String?
    private var resumeStepID: UUID?
    public static let resumeNoteLimit = 240

    public var resumeStep: TaskStep? {
        guard !done, archived != true, let resumeStepID else { return nil }
        return steps?.first { $0.id == resumeStepID && !$0.done }
    }
    public var nextSmallStep: TaskStep? { resumeStep ?? steps?.first { !$0.done } }

    public mutating func rememberStep(_ id: UUID?) {
        resumeStepID = steps?.first { $0.id == id && !$0.done }?.id
    }

    /// A cue belongs to this occurrence. New tasks and templates start with an empty cue.
    public mutating func setResumeNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        resumeNote = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.resumeNoteLimit))
    }
    public var steps: [TaskStep]?
    public var reminder: Date?
    /// An explicit pin can use this particular focus rule, regardless of task category.
    public var assignedFocusBlockID: UUID?
    public var plannedStart: Date? {
        didSet { if plannedStart != oldValue { assignedFocusBlockID = nil } }
    }
    public var repeated: Recurrence?
    /// Calendar weekday numbers for a daily routine on selected days.
    public var repeatDays: Set<Int>?
    public var routineExceptions: [RoutineException]?
    public var routineAnchor: Date?
    public var movedRoutineTimes: MovedRoutineTimes?
    public var seriesID: UUID?
    public var seriesAdvanced: Bool?
    public var archived: Bool?
    public var createdAt: Date?
    public var completedAt: Date?
    public var originalMinutes: Int?
    public var meaningful: Bool?

    public var earliest: Date { max(after ?? .distantPast, plannedStart ?? .distantPast) }
    public func duplicate(id: UUID = UUID()) -> PlanTask {
        var task = PlanTask(title, minutes: originalMinutes ?? minutes, category: category, id: id)
        task.icon = icon
        task.requiresPhotoProof = requiresPhotoProof
        task.availability = availability
        task.project = project
        task.notes = notes
        task.sourceURL = sourceURL
        task.steps = steps?.map { TaskStep($0.title) }
        task.repeated = repeated
        task.repeatDays = repeatDays
        task.importance = importance
        task.energyOverride = energyOverride
        task.effort = effort
        task.overwhelm = overwhelm
        task.setup = setup
        task.meaningful = meaningful
        return task
    }
    public var done = false
    public init(_ title: String, minutes: Int, category: Category = .focus, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.minutes = max(1, minutes)
        originalMinutes = self.minutes
        createdAt = .now
        self.category = category
    }
}

public enum Recurrence: String, Codable, CaseIterable, Sendable {
    case once = "Once"
    case daily = "Daily"
    case weekdays = "Weekdays"
    case weekly = "Weekly"
}
public struct Commitment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var start, end: Date
    public var recurrence: Recurrence
    public init(_ title: String, start: Date, end: Date, recurrence: Recurrence = .once) {
        self.title = title
        self.start = start
        self.end = end
        self.recurrence = recurrence
    }
    public func intervals(on date: Date, calendar: Calendar) -> [DateInterval] {
        guard end > start, let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        func clipped(_ a: Date, _ b: Date) -> DateInterval? {
            let from = max(a, day.start)
            let to = min(b, day.end)
            return from < to ? DateInterval(start: from, end: to) : nil
        }
        if recurrence == .once { return [clipped(start, end)].compactMap { $0 } }
        let anchor = calendar.startOfDay(for: start)
        guard let elapsed = calendar.dateComponents([.day], from: anchor, to: day.start).day, elapsed >= 0 else { return [] }
        let span = calendar.dateComponents([.day], from: anchor, to: calendar.startOfDay(for: end)).day ?? 0
        func occurs(_ offset: Int) -> Bool {
            switch recurrence {
            case .weekly: return (elapsed - offset).isMultiple(of: 7)
            case .weekdays:
                guard let date = calendar.date(byAdding: .day, value: -offset, to: day.start) else { return false }
                return !calendar.isDateInWeekend(date)
            case .daily, .once: return true
            }
        }
        func interval(_ offset: Int) -> DateInterval? {
            // Shift each endpoint by local days so overnight shifts keep their clock times across DST.
            let shift = elapsed - offset
            guard let a = calendar.date(byAdding: .day, value: shift, to: start),
                  let b = calendar.date(byAdding: .day, value: shift, to: end) else { return nil }
            // A short event in a skipped or repeated clock hour still gets its original duration.
            return clipped(a, b > a ? b : a.addingTimeInterval(end.timeIntervalSince(start)))
        }
        let current = occurs(0) ? interval(0) : nil
        // Only the most recent previous occurrence can extend coverage beyond the current one.
        let lookback = min(elapsed, span, 7)
        guard lookback > 0, let priorOffset = (1...lookback).first(where: occurs),
              let prior = interval(priorOffset) else { return current.map { [$0] } ?? [] }
        guard let current else { return [prior] }
        if prior.end >= current.start { return [DateInterval(start: prior.start, end: max(prior.end, current.end))] }
        return [prior, current]
    }
}

public struct FocusPeriod: Codable, Equatable, Sendable {
    public let start: Date
    public let seconds: Double

    public func seconds(in range: DateInterval) -> Double {
        max(
            0,
            min(range.end, start.addingTimeInterval(seconds)).timeIntervalSince(max(range.start, start)))
    }
}

public struct SessionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var taskID: UUID
    public var title: String
    public var start: Date
    public var seconds: Double
    // Older journal entries retain their original start-day accounting.
    public var periods: [FocusPeriod]?
    public func seconds(in range: DateInterval) -> Double {
        periods?.reduce(0) { $0 + $1.seconds(in: range) }
            ?? (start >= range.start && start < range.end ? seconds : 0)
    }

    public var plannedSeconds: Double?
    public var finishedAt: Date?
    public var completedTask: Bool?
    public fileprivate(set) var openSprint: Bool?
    public var isOpenSprint: Bool { openSprint == true }

    /// Older peers preserve both UUIDs but omit the optional sprint marker.
    public mutating func recoverOpenSprintIdentity() {
        if openSprint == nil, id == taskID, completedTask == nil { openSprint = true }
    }
    public init(taskID: UUID, title: String, start: Date, seconds: Double, completedTask: Bool? = nil) {
        self.completedTask = completedTask
        self.taskID = taskID
        self.title = title
        self.start = start
        self.seconds = max(0, seconds)
    }
}

public struct ActiveSession: Codable, Equatable, Sendable {
    public var sessionID: UUID?
    public private(set) var timerRevision: Int?
    public private(set) var openSprint: Bool?
    public var isOpenSprint: Bool { openSprint == true }
    public var taskID: UUID
    public var title: String
    public var started: Date
    public var stepID: UUID?
    public var target: Double
    private var periods: [FocusPeriod]?
    public private(set) var accumulated = 0.0
    public private(set) var wallAnchor: Date?
    public private(set) var tickAnchor: Double?
    public private(set) var bootID: String?
    public init(task: PlanTask, minutes: Int, now: Date, tick: Double, boot: String?) {
        sessionID = UUID()
        periods = []
        taskID = task.id
        title = task.title
        target = min(task.remainingSeconds, Double(max(1, minutes)) * 60)
        started = now
        resume(now: now, tick: tick, boot: boot)
    }
    public init(openSprintSeconds: Double, now: Date, tick: Double, boot: String?) {
        let id = UUID()
        sessionID = id
        // Existing timer destinations use this UUID and the starting instant.
        // A task-free sprint uses its own identity for those destinations.
        taskID = id
        openSprint = true
        title = "Open sprint"
        periods = []
        target = max(1, min(120, openSprintSeconds))
        started = now
        resume(now: now, tick: tick, boot: boot)
    }

    public func elapsed(now: Date, tick: Double, boot: String?) -> Double {
        guard let wallAnchor, let tickAnchor else { return accumulated }
        let sameBoot = boot != nil && boot == bootID && tick >= tickAnchor
        let interval = sameBoot ? tick - tickAnchor : now.timeIntervalSince(wallAnchor)
        return min(target, accumulated + max(0, interval))
    }
    public mutating func pause(now: Date, tick: Double, boot: String?) {
        guard let wallAnchor else { return }
        timerRevision = (timerRevision ?? 0) &+ 1
        let total = elapsed(now: now, tick: tick, boot: boot)
        if total > accumulated {
            periods?.append(FocusPeriod(start: wallAnchor, seconds: total - accumulated))
        }
        accumulated = total
        self.wallAnchor = nil
        tickAnchor = nil
        bootID = nil
    }
    public func record(now: Date, tick: Double, boot: String?, completed: Bool? = nil)
        -> SessionRecord
    {
        var stopped = self
        stopped.pause(now: now, tick: tick, boot: boot)
        var record = SessionRecord(
            taskID: taskID, title: title, start: started, seconds: stopped.accumulated,
            completedTask: isOpenSprint ? nil : completed)
        record.openSprint = openSprint
        if let sessionID { record.id = sessionID }
        record.periods = stopped.periods
        record.plannedSeconds = target
        return record
    }
    public mutating func resume(now: Date, tick: Double, boot: String?) {
        guard wallAnchor == nil, accumulated < target else { return }
        timerRevision = (timerRevision ?? 0) &+ 1
        wallAnchor = now
        tickAnchor = tick
        bootID = boot
    }
}
