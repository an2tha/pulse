import Foundation

/// Weekdays identify the opening date, with Sunday numbered 1. The closing minute is exclusive.
public struct TaskAvailability: Codable, Hashable, Sendable {
    public let weekdays: Set<Int>
    public let startMinute: Int
    public let endMinute: Int

    public init?(weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
        guard !weekdays.isEmpty, weekdays.allSatisfy((1...7).contains),
              (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { return nil }
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let weekdays = try fields.decode(Set<Int>.self, forKey: .weekdays)
        let start = try fields.decode(Int.self, forKey: .startMinute)
        let end = try fields.decode(Int.self, forKey: .endMinute)
        guard let valid = Self(weekdays: weekdays, startMinute: start, endMinute: end) else {
            throw DecodingError.dataCorruptedError(forKey: .weekdays, in: fields, debugDescription: "Invalid task availability.")
        }
        self = valid
    }

    /// The uninterrupted opening containing this instant, including an overnight opening on the prior weekday.
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        if startMinute == endMinute && weekdays.count == 7 { return DateInterval(start: .distantPast, end: .distantFuture) }
        guard let day = calendar.dateInterval(of: .day, for: date),
              let match = intervals(on: day, calendar: calendar).first(where: { $0.start <= date && date < $0.end }) else { return nil }
        var start = match.start
        var end = match.end
        var previousBoundary = day.start
        var nextBoundary = day.end
        // At most six adjacent full-day openings can occur before a closed weekday.
        for _ in 0..<7 where start == previousBoundary {
            guard let previous = calendar.dateInterval(of: .day, for: start.addingTimeInterval(-1)),
                  let prior = intervals(on: previous, calendar: calendar).last, prior.end == start else { break }
            start = prior.start
            previousBoundary = previous.start
        }
        for _ in 0..<7 where end == nextBoundary {
            guard let next = calendar.dateInterval(of: .day, for: end),
                  let following = intervals(on: next, calendar: calendar).first, following.start == end else { break }
            end = following.end
            nextBoundary = next.end
        }
        return DateInterval(start: start, end: end)
    }

    /// Restrict the wall-clock rule to actual instants. Missing minutes contribute nothing,
    /// and both instances of a repeated minute are evaluated against the same clock range.
    /// Pass the full local day returned by the same calendar.
    public func intervals(on day: DateInterval, calendar: Calendar) -> [DateInterval] {
        let weekday = calendar.component(.weekday, from: day.start)
        var clockRanges: [Range<Int>] = []
        if endMinute <= startMinute && endMinute > 0 && weekdays.contains(weekday == 1 ? 7 : weekday - 1) {
            clockRanges.append(0..<endMinute)
        }
        if weekdays.contains(weekday) {
            clockRanges.append(startMinute..<(endMinute > startMinute ? endMinute : 1440))
        }
        guard !clockRanges.isEmpty else { return [] }
        var result: [DateInterval] = []
        var cursor = day.start
        while cursor < day.end {
            let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: cursor)
            let boundary = min(transition ?? day.end, day.end)
            let time = calendar.dateComponents([.hour, .minute, .second], from: cursor)
            let wallSeconds = (time.hour ?? 0) * 3600 + (time.minute ?? 0) * 60 + (time.second ?? 0)
            for range in clockRanges {
                let start = max(cursor, cursor.addingTimeInterval(Double(range.lowerBound * 60 - wallSeconds)))
                let end = min(boundary, cursor.addingTimeInterval(Double(range.upperBound * 60 - wallSeconds)))
                guard end > start else { continue }
                if result.last?.end == start { result[result.count - 1].end = end }
                else { result.append(DateInterval(start: start, end: end)) }
            }
            guard boundary > cursor else { break }
            cursor = boundary
        }
        return result
    }
}

