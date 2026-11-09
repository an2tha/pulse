import Foundation

extension Planner {
    /// Each returned block is an alternative starting now. Its entire remaining task estimate fits.
    public static func spareMoments(
        at now: Date, minutes: Int, tasks: [PlanTask], commitments: [Commitment], reports: [CheckIn],
        dailyLimit: Int, usedMinutes: Int = 0, recovery: DateInterval? = nil,
        preferences: PlannerPreferences = .init(), calendar: Calendar = .current
    ) -> [Block] {
        let preferences = preferences.respectingBoostPins(tasks, calendar: calendar)
        let tasks = tasks.resolvingPreparations(with: commitments, bufferMinutes: preferences.bufferMinutes, calendar: calendar)
        let workEnd = preferences.workEnd(on: now, calendar: calendar)
        guard minutes > 0, now < workEnd,
            recoveryInterval(recovery, at: now, commitments: commitments, calendar: calendar) == nil
        else { return [] }
        let occupied = workExclusions(
            at: now, commitments: commitments, reports: reports, preferences: preferences, calendar: calendar)
        guard !occupied.contains(where: { $0.start <= now && now < $0.end }) else { return [] }

        let tuning = preferences.tuning.flatMap { calendar.isDate($0.date, inSameDayAs: now) ? $0 : nil }
        let limit = Capacity.workloadLimit(userLimit: dailyLimit, reports: reports, at: now, calendar: calendar)
        var room = (tuning?.minimumDay == true ? min(5, limit) : limit) - max(0, usedMinutes)
        guard room > 0 else { return [] }
        func capacity(at time: Date) -> Double {
            preferences.capacity(at: time, reports: reports, calendar: calendar)
        }

        let finished = Set(tasks.filter(\.done).map(\.id))
        var pending = tasks.filter { !$0.done && !$0.isInboxOnly && $0.archived != true && ($0.dependency.map(finished.contains) ?? true) }
        let windows = preferences.taskWindows(pending, on: now, calendar: calendar)
        placeInFocusTime(&pending, at: now, until: workEnd, room: room, occupied: occupied, windows: windows,
                         finished: finished, nextTaskID: nil, preferences: preferences, reports: reports, calendar: calendar)
        let futurePins = futureReservations(pending, after: now, until: workEnd, finished: finished, windows: windows)
        let nextCommitment = occupied.first { $0.start > now }?.start ?? workEnd
        let gap = min(workEnd, nextCommitment, futurePins.first?.start ?? workEnd).timeIntervalSince(now)
        let due = pending.filter { $0.plannedStart != nil && $0.earliest <= now && windows.allows($0, at: now) }
            .sorted { $0.earliest < $1.earliest }
        let duePin = due.first { $0.pinStarts(at: now) } ?? due.first
        if duePin?.pinStarts(at: now) != true {
            let held = reservedMinutes(for: futurePins, occupied: occupied, dayEnd: workEnd, room: room,
                                       windows: windows, calendar: calendar, capacity: capacity)
            guard tuning?.minimumDay != true || held == 0 else { return [] }
            room -= held
        }
        let choices = duePin.map { [$0] } ?? pending.filter { $0.earliest <= now }
        let energy = capacity(at: now)
        let available = Capacity.block(minutes: minutes, capacity: energy, limit: min(room, Int(gap / 60)))
        let matches = choices.filter { $0.minutes <= available && windows.allows($0, at: now, seconds: Double($0.minutes) * 60) }
        let ranks = Dictionary(preferences.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let preferencesByCategory = Dictionary(uniqueKeysWithValues: Category.allCases.map {
            ($0, preferences.preference(for: $0, at: now))
        })
        return matches.sorted { first, second in
            let left = ranks[first.id] ?? .max
            let right = ranks[second.id] ?? .max
            if left != right { return left < right }
            let lhs = Capacity.priority(first, capacity: energy, at: now) + (preferencesByCategory[first.category] ?? 0)
            let rhs = Capacity.priority(second, capacity: energy, at: now) + (preferencesByCategory[second.category] ?? 0)
            return lhs > rhs
        }.map {
            Block(kind: .task($0.id), title: $0.title, start: now, end: now.addingTimeInterval(Double($0.minutes) * 60))
        }
    }
}
