import Foundation

/// A weekly or single-date time block expressed in local wall-clock time.
public struct WeeklyTimeBlock: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case protected, focus }
    public enum Role: String, Sendable { case protected, focus, boost }
    public let id: UUID
    public var kind: Kind
    public var title: String
    public var hours: TaskAvailability
    public var boostActivityID: UUID?
    public private(set) var singleDay: Int?

    /// First eligible opening for a recurring block. Older weekly rules have no lower bound.
    public private(set) var firstDay: Int?
    /// Inclusive civil date of the last opening. An overnight occurrence may finish the next day.
    public private(set) var lastDay: Int?

    public mutating func setSingleDate(_ date: Date?, calendar: Calendar = .current) {
        singleDay = date.map { Self.civilDay($0, in: calendar) }
        if date != nil { firstDay = nil; lastDay = nil }
    }

    public mutating func setFirstDate(_ date: Date?, calendar: Calendar = .current) {
        firstDay = date.map { Self.civilDay($0, in: calendar) }
        if date != nil { singleDay = nil }
    }

    public mutating func setLastDate(_ date: Date?, calendar: Calendar = .current) {
        lastDay = date.map { Self.civilDay($0, in: calendar) }
        if date != nil { singleDay = nil }
    }

    public func lastDate(in calendar: Calendar = .current) -> Date? {
        Self.civilDate(lastDay, in: calendar)
    }

    public var hasValidDates: Bool {
        if singleDay != nil { return singleDate() != nil && firstDay == nil && lastDay == nil }
        if firstDay != nil && firstDate() == nil || lastDay != nil && lastDate() == nil { return false }
        if let firstDay, let lastDay { return firstDay <= lastDay }
        return true
    }

    public func singleDate(in calendar: Calendar = .current) -> Date? {
        Self.civilDate(singleDay, in: calendar)
    }

    public func firstDate(in calendar: Calendar = .current) -> Date? {
        Self.civilDate(firstDay, in: calendar)
    }

    private static func civilDay(_ date: Date, in calendar: Calendar) -> Int {
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let parts = civil.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private static func civilDate(_ key: Int?, in calendar: Calendar) -> Date? {
        guard let key, (10_101...99_991_231).contains(key) else { return nil }
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let parts = DateComponents(year: key / 10000, month: key / 100 % 100, day: key % 100)
        return parts.isValidDate(in: civil) ? civil.date(from: parts) : nil
    }

    func appliesOn(_ date: Date, calendar: Calendar) -> Bool {
        if let singleDay { return Self.civilDay(date, in: calendar) == singleDay }
        guard hours.weekdays.contains(calendar.component(.weekday, from: date)) else { return false }
        if firstDay == nil && lastDay == nil { return true }
        let key = Self.civilDay(date, in: calendar)
        if let firstDay, key < firstDay { return false }
        if let lastDay, key > lastDay { return false }
        return true
    }

    public func blocks(on day: DateInterval, calendar: Calendar = .current) -> [Block] {
        let role: Role = kind == .focus ? .focus : .protected
        return intervals(on: day, calendar: calendar).map {
            Block(kind: .timeBlock(id, role), title: displayTitle, start: $0.start, end: $0.end)
        }
    }

    func intervals(on day: DateInterval, calendar: Calendar) -> [DateInterval] {
        guard singleDay != nil || firstDay != nil || lastDay != nil else {
            return hours.intervals(on: day, calendar: calendar)
        }
        var eligible: Set<Int> = []
        if appliesOn(day.start, calendar: calendar) { eligible.insert(calendar.component(.weekday, from: day.start)) }
        if hours.endMinute <= hours.startMinute && hours.endMinute > 0 {
            let previous = day.start.addingTimeInterval(-1)
            if appliesOn(previous, calendar: calendar) { eligible.insert(calendar.component(.weekday, from: previous)) }
        }
        return TaskAvailability(weekdays: eligible, startMinute: hours.startMinute, endMinute: hours.endMinute)?
            .intervals(on: day, calendar: calendar) ?? []
    }

    public func focusWindow(containing pin: Date, calendar: Calendar = .current) -> DateInterval? {
        guard kind == .focus, let day = calendar.dateInterval(of: .day, for: pin) else { return nil }
        return intervals(on: day, calendar: calendar).first { $0.start <= pin && pin < $0.end }
    }

    fileprivate func openings(on day: DateInterval, calendar: Calendar) -> [DateInterval] {
        guard appliesOn(day.start, calendar: calendar) else { return [] }
        let weekday = calendar.component(.weekday, from: day.start)
        return TaskAvailability(weekdays: [weekday], startMinute: hours.startMinute, endMinute: hours.endMinute)?
            .intervals(on: day, calendar: calendar) ?? []
    }

    func opens(at date: Date, calendar: Calendar) -> Bool {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return false }
        return openings(on: day, calendar: calendar).contains { $0.start == date }
    }

    /// The next actual opening, excluding the clipped continuation of an overnight window.
    public func nextOpening(after date: Date, calendar: Calendar = .current) -> Date? {
        let first = max(date, singleDate(in: calendar) ?? firstDate(in: calendar) ?? date)
        guard var day = calendar.dateInterval(of: .day, for: first) else { return nil }
        for _ in 0...7 {
            if let opening = openings(on: day, calendar: calendar).first(where: { $0.start > date }) {
                return opening.start
            }
            guard let next = calendar.dateInterval(of: .day, for: day.end) else { break }
            day = next
        }
        return nil
    }

    public init(id: UUID = UUID(), kind: Kind, title: String = "", hours: TaskAvailability, boostActivityID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.hours = hours
        self.boostActivityID = kind == .focus ? boostActivityID : nil
    }

    public var displayTitle: String {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? (kind == .focus ? "Focus time" : "Protected time") : label
    }
}

