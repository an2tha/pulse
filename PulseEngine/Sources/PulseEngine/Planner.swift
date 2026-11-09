import Foundation

extension PlanTask {
    /// The scheduler places work on minute boundaries. A missed reservation can
    /// use spare time while an on-time reservation keeps its place and budget.
    public func pinStarts(at time: Date) -> Bool {
        guard let plannedStart else { return false }
        let delay = time.timeIntervalSince(plannedStart)
        return delay >= 0 && delay < 60
    }
}

public struct Block: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case task(UUID)
        case fixed(UUID)
        case timeBlock(UUID, WeeklyTimeBlock.Role)
        case rest
    }
    public var kind: Kind
    public var title: String
    public var start, end: Date
    public var id: String {
        if case .task(let id) = kind { return id.uuidString }
        return "\(kind)-\(start.timeIntervalSince1970)"
    }
    public var minutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
}

public enum Planner {
    /// A break ends at the next fixed commitment or local midnight, whichever comes first.
    public static func recoveryInterval(
        _ requested: DateInterval?, at now: Date, commitments: [Commitment],
        calendar: Calendar = .current
    ) -> DateInterval? {
        guard let requested, requested.start <= now, now < requested.end,
            let day = calendar.dateInterval(of: .day, for: requested.start), now < day.end
        else { return nil }
        var end = min(day.end, requested.end)
        for event in commitments {
            for interval in event.intervals(on: requested.start, calendar: calendar)
            where interval.end > requested.start {
                end = min(end, interval.start)
            }
        }
        return end > now ? DateInterval(start: requested.start, end: end) : nil
    }

    /// Includes the transition into an early appointment tomorrow and out of a late appointment yesterday.
    public static func workExclusions(
        at now: Date, commitments: [Commitment], bufferMinutes: Int, calendar: Calendar = .current
    ) -> [DateInterval] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        let buffer = Double(min(30, max(0, bufferMinutes))) * 60
        let dates = buffer > 0 ? [day.start.addingTimeInterval(-1), now, day.end] : [now]
        let windows = commitments.flatMap { event in
            dates.flatMap { event.intervals(on: $0, calendar: calendar) }
        }.compactMap { interval -> DateInterval? in
            let start = max(day.start, interval.start.addingTimeInterval(-buffer))
            let end = min(day.end, interval.end.addingTimeInterval(buffer))
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }

