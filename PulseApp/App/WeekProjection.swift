import Foundation
import PulseEngine

/// Both sides of a move use one clock, calendar snapshot, active hold and energy model.
struct WeekProjection: Sendable {
    let clock: Date
    let journal: Journal
    let tasks: [PlanTask]
    let events: [Commitment]
    let preferences: PlannerPreferences
    let active: SessionRecord?
    var calendar: Calendar = .current

    private var inputs: DayScheduleInputs? {
        DayScheduleInputs(journal: journal, events: events, tasks: tasks, at: clock, active: active, calendar: calendar)
    }

    func days() -> [OutlookDay] {
        guard !Task.isCancelled, let inputs else { return [] }
        return days(for: inputs)
    }

    private func days(for input: DayScheduleInputs) -> [OutlookDay] {
        let resting = journal.restDate.map { calendar.isDate($0, inSameDayAs: clock) } == true
        let limit = resting ? 0 : journal.limit
        let today = Planner.schedule(at: clock, tasks: input.tasks, commitments: input.events, reports: journal.reports,
                                     dailyLimit: limit, usedMinutes: input.used, breaks: journal.breaks,
                                     recovery: limit > 0 ? journal.recovery : nil, nextTaskID: journal.nextTaskID,
                                     preferences: preferences, calendar: calendar)
        return WeekOutlook.project(at: clock, today: today, tasks: input.tasks, events: input.events,
                                   reports: journal.reports, limit: journal.limit, breaks: journal.breaks,
                                   preferences: preferences, startHour: journal.planningStartHour ?? 9, calendar: calendar)
    }

    func resizedTasks(_ id: UUID, start: Date, end: Date, minutes: Int) throws -> [PlanTask] {
        let before = days()
        try Task.checkCancellation()
        let proposed = try TaskRoutines.resizing(id, start: start, end: end, to: minutes, tasks: tasks,
                                                days: before, now: clock, calendar: calendar)
        let wantedEnd = start.addingTimeInterval(Double(minutes) * 60)
        let blocks = before.flatMap(\.blocks)
        if wantedEnd > end, blocks.contains(where: { other in
            guard other.start < wantedEnd, other.end > end else { return false }
            switch other.kind {
            case .task(let task): return task != id
            case .fixed, .timeBlock(_, .protected), .timeBlock(_, .boost): return true
            case .rest, .timeBlock(_, .focus): return false
            }
        }) { throw TimelineResizeError.doesNotFit }
        let trial = WeekProjection(clock: clock, journal: journal, tasks: proposed, events: events,
                                   preferences: preferences, active: active, calendar: calendar)
        let after = trial.days().flatMap(\.blocks)
        try Task.checkCancellation()
        let pinned = (tasks + before.flatMap(\.projectedTasks)).reduce(into: [UUID: Set<Date>]()) { pins, task in
            if let pin = task.plannedStart { pins[task.id, default: []].insert(pin) }
        }
        let retained = blocks.filter { block in
            guard case .task(let other) = block.kind else { return false }
            if other == id { return block.start < start }
            return pinned[other]?.contains(block.start) == true
        }
        guard after.contains(where: { $0.kind == .task(id) && $0.start == start && $0.end == wantedEnd }),
              retained.allSatisfy(after.contains)
        else { throw TimelineResizeError.doesNotFit }
        return proposed
    }

    func focusPlacement(taskID: UUID, target: Block, newRule: WeeklyTimeBlock?, forecast: EnergyTimeline) -> TaskPlacement? {
        guard let inputs else { return nil }
        var options = preferences
        if let newRule { options.timeBlocks.append(newRule) }
        let resting = journal.restDate.map { calendar.isDate($0, inSameDayAs: clock) } == true
        return Planner.weekPlacements(for: taskID, at: clock, tasks: inputs.tasks, commitments: inputs.events,
                                      reports: journal.reports, dailyLimit: journal.limit, usedMinutes: inputs.used,
                                      breaks: journal.breaks, recovery: journal.recovery, nextTaskID: journal.nextTaskID,
                                      preferences: options, calendar: calendar, forecast: forecast,
                                      startHour: journal.planningStartHour ?? 9, todayLimit: resting ? 0 : journal.limit,
                                      focusTarget: target, priorPreferences: newRule == nil ? nil : preferences)
            .first(where: \.recommended)
    }