extension PlanTask {
    public var fitsDedicatedFocus: Bool { category == .focus || category == .study }
}

extension PlannerPreferences {
    public func respectingBoostPins(_ tasks: [PlanTask], calendar: Calendar = .current) -> Self {
        guard boostPins == nil, timeBlocks.contains(where: { $0.kind == .focus && $0.boostActivityID != nil }) else { return self }
        var copy = self
        copy.boostPins = Self.eligibleBoostPins(tasks, calendar: calendar)
        return copy
    }

    private static func eligibleBoostPins(_ tasks: [PlanTask], calendar: Calendar) -> [DateInterval] {
        let completed = Set(tasks.filter(\.done).map(\.id))
        return tasks.compactMap { task in
            guard !task.done, task.archived != true, !task.isInboxOnly, let pin = task.plannedStart,
                  task.earliest <= pin, task.dependency.map(completed.contains) != false,
                  task.permitsRoutineWork(at: pin, calendar: calendar) else { return nil }
            if let hours = task.availability, hours.interval(containing: pin, calendar: calendar) == nil { return nil }
            return DateInterval(start: pin, duration: task.remainingSeconds)
        }
    }

    /// Continuous free time ending at this exact opening. Replace the stored rule
    /// with the edited version and keep every other rule's reserved preparation.
    public func preFocusMinutes(for rule: WeeklyTimeBlock, opening: Date, at now: Date,
                                tasks: [PlanTask], commitments: [Commitment], reports: [CheckIn],
                                extraHolds: [DateInterval] = [], calendar: Calendar = .current) -> Int {
        guard opening > now, rule.kind == .focus, rule.opens(at: opening, calendar: calendar),
              capacity(at: opening, reports: reports, calendar: calendar) > 0 else { return 0 }
        var options = self
        var draft = rule
        draft.boostActivityID = nil
        options.timeBlocks.removeAll { $0.id == rule.id }
        options.timeBlocks.append(draft)
        let pins = Self.eligibleBoostPins(tasks, calendar: calendar)
        options.boostPins = pins

        var start = max(now, opening.addingTimeInterval(-240 * 60))
        func exclude(_ occupied: DateInterval) {
            if occupied.start < opening && start < occupied.end { start = min(opening, occupied.end) }
        }
        for hold in pins + extraHolds { exclude(hold) }
        var cursor = start
        while cursor <= opening, let day = calendar.dateInterval(of: .day, for: cursor) {
            var closed = Planner.workExclusions(at: cursor, commitments: commitments, bufferMinutes: bufferMinutes, calendar: calendar)
            closed += zeroEnergyWindows(on: cursor, reports: reports, calendar: calendar)
            if wrapUpMinute != nil {
                let end = workEnd(on: cursor, calendar: calendar)
                if end < day.end { closed.append(DateInterval(start: end, end: day.end)) }
            }
            let weekly = options.weeklyBlocks(on: cursor, commitments: commitments, reports: reports, calendar: calendar)
            for block in weekly {
                let interval = DateInterval(start: block.start, end: block.end)
                if case .timeBlock(_, .protected) = block.kind { closed.append(interval) }
                else { exclude(interval) }
            }
            if closed.contains(where: { $0.start <= opening && opening < $0.end }) { return 0 }
            for interval in closed { exclude(interval) }
            cursor = day.end
        }
        return Int(opening.timeIntervalSince(start) / 60)
    }

