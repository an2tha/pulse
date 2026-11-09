import Foundation
import PulseEngine

struct TimeDropSuggestion {
    let taskID: UUID
    let source: Date
    let start: Date

    init?(for task: PlanTask?, from source: Date, day: Date, hour: Date?, options: [TaskPlacement], calendar: Calendar = .current) {
        guard let task else { return nil }
        let alternatives = options.filter { $0.start != $0.originalStart }
        let onDay = alternatives.filter { calendar.isDate($0.start, inSameDayAs: day) }
        let slot: TaskPlacement?
        if let hour, !onDay.isEmpty {
            slot = onDay.min {
                let a = abs($0.start.timeIntervalSince(hour)), b = abs($1.start.timeIntervalSince(hour))
                return a == b ? $0.start > $1.start : a < b
            }
        } else {
            // The week's top pick can be the current time. Rank the remaining
            // openings so a full destination day still offers a genuine move.
            let available = onDay.isEmpty ? alternatives : onDay
            slot = available.min { $0.isPreferred(to: $1, for: task) }
        }
        guard let slot else { return nil }
        taskID = task.id
        self.source = source
        start = slot.start
    }

    func label(includeDay: Bool) -> String {
        "Use " + (includeDay ? start.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : start.formatted(date: .omitted, time: .shortened))
    }
}

extension Workspace {
    func blockedDropMessage(taskID: UUID, day: Date, hour: Date?, exact: Bool = false) -> String {
        let calendar = Calendar.current
        if exact && !calendarReadyForStart { return "Your calendar is still loading. Try placing the task again in a moment." }
        let target = hour.flatMap { start in
            exact ? DateInterval(start: start, duration: 1) : calendar.dateInterval(of: .hour, for: start)
        }
        if exact, let hour, hour < Date.now { return "That time has passed." }
        if isRestDay && calendar.isDate(day, inSameDayAs: now) { return "Today is a rest day." }
        if journal.limit == 0 { return "Your work limit is set to zero." }
        if let earliest = timingTask(taskID)?.after, let window = calendar.dateInterval(of: .day, for: day), earliest >= window.end {
            return "This task is available from " + earliest.formatted(date: .abbreviated, time: .shortened) + "."
        }
        if let hours = timingTask(taskID)?.availability, let localDay = calendar.dateInterval(of: .day, for: day) {
            let target = target ?? localDay
            let opens = hours.intervals(on: localDay, calendar: calendar)
            if !opens.contains(where: { max(target.start, $0.start, now) < min(target.end, $0.end) }) {
                return "Available " + hours.formattedHours() + "."
            }
        }
        guard let hour, let window = target else {
            if let window = calendar.dateInterval(of: .day, for: day),
               let fullDay = planningEvents.first(where: { event in
                   event.intervals(on: day, calendar: calendar).contains { $0.start <= window.start && $0.end >= window.end }
               }) {
                return "“" + fullDay.title + "” fills that day."
            }
            return "This task doesn’t fit on that day."
        }
        let from = max(now, window.start)
        if from >= window.end { return "That hour has passed." }
        if journal.wrapUpMinute != nil, from >= preferences.workEnd(on: day) { return "That hour is after your wrap-up time." }
        for event in planningEvents {
            if let busy = event.intervals(on: hour, calendar: calendar).first(where: { $0.start <= from && $0.end >= window.end }) {
                if !exact, busy.end == calendar.dateInterval(of: .day, for: hour)?.end { return "“" + event.title + "” fills that hour." }
                return "“" + event.title + "” runs until " + busy.end.formatted(date: .omitted, time: .shortened) + "."
            }
        }
        if let block = preferences.weeklyBlocks(on: hour, commitments: planningEvents, reports: journal.reports).first(where: {
            guard case .timeBlock(_, let role) = $0.kind, $0.start <= from, $0.end >= window.end else { return false }
            return role != .focus || timingTask(taskID)?.fitsDedicatedFocus == false
        }), case .timeBlock(_, let role) = block.kind {
            return role.label + " lasts until " + block.end.formatted(date: .omitted, time: .shortened) + "."
        }
        if EnergyExpectation.applicable(at: from, in: preferences.expectations, calendar: calendar)?.score == 0,
           preferences.capacity(at: from, reports: journal.reports, calendar: calendar) == 0 {
            return "Expected energy for this hour is 0/10."
        }
        if exact, let pin = blocks.first(where: { block in
            guard case .task(let other) = block.kind, other != taskID,
                  block.start <= hour, hour < block.end else { return false }
            return timingTask(other)?.plannedStart != nil
        }) {
            return "“" + pin.title + "” is scheduled until " + pin.end.formatted(date: .omitted, time: .shortened) + "."
        }
        return exact ? "This task doesn’t fit at that time." : "This task doesn’t fit in that hour."
    }
}