    func impact(of slot: TaskPlacement, taskID: UUID) -> WeekSlotImpact? {
        guard !Task.isCancelled, let original = inputs else { return nil }
        var proposed = original
        if let key = slot.projectedOccurrence {
            guard key.id == taskID, let owner = proposed.tasks.firstIndex(where: { $0.owns(key) }) else { return nil }
            proposed.tasks[owner].setException(.init(occurrence: key, start: slot.start), for: key, calendar: calendar)
        } else {
            guard let i = proposed.tasks.firstIndex(where: { $0.id == taskID && !$0.done && $0.archived != true })
            else { return nil }
            proposed.tasks[i].moveOccurrence(to: slot.start, originalDay: slot.originalStart ?? slot.start, calendar: calendar)
        }
        let before = days(for: original)
        guard !Task.isCancelled else { return nil }
        let after = days(for: proposed)
        guard !Task.isCancelled,
              let day = after.first(where: { calendar.isDate($0.date, inSameDayAs: slot.start) }),
              let moved = day.blocks.first(where: { $0.kind == .task(taskID) && $0.start == slot.start && $0.minutes == slot.minutes })
        else { return nil }
        let margin = WeekSlotImpact.adjacent(to: moved, in: day, events: proposed.events,
                                             buffer: preferences.bufferMinutes, calendar: calendar, focusID: journal.active?.taskID)
        guard !Task.isCancelled else { return nil }
        return WeekSlotImpact(before: before, after: after, taskID: taskID, margin: margin)
    }
}

struct WeekSlotImpact: Sendable {
    struct Change: Identifiable, Sendable {
        let id: UUID
        let title: String
        let before: [Block]
        let after: [Block]
    }
    struct Margin: Sendable {
        let title: String
        let isFocus: Bool
        let eventIsFirst: Bool
        let gap: TimeInterval
        let buffer: Int
    }

    let selectedChanged: Bool
    let others: [Change]
    let margin: Margin?

    init(before: [OutlookDay], after: [OutlookDay], taskID: UUID, margin: Margin?) {
        func byTask(_ days: [OutlookDay]) -> [UUID: [Block]] {
            var parts: [UUID: [Block]] = [:]
            for day in days {
                for block in day.blocks {
                    if case .task(let id) = block.kind { parts[id, default: []].append(block) }
                }
            }
            return parts
        }
        let old = byTask(before)
        let new = byTask(after)
        selectedChanged = old[taskID] != new[taskID]
        self.margin = margin
        // A long task may span several days. Show only parts whose time or duration actually changes.
        others = Set(old.keys).union(new.keys).subtracting([taskID]).compactMap { id in
            let original = old[id] ?? []
            let proposed = new[id] ?? []
            guard original != proposed, let title = proposed.first?.title ?? original.first?.title else { return nil }
            return Change(id: id, title: title, before: original.filter { !proposed.contains($0) },
                          after: proposed.filter { !original.contains($0) })
        }.sorted {
            let a = min($0.before.first?.start ?? .distantFuture, $0.after.first?.start ?? .distantFuture)
            let b = min($1.before.first?.start ?? .distantFuture, $1.after.first?.start ?? .distantFuture)
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }

    /// Use an actual adjacent commitment, including a buffer that carries over midnight.
    static func adjacent(to block: Block, in day: OutlookDay, events: [Commitment],
                         buffer: Int, calendar: Calendar, focusID: UUID? = nil) -> Margin? {
        guard let bounds = calendar.dateInterval(of: .day, for: day.date) else { return nil }
        let allowance = min(30, max(0, buffer))
        let dates = allowance > 0 ? [bounds.start.addingTimeInterval(-1), day.date, bounds.end] : [day.date]
        let tasks = day.blocks.filter { if case .task = $0.kind { $0 != block } else { false } }
        var nearest: Margin?
        for event in events {
            if Task.isCancelled { return nil }
            for date in dates {
                for interval in event.intervals(on: date, calendar: calendar) {
                    let before = interval.end <= block.start
                    guard before || interval.start >= block.end else { continue }
                    let first = before ? interval.end : block.end
                    let last = before ? block.start : interval.start
                    let gap = last.timeIntervalSince(first)
                    guard gap < (nearest?.gap ?? .infinity),
                          calendar.isDate(date, inSameDayAs: day.date) || gap <= Double(allowance) * 60,
                          !tasks.contains(where: { $0.start < last && $0.end > first }) else { continue }
                    nearest = Margin(title: event.title, isFocus: event.id == focusID, eventIsFirst: before, gap: gap, buffer: allowance)
                }
            }
        }
        return nearest
    }
}

enum FocusAssignmentError: LocalizedError {
    case unavailable, changed, taskChanged, blockChanged, noTime, beyondHorizon

    var errorDescription: String? {
        switch self {
        case .unavailable: "Wait for your journal and calendar to finish loading, then try again."
        case .changed: "Your plan changed. Try the move again."
        case .taskChanged: "This task is no longer available to schedule."
        case .blockChanged: "This focus block changed. Open it again."
        case .beyondHorizon: "Choose a focus block within the next \(Planner.focusAssignmentLookaheadDays) days, or save the block without a task."
        case .noTime: "This task doesn’t fit in the focus block. Try another time or choose a different task."
        }
    }
}