    func focusIntervals(on day: DateInterval, calendar: Calendar) -> [DateInterval] {
        Planner.mergedWindows(timeBlocks.filter { $0.kind == .focus }.flatMap { $0.intervals(on: day, calendar: calendar) }.sorted { $0.start < $1.start })
    }

    public func focusBoundary(for task: PlanTask, at date: Date, calendar: Calendar = .current) -> Date? {
        guard !timeBlocks.isEmpty, let day = calendar.dateInterval(of: .day, for: date) else { return nil }
        if let id = task.assignedFocusBlockID, let pin = task.plannedStart,
           let rule = timeBlocks.first(where: { $0.id == id && $0.kind == .focus }),
           let span = rule.focusWindow(containing: pin, calendar: calendar),
           span.start <= date && date < span.end { return span.end }
        for window in focusIntervals(on: day, calendar: calendar) where window.end > date {
            if window.start > date { return window.start }
            return task.fitsDedicatedFocus ? window.end : date
        }
        return nil
    }

    public func weeklyBlocks(on date: Date, commitments: [Commitment], reports: [CheckIn], calendar: Calendar = .current) -> [Block] {
        guard !timeBlocks.isEmpty, let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        var result = timeBlocks.flatMap { $0.blocks(on: day, calendar: calendar) }
        let focusRules = timeBlocks.filter { $0.kind == .focus && $0.boostActivityID != nil }
        guard !focusRules.isEmpty, let next = calendar.dateInterval(of: .day, for: day.end) else { return result }
        var usedBoosts: [DateInterval] = []
        for occurrenceDay in [day, next] {
            for rule in focusRules {
                guard let id = rule.boostActivityID, let activity = timeBlockBoosts[id] ?? EnergyActivity.presetBoosts.first(where: { $0.id == id }), activity.kind == .boost, activity.isValid else { continue }
                for opening in rule.openings(on: occurrenceDay, calendar: calendar) {
                    guard capacity(at: opening.start, reports: reports, calendar: calendar) > 0 else { continue }
                    let prep = DateInterval(start: opening.start.addingTimeInterval(Double(-activity.minutes) * 60), end: opening.start)
                    guard let part = prep.intersection(with: day), part.duration > 0,
                          !(boostPins ?? []).contains(where: { $0.start < prep.end && prep.start < $0.end }),
                          !usedBoosts.contains(where: { $0.start < prep.end && prep.start < $0.end }) else { continue }
                    var cursor = prep.start
                    var clear = true
                    while cursor <= prep.end, let local = calendar.dateInterval(of: .day, for: cursor) {
                        let fixed = Planner.workExclusions(at: cursor, commitments: commitments, bufferMinutes: bufferMinutes, calendar: calendar)
                        let unavailable = fixed + zeroEnergyWindows(on: cursor, reports: reports, calendar: calendar)
                        let protected = timeBlocks.filter { $0.kind == .protected }.flatMap { $0.intervals(on: local, calendar: calendar) }
                        if (unavailable + protected).contains(where: { $0.start <= opening.start && opening.start < $0.end ||
                            $0.start < prep.end && prep.start < $0.end }) ||
                            focusIntervals(on: local, calendar: calendar).contains(where: { $0.start < prep.end && prep.start < $0.end }) {
                            clear = false
                            break
                        }
                        cursor = local.end
                    }
                    if clear {
                        usedBoosts.append(prep)
                        result.append(Block(kind: .timeBlock(rule.id, .boost), title: activity.title, start: part.start, end: part.end))
                    }
                }
            }
        }
        return result
    }
}