        return mergedWindows(windows)
    }

    public static func workExclusions(at date: Date, commitments: [Commitment], reports: [CheckIn],
                                      preferences: PlannerPreferences, calendar: Calendar = .current) -> [DateInterval] {
        let weekly = preferences.weeklyBlocks(on: date, commitments: commitments, reports: reports, calendar: calendar)
        return workExclusions(at: date, commitments: commitments, reports: reports, preferences: preferences, weekly: weekly, calendar: calendar)
    }

    private static func workExclusions(at date: Date, commitments: [Commitment], reports: [CheckIn], preferences: PlannerPreferences,
                                       weekly: [Block], calendar: Calendar) -> [DateInterval] {
        let busy = workExclusions(at: date, commitments: commitments, bufferMinutes: preferences.bufferMinutes, calendar: calendar)
        let weekly = weekly.compactMap { block -> DateInterval? in
            guard case .timeBlock(_, let role) = block.kind, role != .focus else { return nil }
            return DateInterval(start: block.start, end: block.end)
        }
        guard !preferences.expectations.isEmpty || !weekly.isEmpty else { return busy }
        let energy = preferences.zeroEnergyWindows(on: date, reports: reports, calendar: calendar)
        return mergedWindows((busy + weekly + energy).sorted { $0.start < $1.start })
    }

    static func mergedWindows(_ windows: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for window in windows {
            if let last = merged.last, window.start <= last.end {
                merged[merged.count - 1].end = max(last.end, window.end)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    struct PinReservation {
        let task: PlanTask
        let start: Date
    }

    static func futureReservations(_ tasks: [PlanTask], after cursor: Date, until end: Date,
                                   finished: Set<UUID>, windows: DayTaskWindows) -> [PinReservation] {
        tasks.compactMap { task in
            guard task.plannedStart != nil, task.dependency.map(finished.contains) != false,
                  let opening = windows.opening(for: task, atOrAfter: cursor, until: end),
                  opening.start > cursor else { return nil }
            return PinReservation(task: task, start: opening.start)
        }.sorted { $0.start < $1.start }
    }

    /// Protect only the part of a pin that fits its allowed hours, adjacent pins and commitments.
    static func reservedMinutes(
        for pins: [PinReservation], occupied: [DateInterval], dayEnd: Date, room: Int,
        windows: DayTaskWindows, calendar: Calendar = .current, capacity: (Date) -> Double
    ) -> Int {
        var reserved = 0
        var cursor = pins.first?.start ?? dayEnd
        for (index, pin) in pins.enumerated() {
            var candidate = max(pin.start, cursor)
            while let opening = windows.opening(for: pin.task, atOrAfter: candidate, until: dayEnd) {
                if let busy = occupied.first(where: { $0.start <= opening.start && opening.start < $0.end }) {
                    candidate = busy.end
                    continue
                }
                let nextBusy = occupied.first(where: { $0.start > opening.start })?.start ?? dayEnd
                let nextPin = pins.dropFirst(index + 1).first(where: { $0.start > opening.start })?.start ?? dayEnd
                let gap = Int(min(opening.end, nextBusy, nextPin).timeIntervalSince(opening.start) / 60)
                let length = pin.task.blockMinutes(at: opening.start, capacity: capacity(opening.start),
                                                   limit: min(gap, room - reserved), calendar: calendar)
                reserved += length
                if reserved == room { return room }
                cursor = opening.start.addingTimeInterval(Double(length) * 60)
                break
            }
        }
        return reserved
    }

    public static func schedule(
        at now: Date, tasks: [PlanTask], commitments: [Commitment], reports: [CheckIn], dailyLimit: Int,
        usedMinutes: Int = 0, breaks: Bool = true, recovery: DateInterval? = nil,
        nextTaskID: UUID? = nil,
        preferences: PlannerPreferences = .init(),
        calendar: Calendar = .current
    ) -> [Block] {
        guard !Task.isCancelled else { return [] }
        let preferences = preferences.preparingVotes().respectingBoostPins(tasks, calendar: calendar)
        let weekly = preferences.weeklyBlocks(on: now, commitments: commitments, reports: reports, calendar: calendar)
        let occupied = workExclusions(
            at: now, commitments: commitments, reports: reports, preferences: preferences,
            weekly: weekly, calendar: calendar)
        let fixed = commitments.flatMap { item in
            item.intervals(on: now, calendar: calendar).filter { $0.end > now }.map { interval in
                Block(kind: .fixed(item.id), title: item.title, start: interval.start, end: interval.end)
            }
        }.sorted { $0.start < $1.start }
        let rest =
            breaks
            ? recoveryInterval(recovery, at: now, commitments: commitments, calendar: calendar) : nil
        var output = fixed + weekly.filter { $0.end > now }
        if let rest {
            output.append(Block(kind: .rest, title: "Breathing room", start: rest.start, end: rest.end))
        }
        let budget = Capacity.workloadLimit(
            userLimit: dailyLimit, reports: reports, at: now, calendar: calendar)
        let tuning = preferences.tuning.flatMap {
            calendar.isDate($0.date, inSameDayAs: now) ? $0 : nil
        }
        let minimumDay = tuning?.minimumDay == true
        var room = max(0, (minimumDay ? min(5, budget) : budget) - usedMinutes)
        var order: [UUID: Int] = [:]
        for (i, id) in preferences.order.enumerated() where order[id] == nil { order[id] = i }
        var finished = Set(tasks.filter(\.done).map(\.id))
        var pending = tasks.compactMap { task -> PlanTask? in
            guard !task.done, !task.isInboxOnly, task.archived != true else { return nil }
            return task.planningCopy(with: commitments, bufferMinutes: preferences.bufferMinutes, calendar: calendar)
        }
        let dayEnd = preferences.workEnd(on: now, calendar: calendar)
        let windows = preferences.taskWindows(pending, on: now, calendar: calendar)
        var cursor = Date(
            timeIntervalSince1970: ceil((rest?.end ?? now).timeIntervalSince1970 / 60) * 60)
        placeInFocusTime(&pending, at: cursor, until: dayEnd, room: room, occupied: occupied, windows: windows,
                         finished: finished, nextTaskID: nextTaskID, preferences: preferences, reports: reports, calendar: calendar)
        while room > 0, cursor < dayEnd, !pending.isEmpty {
            guard !Task.isCancelled else { return [] }
            if let busy = occupied.first(where: { $0.start <= cursor && $0.end > cursor }) {
                cursor = busy.end
                continue
            }
            let available = pending.filter { task in
                task.earliest <= cursor && (task.dependency.map(finished.contains) ?? true) && windows.allows(task, at: cursor)
            }
            func capacity(at time: Date) -> Double {
                preferences.capacity(at: time, reports: reports, calendar: calendar)
            }
            let cap = capacity(at: cursor)
            if cap <= 0 {
                // An unavailable hour does not close the whole day. A later
                // reading or forecast can open another real scheduling window.
                let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end ?? dayEnd
                let report = reports.lazy.map(\.date).filter { $0 > cursor && $0 < hourEnd }.min()
                let edit = preferences.corrections.lazy.map(\.date).filter { $0 > cursor && $0 < hourEnd }.min()
                cursor = min(hourEnd, report ?? hourEnd, edit ?? hourEnd, dayEnd)
                continue
            }
            let futurePins = futureReservations(pending, after: cursor, until: dayEnd, finished: finished, windows: windows)
            let nextPin = futurePins.first?.start ?? dayEnd
            let nextBoundary = min(nextPin, occupied.first(where: { $0.start > cursor })?.start ?? dayEnd)
            let gap = Int(nextBoundary.timeIntervalSince(cursor) / 60)
            guard
                let choice = available.min(by: { a, b in
                    if (a.plannedStart != nil) != (b.plannedStart != nil) { return a.plannedStart != nil }
                    if let first = a.plannedStart, let second = b.plannedStart, first != second {
                        if a.pinStarts(at: cursor) != b.pinStarts(at: cursor) { return a.pinStarts(at: cursor) }
                        return first < second
                    }
                    if a.id == nextTaskID || b.id == nextTaskID { return a.id == nextTaskID }
                    if order[a.id] != order[b.id] { return (order[a.id] ?? .max) < (order[b.id] ?? .max) }
                    return Capacity.priority(a, capacity: cap, at: cursor)
                        + preferences.preference(for: a.category, at: cursor)
                        > Capacity.priority(b, capacity: cap, at: cursor)
                        + preferences.preference(for: b.category, at: cursor)
                })
            else {
                let next = pending.compactMap { task -> Date? in
                    guard task.dependency.map(finished.contains) != false else { return nil }
                    return windows.opening(for: task, atOrAfter: cursor, until: dayEnd)?.start
                }.filter { $0 > cursor }.min()
                guard let next else { break }
                cursor = next
                continue
            }
            let held =
                !choice.pinStarts(at: cursor)
                ? reservedMinutes(
                    for: futurePins, occupied: occupied, dayEnd: dayEnd, room: room, windows: windows, calendar: calendar, capacity: capacity)
                : 0
            if held == room || (minimumDay && held > 0) {
                cursor = nextPin
                continue
            }
            let close = windows.opening(for: choice, atOrAfter: cursor, until: dayEnd)?.end ?? dayEnd
            let duration = choice.blockMinutes(
                at: cursor, capacity: cap, limit: min(room - held, gap, Int(close.timeIntervalSince(cursor) / 60)), calendar: calendar)
            guard duration > 0 else {
                if gap == 0 {
                    cursor = nextBoundary
                    continue
                }
                break
            }
            let end = cursor.addingTimeInterval(Double(duration) * 60)
            output.append(Block(kind: .task(choice.id), title: choice.title, start: cursor, end: end))
            pending.removeAll { $0.id == choice.id }
            if duration == choice.minutes { finished.insert(choice.id) }
            if minimumDay { break }
            room -= duration
            cursor = end
            let breakEnd = end.addingTimeInterval(300)
            // Completing this task may have just made a previously blocked pin available.
            if breaks, room > 0, !pending.isEmpty, breakEnd <= nextBoundary,
               !pending.contains(where: { task in
                   task.plannedStart != nil && task.dependency.map(finished.contains) != false
                       && (windows.opening(for: task, atOrAfter: end, until: dayEnd)?.start ?? dayEnd) < breakEnd
               }) {
                cursor = breakEnd
                output.append(Block(kind: .rest, title: "Breathing room", start: end, end: cursor))
            }
        }
        // Keep recovery time between planned blocks, without a trailing break
        // when every remaining dependency is blocked or deferred.
        if let lastTask = output.last(where: { if case .task = $0.kind { true } else { false } }) {
            output.removeAll { $0.kind == .rest && $0.start >= lastTask.end }
        }
        return output.sorted { $0.start < $1.start }
    }
}
