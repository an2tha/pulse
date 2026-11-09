import Foundation

extension PlanTask {
    public var hasValidRepeatDays: Bool {
        guard let repeatDays else { return true }
        return repeated == .daily && !repeatDays.isEmpty && repeatDays.allSatisfy((1...7).contains)
    }

    public func firstRepeatDay(onOrAfter date: Date, calendar: Calendar = .current) -> Date? {
        let reference = templatePin ?? routineAnchor ?? after ?? date
        return cadenceDay(from: max(calendar.startOfDay(for: date), calendar.startOfDay(for: reference)),
                          anchor: reference, includingStart: true, calendar: calendar)
    }

    /// Align a new routine, or a deliberate cadence edit. Move reminders by the
    /// same number of civil days as the occurrence, retaining their original offset.
    public mutating func alignFirstRepeatDay(at now: Date, calendar: Calendar = .current) {
        guard repeatDays != nil, hasValidRepeatDays, !done, archived != true,
              movedRoutineTimes?.pin == nil, movedRoutineTimes?.availability == nil else { return }
        let reference = max(plannedStart ?? .distantPast, after ?? .distantPast)
        let authoredDay = reference == .distantPast ? routineAnchor : reference
        let origin = authoredDay ?? now
        guard let first = firstRepeatDay(onOrAfter: max(now, origin), calendar: calendar),
              let shift = calendar.dateComponents([.day], from: calendar.startOfDay(for: origin), to: first).day else { return }
        if shift != 0 {
            if let pin = plannedStart { plannedStart = calendar.date(byAdding: .day, value: shift, to: pin) ?? pin }
            if authoredDay != nil, let notice = reminder {
                reminder = calendar.date(byAdding: .day, value: shift, to: notice) ?? notice
            }
        }
        if let earliest = after {
            if plannedStart == nil || calendar.isDate(earliest, inSameDayAs: origin) {
                after = calendar.date(byAdding: .day, value: shift, to: earliest) ?? earliest
            }
        } else if plannedStart == nil {
            after = first
        }
        // A materialized occurrence's UUID belongs to its original nominal date.
        if occurrence(in: calendar) == nil { routineAnchor = plannedStart ?? first }
    }

    /// A user-chosen deferral affects this occurrence; successors retain their own release clock.
    public mutating func deferOccurrence(until date: Date) {
        if repeated == .daily && repeatDays != nil {
            var times = movedRoutineTimes ?? MovedRoutineTimes()
            let original: Date?
            if let prior = times.availability, prior.moved == after { original = prior.original }
            else { original = after }
            times.availability = MovedRoutineTime(original: original, moved: date)
            movedRoutineTimes = times
        }
        after = date
    }

    public func permitsRoutineWork(at date: Date, calendar: Calendar = .current) -> Bool {
        guard repeated == .daily, repeatDays != nil else { return true }
        guard let day = calendar.dateInterval(of: .day, for: date) else { return false }
        return permitsRoutineWork(on: day, weekday: calendar.component(.weekday, from: date))
    }

    func permitsRoutineWork(on day: DateInterval, weekday: Int) -> Bool {
        guard repeated == .daily, let repeatDays else { return true }
        guard hasValidRepeatDays else { return false }
        if repeatDays.contains(weekday) { return true }
        if let override = movedRoutineTimes?.pin, override.moved == plannedStart,
           override.moved >= day.start && override.moved < day.end { return true }
        if let override = movedRoutineTimes?.availability, override.moved == after,
           override.moved >= day.start && override.moved < day.end { return true }
        return false
    }

    func matchesCadence(on day: Date, anchor: Date, calendar: Calendar) -> Bool {
        switch repeated {
        case .weekly:
            let distance = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor),
                                                    to: calendar.startOfDay(for: day)).day
            return distance?.isMultiple(of: 7) == true
        case .weekdays: return !calendar.isDateInWeekend(day)
        case .daily: return repeatDays?.contains(calendar.component(.weekday, from: day)) ?? true
        case .once, nil: return false
        }
    }

    func cadenceDay(from date: Date, anchor: Date, includingStart: Bool = false, backwards: Bool = false,
                    calendar: Calendar) -> Date? {
        guard let repeated, repeated != .once, hasValidRepeatDays else { return nil }
        let origin = calendar.startOfDay(for: anchor)
        let reference = calendar.startOfDay(for: date)
        guard let elapsed = calendar.dateComponents([.day], from: origin, to: reference).day else { return nil }
        let direction = backwards ? -1 : 1
        if repeated == .weekly {
            let residue = (elapsed % 7 + 7) % 7
            let distance = backwards ? residue : (7 - residue) % 7
            let step = distance == 0 && !includingStart ? 7 : distance
            return calendar.date(byAdding: .day, value: elapsed + direction * step, to: origin)
        }
        guard var candidate = calendar.date(byAdding: .day, value: elapsed + (includingStart ? 0 : direction),
                                            to: origin) else { return nil }
        for _ in 0..<7 {
            if matchesCadence(on: candidate, anchor: anchor, calendar: calendar) {
                return repeatDays == nil ? candidate : calendar.startOfDay(for: candidate)
            }
            guard let following = calendar.date(byAdding: .day, value: direction, to: candidate) else { break }
            candidate = following
        }
        return nil
    }

    func keepsRepeatException(_ move: RoutineException, calendar: Calendar) -> Bool {
        guard let rule = repeated, rule == move.occurrence.rule, (seriesID ?? id) == move.occurrence.seriesID,
              let nominal = move.occurrence.day(in: calendar),
              matchesCadence(on: nominal, anchor: templatePin ?? routineAnchor ?? after ?? nominal, calendar: calendar),
              let previous = cadenceDay(from: nominal, anchor: nominal, backwards: true, calendar: calendar),
              let next = cadenceDay(from: nominal, anchor: nominal, calendar: calendar) else { return false }
        return previous <= move.start && move.start < next
    }

    /// Remove only moves whose nominal day or neighboring bounds no longer fit the series.
    public mutating func pruneRepeatExceptions(calendar: Calendar = .current) {
        guard let saved = routineExceptions, !saved.isEmpty else { return }
        let retained = saved.filter { keepsRepeatException($0, calendar: calendar) }
        if retained != saved { routineExceptions = retained }
    }
}