/// Resolve each distinct rule once for a day's scheduling trials.
struct DayTaskWindows: Sendable {
    var intervals: [TaskAvailability: [DateInterval]] = [:]
    let bufferMinutes: Int
    private let day: DateInterval?
    private let focus: [DateInterval]
    private let focusByID: [UUID: [DateInterval]]
    private let weekday: Int

    init(rules: Set<TaskAvailability>, on day: DateInterval, calendar: Calendar, bufferMinutes: Int, focusRules: [WeeklyTimeBlock] = []) {
        focusByID = Dictionary(grouping: focusRules.filter { $0.kind == .focus }, by: \.id)
            .mapValues { $0.flatMap { $0.intervals(on: day, calendar: calendar) } }
        focus = Planner.mergedWindows(focusByID.values.flatMap { $0 }.sorted { $0.start < $1.start })
        self.bufferMinutes = bufferMinutes
        self.day = day
        weekday = calendar.component(.weekday, from: day.start)
        for rule in rules { intervals[rule] = rule.intervals(on: day, calendar: calendar) }
    }

    init(bufferMinutes: Int) {
        focusByID = [:]
        focus = []
        self.bufferMinutes = bufferMinutes
        day = nil
        weekday = 0
    }

    /// Only the occurrence containing the authored pin can admit an explicitly selected task.
    func assignedWindow(for task: PlanTask) -> DateInterval? {
        guard let id = task.assignedFocusBlockID, let pin = task.plannedStart else { return nil }
        return focusByID[id]?.first { $0.start <= pin && pin < $0.end }
    }

    /// Only whole minutes can be placed on the planner. Skip a window with just seconds left.
    func opening(for task: PlanTask, atOrAfter time: Date, until boundary: Date) -> DateInterval? {
        if let day, !task.permitsRoutineWork(on: day, weekday: weekday) { return nil }
        let boundary = min(boundary, task.preparationCutoff(bufferMinutes: bufferMinutes) ?? boundary)
        let earliest = max(task.earliest, time)
        guard boundary.timeIntervalSince(earliest) >= 60 else { return nil }
        let openings = task.availability.map { intervals[$0] ?? [] } ?? [DateInterval(start: earliest, end: boundary)]
        for opening in openings {
            var start = max(earliest, opening.start)
            let end = min(boundary, opening.end)
            let assigned = assignedWindow(for: task)
            if let assigned, assigned.start <= start, start < assigned.end {
                let close = min(assigned.end, end)
                if close.timeIntervalSince(start) >= 60 { return DateInterval(start: start, end: close) }
            }
            for window in focus where window.end > start && window.start < end {
                let before = min(end, window.start)
                if before.timeIntervalSince(start) >= 60 { return DateInterval(start: start, end: before) }
                if task.fitsDedicatedFocus {
                    let begin = max(start, window.start)
                    let close = min(end, window.end)
                    if close.timeIntervalSince(begin) >= 60 { return DateInterval(start: begin, end: close) }
                }
                start = max(start, window.end)
            }
            if end.timeIntervalSince(start) >= 60 { return DateInterval(start: start, end: end) }
        }
        return nil
    }

    func allows(_ task: PlanTask, at time: Date, seconds: TimeInterval = 60) -> Bool {
        if let day, !task.permitsRoutineWork(on: day, weekday: weekday) { return false }
        if let cutoff = task.preparationCutoff(bufferMinutes: bufferMinutes), cutoff.timeIntervalSince(time) < seconds { return false }
        if !focus.isEmpty {
            let end = time.addingTimeInterval(seconds)
            if let assigned = assignedWindow(for: task), assigned.start <= time && time < assigned.end {
                if end > assigned.end { return false }
            } else if task.fitsDedicatedFocus {
                if focus.contains(where: { time < $0.start && $0.start < end || time < $0.end && $0.end < end }) { return false }
            } else if focus.contains(where: { $0.start < end && time < $0.end }) { return false }
        }
        guard let rule = task.availability else { return true }
        return intervals[rule]?.contains { $0.start <= time && $0.end.timeIntervalSince(time) >= seconds } == true
    }
}
