import Foundation

public struct WeekRemainder: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case earliest(Date), prerequisite(UUID), preparation(Date), availability, zeroLimit, atCapacity, noFurtherBlock
    }
    public let id: UUID
    public let plannedMinutes: Int
    /// Estimated work still outside the displayed projection, rounded up to a minute.
    public let remainingMinutes: Int
    public let reason: Reason
}

extension WeekOutlook {
    /// Read the completed projection without reranking tasks or testing placements.
    /// The result preserves input order and includes only real unfinished tasks.
    public static func remaining(
        in days: [OutlookDay], tasks: [PlanTask], at now: Date, commitments: [Commitment] = [],
        dailyLimit: Int, preferences: PlannerPreferences = .init(), calendar: Calendar = .current
    ) -> [WeekRemainder] {
        guard !Task.isCancelled, days.count == 7, let first = calendar.dateInterval(of: .day, for: now) else { return [] }
        var boundaries: [DateInterval] = []
        var start = first.start
        for day in days {
            guard calendar.isDate(day.date, inSameDayAs: start),
                  let interval = calendar.dateInterval(of: .day, for: start) else { return [] }
            boundaries.append(interval)
            start = interval.end
        }
        let horizonEnd = start
        let previews = Set(days.flatMap(\.projectedTasks).map(\.id))
        let open = tasks.filter { !$0.done && $0.archived != true && !$0.isInboxOnly && !previews.contains($0.id) }
        guard !open.isEmpty else { return [] }
        var planned: [UUID: TimeInterval] = [:]
        var past: [UUID: TimeInterval] = [:]
        var busy: [DateInterval] = []
        var atCapacity = dailyLimit > 0
        let buffer = Double(min(30, max(0, preferences.bufferMinutes))) * 60
        for (day, bounds) in zip(days, boundaries) {
            var work: TimeInterval = 0
            for block in day.blocks {
                let from = max(block.start, bounds.start)
                let to = min(block.end, bounds.end)
                guard to > from else { continue }
                switch block.kind {
                case .task(let id):
                    planned[id, default: 0] += to.timeIntervalSince(from)
                    if from < now { past[id, default: 0] += min(now, to).timeIntervalSince(from) }
                    work += to.timeIntervalSince(from)
                case .fixed:
                    busy.append(DateInterval(start: from.addingTimeInterval(-buffer), end: to.addingTimeInterval(buffer)))
                case .timeBlock(_, .boost), .timeBlock(_, .protected):
                    busy.append(DateInterval(start: from, end: to))
                case .timeBlock(_, .focus), .rest: break
                }
            }
            if work < Double(dailyLimit) * 60 { atCapacity = false }
        }
        let truncated = open.filter { $0.remainingSeconds > (planned[$0.id] ?? 0) }
        guard !truncated.isEmpty else { return [] }

        let referenced = Set(truncated.compactMap(\.dependency))
        var unmet = referenced
        var seen = Set<UUID>()
        func inspectPrerequisite(_ task: PlanTask) {
            guard referenced.contains(task.id), seen.insert(task.id).inserted else { return }
            if task.done || (planned[task.id] ?? 0) >= task.remainingSeconds { unmet.remove(task.id) }
        }
        if !referenced.isEmpty {
            tasks.forEach(inspectPrerequisite)
            for day in days { day.projectedTasks.forEach(inspectPrerequisite) }
            // A caller may have omitted an active task. Its scheduled work alone
            // cannot prove it remains unfinished without its remaining estimate.
            for id in referenced where !seen.contains(id) && planned[id] != nil { unmet.remove(id) }
        }
        let needsAppointments = truncated.contains { $0.preparation != nil }
        let events = needsAppointments ? Dictionary(commitments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        busy.sort { $0.start < $1.start }
        var free: [[DateInterval]] = []
        if needsAppointments || truncated.contains(where: { $0.availability != nil }) {
            for day in boundaries {
                var cursor = max(now, day.start)
                let end = min(day.end, preferences.workEnd(on: day.start, calendar: calendar))
                var windows: [DateInterval] = []
                for event in busy where cursor < end && event.end > cursor && event.start < end {
                    if event.start > cursor { windows.append(DateInterval(start: cursor, end: event.start)) }
                    cursor = max(cursor, event.end)
                }
                if cursor < end { windows.append(DateInterval(start: cursor, end: end)) }
                free.append(windows)
            }
        }
        let unrestricted = free.flatMap { $0 }
        var windowCache: [TaskAvailability: [DateInterval]] = [:]
        func hours(for rule: TaskAvailability?) -> [DateInterval] {
            guard let rule else { return unrestricted }
            if let cached = windowCache[rule] { return cached }
            var result: [DateInterval] = []
            for (day, openings) in zip(boundaries, free) {
                for window in rule.intervals(on: day, calendar: calendar) {
                    for available in openings {
                        if let overlap = window.intersection(with: available), overlap.duration > 0 { result.append(overlap) }
                    }
                }
            }
            windowCache[rule] = result
            return result
        }

        var result: [WeekRemainder] = []
        result.reserveCapacity(truncated.count)
        for original in truncated {
            guard !Task.isCancelled else { return [] }
            let event = original.preparation.flatMap { events[$0.commitmentID] }
            let task = original.planningCopy(with: event.map { [$0] } ?? [], bufferMinutes: preferences.bufferMinutes, calendar: calendar)
            let placed = planned[task.id] ?? 0
            let missing = Int(ceil((task.remainingSeconds - placed) / 60))
            let reason: WeekRemainder.Reason
            let earliest = max(now, task.earliest)
            if task.earliest >= horizonEnd {
                reason = .earliest(task.earliest)
            } else if let cutoff = task.preparationCutoff(bufferMinutes: preferences.bufferMinutes), cutoff <= horizonEnd,
                      hours(for: task.availability).reduce(0.0, { sum, window in
                          guard task.permitsRoutineWork(at: window.start, calendar: calendar) else { return sum }
                          return sum + max(0, min(window.end, cutoff).timeIntervalSince(max(window.start, earliest)))
                      }) < task.remainingSeconds - (past[task.id] ?? 0) {
                reason = .preparation(cutoff)
            } else if placed == 0, let dependency = task.dependency, unmet.contains(dependency) {
                reason = .prerequisite(dependency)
            } else if dailyLimit <= 0 {
                reason = .zeroLimit
            } else if task.availability != nil, !hours(for: task.availability).contains(where: {
                $0.end.timeIntervalSince(max($0.start, earliest)) >= 60
                    && task.permitsRoutineWork(at: $0.start, calendar: calendar)
            }) {
                reason = .availability
            } else if atCapacity {
                reason = .atCapacity
            } else {
                reason = .noFurtherBlock
            }
            result.append(WeekRemainder(id: task.id, plannedMinutes: Int(ceil(task.remainingSeconds / 60)) - missing,
                                        remainingMinutes: missing, reason: reason))
        }
        return result
    }
}
