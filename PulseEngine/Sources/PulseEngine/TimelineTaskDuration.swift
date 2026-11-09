import Foundation

public struct TimelineTaskDuration: Codable, Equatable, Sendable {
    public let start: Date
    public let minutes: Int
}

extension PlanTask {
    func timelineDuration(on date: Date, calendar: Calendar) -> Int? {
        timelineDurations?.first { calendar.isDate($0.start, inSameDayAs: date) }?.minutes
    }

    mutating func setTimelineDuration(_ length: Int, on date: Date, calendar: Calendar) {
        var edits = timelineDurations ?? []
        edits.removeAll { calendar.isDate($0.start, inSameDayAs: date) }
        edits.append(TimelineTaskDuration(start: date, minutes: length))
        timelineDurations = edits
    }

    public func blockMinutes(at start: Date, capacity: Double, limit: Int, calendar: Calendar) -> Int {
        if let length = timelineDuration(on: start, calendar: calendar), length > 0, capacity > 0 {
            return max(0, min(length, minutes, limit))
        }
        return Capacity.block(minutes: minutes, capacity: capacity, limit: limit)
    }
}

public enum TimelineResizeError: LocalizedError {
    case changed, unavailable, doesNotFit
    public var errorDescription: String? {
        switch self {
        case .changed: "The schedule changed. Try resizing the task again."
        case .unavailable: "This task can’t be resized right now."
        case .doesNotFit: "That duration doesn’t fit here. Try a shorter duration or move the task."
        }
    }
}

extension TaskRoutines {
    /// A resize changes the selected slice of remaining work. Other planned days and completed focus time are retained.
    public static func resizing(_ id: UUID, start: Date, end: Date, to minutes: Int, tasks: [PlanTask],
                                days: [OutlookDay], now: Date, calendar: Calendar = .current) throws -> [PlanTask] {
        guard (1...1440).contains(minutes), end > start,
              let day = days.first(where: { calendar.isDate($0.date, inSameDayAs: start) }),
              let block = day.blocks.first(where: { $0.kind == .task(id) && $0.start == start && $0.end == end })
        else { throw TimelineResizeError.changed }
        let desiredEnd = start.addingTimeInterval(Double(minutes) * 60)
        guard let dayEnd = calendar.dateInterval(of: .day, for: start)?.end, desiredEnd <= dayEnd else {
            throw TimelineResizeError.doesNotFit
        }
        var result = tasks
        if !result.contains(where: { $0.id == id }) {
            // Detach just this generated occurrence. Its nominal day is skipped by the series on subsequent projections.
            guard let preview = days.lazy.flatMap(\.projectedTasks).first(where: { $0.id == id }),
                  returnToDrawer(id, in: &result, projected: preview, from: start, at: now, calendar: calendar),
                  let index = result.firstIndex(where: { $0.id == id }) else { throw TimelineResizeError.changed }
            result[index].inboxOnly = nil
            result[index].plannedStart = preview.plannedStart
            result[index].assignedFocusBlockID = preview.assignedFocusBlockID
        }
        guard let index = result.firstIndex(where: { $0.id == id && !$0.done && $0.archived != true && !$0.isInboxOnly })
        else { throw TimelineResizeError.unavailable }
        let delta = minutes - block.minutes
        guard (1...1440).contains(result[index].minutes + delta) else { throw TimelineResizeError.doesNotFit }
        let hasEarlierSlice = days.flatMap(\.blocks).contains { $0.kind == .task(id) && $0.start < start }
        if !hasEarlierSlice {
            let assignment = result[index].assignedFocusBlockID
            result[index].moveOccurrence(to: start, originalDay: start, calendar: calendar)
            result[index].assignedFocusBlockID = assignment
        }
        if (result[index].repeated ?? .once) == .once {
            let estimate = result[index].originalMinutes ?? result[index].minutes
            result[index].originalMinutes = min(1440, max(1, estimate + delta))
        }
        result[index].resizeRemaining(by: delta)
        result[index].setTimelineDuration(minutes, on: start, calendar: calendar)
        return result
    }
}
