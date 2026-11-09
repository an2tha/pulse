import Foundation

/// A one-occurrence move keeps the original times available to the recurrence generator.
public struct MovedRoutineTime: Codable, Equatable, Sendable {
    public let original: Date?
    public let moved: Date
}

public struct MovedRoutineTimes: Codable, Equatable, Sendable {
    public var pin: MovedRoutineTime?
    public var reminder: MovedRoutineTime?
    public var availability: MovedRoutineTime?
}

extension PlanTask {
    public mutating func moveOccurrence(to start: Date, originalDay: Date? = nil, calendar: Calendar = .current) {
        if let source = originalDay ?? plannedStart, !calendar.isDate(source, inSameDayAs: start),
           let length = timelineDuration(on: source, calendar: calendar) {
            timelineDurations?.removeAll { calendar.isDate($0.start, inSameDayAs: source) }
            setTimelineDuration(length, on: start, calendar: calendar)
        }
        assignedFocusBlockID = nil
        if let repeated, repeated != .once {
            var times = movedRoutineTimes ?? MovedRoutineTimes()
            if times.pin?.moved != plannedStart { times.availability = nil }
            if times.availability == nil, let after, let nominal = occurrence(in: calendar)?.day(in: calendar),
               after < nominal {
                // An explicitly earlier release on a generated task belongs to the user.
                times.availability = MovedRoutineTime(original: after, moved: after)
            }
            let original = templatePin
            times.pin = MovedRoutineTime(original: original, moved: start)
            if routineAnchor == nil { routineAnchor = original ?? after ?? calendar.startOfDay(for: originalDay ?? start) }
            movedRoutineTimes = times
        }
        if inboxOnly == true { inboxOnly = nil }
        plannedStart = start
    }

    var templatePin: Date? {
        if let pin = movedRoutineTimes?.pin, pin.moved == plannedStart { return pin.original }
        return plannedStart
    }

    public var canReleaseTimePin: Bool {
        guard !done, archived != true, let pin = plannedStart else { return false }
        guard let rule = repeated, rule != .once else { return true }
        guard let change = movedRoutineTimes?.pin, change.moved == pin else { return false }
        if change.original != pin { return true }
        guard let release = movedRoutineTimes?.availability else { return false }
        return release.original != release.moved && after == release.moved
    }

    public mutating func releaseTimePin(calendar: Calendar = .current) {
        guard canReleaseTimePin else { return }
        assignedFocusBlockID = nil
        if let rule = repeated, rule != .once, let move = movedRoutineTimes?.pin {
            plannedStart = move.original
            if let availability = movedRoutineTimes?.availability {
                if after == availability.moved { after = availability.original }
            } else if let nominal = occurrence(in: calendar)?.day(in: calendar),
                      let after, after < nominal, after == calendar.startOfDay(for: move.moved) {
                // Earlier versions lowered a generated occurrence's release day without retaining the original.
                self.after = nominal
            }
        } else {
            plannedStart = nil
        }
        movedRoutineTimes?.pin = nil
        movedRoutineTimes?.availability = nil
        if movedRoutineTimes?.reminder == nil { movedRoutineTimes = nil }
    }

    var templateReminder: Date? {
        if let old = movedRoutineTimes?.reminder, old.moved == reminder { return old.original }
        return reminder
    }
}

public enum DayClose {
    public static func candidates(
        in tasks: [PlanTask], planned: Set<UUID>, active: UUID?, day: DateInterval
    ) -> [PlanTask] {
        tasks.filter { task in
            guard !task.done, task.archived != true, task.id != active, task.earliest < day.end else {
                return false
            }
            let datedForToday = [task.after, task.plannedStart, task.reminder].compactMap { $0 }
                .contains { $0 >= day.start && $0 < day.end }
            return planned.contains(task.id) || datedForToday || task.due.map { $0 < day.end } == true
        }
    }

    /// The caller passes the reviewed day so a delayed confirmation cannot move a second day's work.
    @discardableResult public static func move(
        _ selected: Set<UUID>, in tasks: inout [PlanTask], planned: Set<UUID>, active: UUID?,
        reviewedDay: Date, now: Date, calendar: Calendar = .current
    ) -> Int {
        guard calendar.isDate(reviewedDay, inSameDayAs: now),
            let day = calendar.dateInterval(of: .day, for: now)
        else { return 0 }

        let eligible = selected.intersection(
            candidates(in: tasks, planned: planned, active: active, day: day).map(\.id))
        for index in tasks.indices where eligible.contains(tasks[index].id) {
            var task = tasks[index]
            let repeating = task.repeated != nil && task.repeated != .once
            if repeating && task.routineAnchor == nil {
                task.routineAnchor = task.templatePin ?? task.after ?? day.start
            }
            // Reapply clock components, since the next local day may be 23 or 25 hours long.
            func tomorrow(_ time: Date) -> Date {
                let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
                return calendar.date(
                    bySettingHour: clock.hour!, minute: clock.minute!, second: clock.second!, of: day.end,
                    matchingPolicy: .nextTimePreservingSmallerComponents
                ) ?? day.end
            }
            var times = task.movedRoutineTimes ?? MovedRoutineTimes()
            if let pin = task.plannedStart {
                let newPin = tomorrow(pin)
                if repeating { times.pin = MovedRoutineTime(original: task.templatePin, moved: newPin) }
                task.plannedStart = newPin
            }
            if let reminder = task.reminder, reminder < day.end {
                let newReminder = tomorrow(reminder)
                if repeating {
                    times.reminder = MovedRoutineTime(original: task.templateReminder ?? reminder, moved: newReminder)
                }
                task.reminder = newReminder
            }
            task.movedRoutineTimes = repeating && (times.pin != nil || times.reminder != nil || times.availability != nil) ? times : nil
            task.inboxOnly = nil
            task.deferOccurrence(until: day.end)
            tasks[index] = task
        }
        return eligible.count
    }
}