extension Planner {
    /// Reserve unpinned Focus and Study work inside a chosen focus period.
    /// These starts exist only for this projection. Authored pins keep their time and budget.
    static func placeInFocusTime(_ tasks: inout [PlanTask], at now: Date, until end: Date, room: Int,
                                 occupied: [DateInterval], windows: DayTaskWindows, finished: Set<UUID>,
                                 nextTaskID: UUID?, preferences: PlannerPreferences, reports: [CheckIn], calendar: Calendar) {
        guard !preferences.timeBlocks.isEmpty, let day = calendar.dateInterval(of: .day, for: now) else { return }
        let focus = preferences.focusIntervals(on: day, calendar: calendar)
        guard !focus.isEmpty else { return }
        let prerequisites = Set(tasks.compactMap(\.dependency))
        var capacities: [Date: Double] = [:]
        func capacity(at start: Date) -> Double {
            if let cached = capacities[start] { return cached }
            let value = preferences.capacity(at: start, reports: reports, calendar: calendar)
            capacities[start] = value
            return value
        }
        var occupied = occupied
        var remaining = room
        for task in tasks where !task.done && task.archived != true && !task.isInboxOnly && (task.plannedStart != nil || task.id == nextTaskID) {
            guard task.dependency.map(finished.contains) != false,
                  let opening = windows.opening(for: task, atOrAfter: now, until: end) else { continue }
            let length = task.blockMinutes(at: opening.start, capacity: capacity(at: opening.start),
                                           limit: min(remaining, Int(opening.duration / 60)), calendar: calendar)
            remaining -= length
            occupied.append(DateInterval(start: opening.start, duration: Double(length) * 60))
        }
        guard remaining > 0 else { return }
        occupied = mergedWindows(occupied.sorted { $0.start < $1.start })
        for window in focus where window.end > now {
            var cursor = Date(timeIntervalSince1970: ceil(max(now, window.start).timeIntervalSince1970 / 60) * 60)
            let close = min(end, window.end)
            while cursor < close, remaining > 0 {
                if Task.isCancelled { return }
                if let busy = occupied.first(where: { $0.start <= cursor && cursor < $0.end }) { cursor = busy.end; continue }
                let freeEnd = min(close, occupied.first(where: { $0.start > cursor })?.start ?? close)
                var choice: (index: Int, start: Date, length: Int, priority: Double)?
                for i in tasks.indices {
                    let task = tasks[i]
                    guard !task.done, task.archived != true, !task.isInboxOnly, task.plannedStart == nil, task.fitsDedicatedFocus, task.id != nextTaskID, !prerequisites.contains(task.id),
                          task.dependency.map(finished.contains) != false,
                          let opening = windows.opening(for: task, atOrAfter: cursor, until: freeEnd) else { continue }
                    let start = opening.start
                    guard task.due.map({ start.addingTimeInterval(task.remainingSeconds) <= $0 }) != false else { continue }
                    let cap = capacity(at: start)
                    let length = task.blockMinutes(at: start, capacity: cap, limit: min(remaining, Int(opening.duration / 60)), calendar: calendar)
                    guard length > 0 else { continue }
                    let priority = Capacity.priority(task, capacity: cap, at: start) + preferences.preference(for: task.category, at: start)
                    if let other = choice, other.start < start || (other.start == start && other.priority >= priority) { continue }
                    choice = (i, start, length, priority)
                }
                guard let choice else { cursor = freeEnd; continue }
                tasks[choice.index].plannedStart = choice.start
                remaining -= choice.length
                cursor = choice.start.addingTimeInterval(Double(choice.length) * 60)
            }
        }
    }
}
