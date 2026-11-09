import Foundation

public struct TaskPlacement: Identifiable, Equatable, Sendable {
    public let start: Date
    public let originalStart: Date?
    public let projectedOccurrence: RoutineOccurrence?
    public let minutes: Int
    /// Week searches for dated tasks follow all remaining work through the seven-day horizon.
    public let projectedFinish: Date?
    public let capacity: Double
    public let forecastScore: Double?
    public let forecastSource: EnergySource?
    public enum EnergyBasis: Sendable { case capacity, manual, correction, expected, hour, day }
    public let energyBasis: EnergyBasis
    public let forecastIsDaily: Bool
    public let rankingCapacity: Double
    public fileprivate(set) var inFocusTime = false
    fileprivate let hasEnergyEvidence: Bool
    public fileprivate(set) var recommendedForDay = false
    public fileprivate(set) var recommended = false
    var skipTiming = SkipTimingAssessment()
    public var skipTimingReason: String? { skipTiming.energyReason ?? skipTiming.timeReason }
    public var id: Date { start }

    /// Compares feasible times by deadline, energy fit, then start time.
    public func isPreferred(to other: Self, for task: PlanTask) -> Bool {
        if let due = task.due {
            if (projectedFinish != nil) != (other.projectedFinish != nil) { return projectedFinish != nil }
            // Even without a finish in view, a start after the deadline already guarantees a delay.
            let earliest = projectedFinish ?? start.addingTimeInterval(task.remainingSeconds)
            let otherEarliest = other.projectedFinish ?? other.start.addingTimeInterval(task.remainingSeconds)
            let delay = max(0, earliest.timeIntervalSince(due))
            let otherDelay = max(0, otherEarliest.timeIntervalSince(due))
            if delay != otherDelay { return delay < otherDelay }
        }
        if inFocusTime != other.inFocusTime { return inFocusTime }
        // A shortfall is costlier than having spare energy. An easy task can use
        // a quieter hour, leaving the stronger hours open for demanding work.
        func mismatch(_ score: Double) -> Double {
            let difference = task.energyDemand - score
            return difference > 0 ? difference * 2 : -difference
        }
        // Prefer supported estimates when fits are close. A known severe
        // shortfall should not beat a plausible opening solely because it was logged.
        let fit = mismatch(rankingCapacity) + (hasEnergyEvidence ? 0 : 1) + skipTiming.penalty
        let otherFit = mismatch(other.rankingCapacity) + (other.hasEnergyEvidence ? 0 : 1) + other.skipTiming.penalty
        if fit != otherFit { return fit < otherFit }
        if hasEnergyEvidence != other.hasEnergyEvidence { return hasEnergyEvidence }
        if forecastIsDaily != other.forecastIsDaily { return !forecastIsDaily }
        return start < other.start
    }
}

extension Planner {
    /// One realizable start per remaining local hour, or a single requested time. Trials use the same
    /// scheduler as Plan, so priority, buffers and completed prerequisites apply.
    public static func placements(
        for taskID: UUID, at now: Date, tasks: [PlanTask], commitments: [Commitment],
        reports: [CheckIn], dailyLimit: Int, usedMinutes: Int = 0, breaks: Bool = true,
        recovery: DateInterval? = nil, nextTaskID: UUID? = nil,
        preferences: PlannerPreferences = .init(), calendar: Calendar = .current, forecast: EnergyTimeline? = nil,
        exactStart: Date? = nil, skipRecords: [TaskSkipRecord] = []
    ) -> [TaskPlacement] {
        let tasks = tasks.resolvingPreparations(with: commitments, bufferMinutes: preferences.bufferMinutes, calendar: calendar)
        guard !Task.isCancelled, let index = tasks.firstIndex(where: { $0.id == taskID && !$0.done && $0.archived != true }),
              let day = calendar.dateInterval(of: .day, for: now),
              let currentHour = calendar.dateInterval(of: .hour, for: now)
        else { return [] }
        let task = tasks[index]
        let preferences = preferences.respectingBoostPins(tasks, calendar: calendar).preparingHistory(reports, calendar: calendar)
            .preparingAvailability(tasks, on: [now], calendar: calendar)
        func schedule(_ input: [PlanTask]) -> [Block] {
            Planner.schedule(at: now, tasks: input, commitments: commitments, reports: reports,
                             dailyLimit: dailyLimit, usedMinutes: usedMinutes, breaks: breaks,
                             recovery: recovery, nextTaskID: nextTaskID, preferences: preferences, calendar: calendar)
        }
        let baseline = schedule(tasks)
        let original = baseline.first(where: { $0.kind == .task(taskID) })
        let pinnedIDs = Set(tasks.filter { $0.id != taskID && $0.plannedStart != nil }.map(\.id))
        let reserved = baseline.filter { if case .task(let id) = $0.kind { pinnedIDs.contains(id) } else { false } }
        let first = max(now, task.after ?? now, breaks ? (recoveryInterval(recovery, at: now, commitments: commitments, calendar: calendar)?.end ?? now) : now)
        return dayPlacements(task: task, original: original, day: day, first: first, hourStart: currentHour.start,
                             baseline: baseline, occupied: workExclusions(at: now, commitments: commitments,
                             reports: reports, preferences: preferences, calendar: calendar), reserved: reserved,
                             reports: reports, preferences: preferences, calendar: calendar, forecast: forecast, exactStart: exactStart,
                             skipProfile: SkipTimingProfile(records: skipRecords, calendar: calendar)) { start in
            var trial = tasks
            trial[index].moveOccurrence(to: start, originalDay: original?.start ?? now, calendar: calendar)
            return schedule(trial)
        } validate: { _, moved in
            .valid(finish: moved.minutes >= task.minutes ? moved.end : nil)
        }
    }

    private enum PlacementValidation {
        case valid(finish: Date?)
        case conflict
    }

    private static func dayPlacements(
        task: PlanTask, original: Block?, day: DateInterval, first: Date, hourStart: Date, baseline: [Block],
        occupied: [DateInterval], reserved: [Block], reports: [CheckIn], preferences: PlannerPreferences,
        calendar: Calendar, forecast: EnergyTimeline?, allowDailyForecast: Bool = false, projectedOccurrence: RoutineOccurrence? = nil,
        normalStart: Date? = nil, focusTarget: Block? = nil, exactStart: Date? = nil, skipProfile: SkipTimingProfile,
        schedule: (Date) -> [Block], validate: ([Block], Block) -> PlacementValidation
    ) -> [TaskPlacement] {
        let workEnd = preferences.workEnd(on: day.start, calendar: calendar)
        guard first < workEnd else { return [] }
        // A backlog item has no existing block to preserve. Still require a useful
        // first step, and use the actual duration from the planner for each option.
        let minimumMinutes = focusTarget.map { min($0.minutes, min(3, task.minutes)) } ?? original?.minutes ?? min(3, task.minutes)
        var starts = Set<Date>()
        func add(_ date: Date) {
            let minute = Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / 60) * 60)
            if minute >= first && minute < workEnd { starts.insert(minute) }
        }
        let openings = task.availability?.intervals(on: day, calendar: calendar)
        if let exactStart {
            guard exactStart >= first, exactStart < workEnd,
                  calendar.isDate(exactStart, inSameDayAs: day.start) else { return [] }
            starts.insert(exactStart)
        } else {
            if let openings {
                guard !openings.isEmpty else { return [] }
                for window in openings { add(window.start) }
            }
            add(first)
            if let focusTarget { add(focusTarget.start) }
            for interval in occupied { add(interval.end) }
            for block in baseline { add(block.start); add(block.end) }
            var tick = hourStart
            while tick < workEnd {
                add(tick)
                tick = tick.addingTimeInterval(300)
            }
        }
        var result: [TaskPlacement] = []
        var nextHour: Date = .distantPast
        let focus = task.fitsDedicatedFocus ? preferences.focusIntervals(on: day, calendar: calendar) : []
        for start in starts.sorted() {
            if Task.isCancelled { return [] }
            if let focusTarget, start < focusTarget.start || start >= focusTarget.end { continue }
            let inFocus = focusTarget != nil || focus.contains { $0.start <= start && start < $0.end }
            if let normalStart, start < normalStart && !inFocus { continue }
            let sameHour = start < nextHour
            if sameHour && (!inFocus || result.last?.inFocusTime != false) { continue }
            let end = start.addingTimeInterval(Double(minimumMinutes) * 60)
            guard end <= workEnd,
                  openings?.contains(where: { $0.start <= start && end <= $0.end }) != false,
                  !occupied.contains(where: { $0.start < end && $0.end > start }),
                  !reserved.contains(where: { $0.start < end && $0.end > start })
            else { continue }
            let plan = schedule(start)
            guard let moved = plan.first(where: { $0.kind == .task(task.id) }),
                  moved.start == start, moved.minutes >= minimumMinutes,
                  focusTarget.map({ moved.end <= $0.end }) != false,
                  reserved.allSatisfy({ pin in plan.contains { $0.kind == pin.kind && $0.start == pin.start && $0.end >= pin.end } }),
                  case .valid(let finish) = validate(plan, moved)
            else { continue }
            let capacity = preferences.capacity(at: start, reports: reports, calendar: calendar)
            let hourly = forecast?.estimate(at: start)
            let daily = hourly == nil && allowDailyForecast ? forecast?.daily(on: start) : nil
            let point = hourly ?? daily
            let forecastScore = point?.score
            let manual = preferences.tuning.map { calendar.isDate($0.date, inSameDayAs: start) && $0.manualCapacity != nil } ?? false
            let corrected = preferences.corrections.contains { $0.date <= start && calendar.isDate($0.date, equalTo: start, toGranularity: .hour) }
            let healthApplies = preferences.energyTimeline != nil && (!preferences.energyOnlyToday ||
                preferences.energyAsOf.map { calendar.isDate($0, inSameDayAs: start) } == true)
            let expected = EnergyExpectation.applicable(at: start, in: preferences.expectations, calendar: calendar)
            let rankingCapacity = manual || corrected || healthApplies || expected != nil ? capacity : (forecastScore ?? capacity)
            let basis: TaskPlacement.EnergyBasis
            if manual { basis = .manual }
            else if corrected { basis = .correction }
            else if let expected, expected.score == rankingCapacity { basis = .expected }
            else if forecastScore == rankingCapacity { basis = daily == nil ? .hour : .day }
            else { basis = .capacity }
            var candidate = TaskPlacement(start: start, originalStart: original?.start, projectedOccurrence: projectedOccurrence, minutes: moved.minutes, projectedFinish: finish, capacity: capacity,
                                        forecastScore: forecastScore, forecastSource: point?.source, energyBasis: basis,
                                        forecastIsDaily: daily != nil, rankingCapacity: rankingCapacity,
                                        inFocusTime: inFocus,
                                        hasEnergyEvidence: manual || corrected || expected != nil || forecastScore != nil)
            candidate.skipTiming = skipProfile.assessment(for: candidate)
            if sameHour, let prior = result.last {
                if candidate.isPreferred(to: prior, for: task) { result[result.count - 1] = candidate }
            } else {
                result.append(candidate)
            }
            nextHour = calendar.dateInterval(of: .hour, for: start)?.end ?? day.end
        }
        if let best = result.indices.min(by: { result[$0].isPreferred(to: result[$1], for: task) }) {
            result[best].recommendedForDay = true
            result[best].recommended = true
        }
        return result
    }
}

extension Planner {
    /// Focus attachments can be booked beyond the displayed week. Bound the daily
    /// replay for distant dates chosen in a calendar picker or restored from backup.
    public static let focusAssignmentLookaheadDays = 366

    /// Tests a single occurrence at candidate times over the displayed week. Earlier
    /// projected work is replayed with that occurrence held back until its candidate day.
    public static func weekPlacements(
        for taskID: UUID, at now: Date, tasks: [PlanTask], commitments: [Commitment],
        reports: [CheckIn], dailyLimit: Int, usedMinutes: Int = 0, breaks: Bool = true,
        recovery: DateInterval? = nil, nextTaskID: UUID? = nil, preferences: PlannerPreferences = .init(),
        calendar: Calendar = .current, forecast: EnergyTimeline? = nil, startHour: Int = 9,
        todayLimit: Int? = nil, sourceDay: Date? = nil, focusTarget: Block? = nil,
        priorPreferences: PlannerPreferences? = nil, exactStart: Date? = nil, skipRecords: [TaskSkipRecord] = []
    ) -> [TaskPlacement] {
        guard !Task.isCancelled else { return [] }
        let assignedID: UUID?
        if let focusTarget {
            guard case .timeBlock(let ruleID, .focus) = focusTarget.kind,
                  let day = calendar.dateInterval(of: .day, for: focusTarget.start),
                  preferences.timeBlocks.contains(where: { $0.id == ruleID && $0.blocks(on: day, calendar: calendar).contains(focusTarget) }) else { return [] }
            assignedID = ruleID
        } else { assignedID = nil }
        let tasks = tasks.resolvingPreparations(with: commitments, bufferMinutes: preferences.bufferMinutes, calendar: calendar)
        let existing = tasks.first { $0.id == taskID && !$0.done && $0.archived != true }
        guard existing != nil || sourceDay != nil else { return [] }
        let existingSeries = existing.flatMap { ($0.repeated ?? .once) == .once ? nil : ($0.seriesID ?? $0.id) }
        let today = calendar.startOfDay(for: now)
        if let exactStart {
            guard let distance = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: exactStart)).day,
                  (0..<7).contains(distance) else { return [] }
        }
        let lastDay = focusTarget.map { calendar.startOfDay(for: $0.start) } ?? today
        let distance = calendar.dateComponents([.day], from: today, to: lastDay).day ?? 0
        guard (0...focusAssignmentLookaheadDays).contains(distance) else { return [] }
        let dates = (0...max(6, distance)).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        // Only the candidate day repeats the same scheduling trials on a targeted
        // search. Other days resolve their windows on demand during the replay.
        let trialDates = focusTarget.map { _ in [lastDay] } ?? dates
        let preferences = preferences.respectingBoostPins(tasks, calendar: calendar).preparingHistory(reports, calendar: calendar)
            .preparingAvailability(tasks, on: trialDates, calendar: calendar)
        let baselineOptions = priorPreferences?.respectingBoostPins(tasks, calendar: calendar).preparingHistory(reports, calendar: calendar)
            .preparingAvailability(tasks, on: trialDates, calendar: calendar)
        func schedule(_ remaining: [PlanTask], on day: Date, with override: PlannerPreferences? = nil) -> [Block] {
            let preferences = override ?? preferences
            if day == today {
                return Planner.schedule(at: now, tasks: remaining, commitments: commitments, reports: reports,
                                        dailyLimit: todayLimit ?? dailyLimit, usedMinutes: usedMinutes,
                                        breaks: breaks, recovery: recovery, nextTaskID: nextTaskID,
                                        preferences: preferences, calendar: calendar)
            }
            return WeekOutlook.futureBlocks(on: day, tasks: remaining, events: commitments, reports: reports,
                                            limit: dailyLimit, breaks: breaks, preferences: preferences,
                                            startHour: startHour, calendar: calendar)
        }

        func protected(_ blocks: [Block], in remaining: [PlanTask]) -> [Block] {
            let pins = Set(remaining.filter {
                $0.id != taskID && $0.plannedStart != nil && ($0.seriesID ?? $0.id) != existingSeries
            }.map(\.id))
            return blocks.filter { block in
                if case .task(let id) = block.kind { return pins.contains(id) }
                return false
            }
        }
        func retained(_ required: [Block], by actual: [Block]) -> Bool {
            required.allSatisfy { pin in actual.contains { $0.kind == pin.kind && $0.start == pin.start && $0.end >= pin.end } }
        }

        var original: Block?
        var target = existing
        var routineBlocks: [Date: [(UUID, UUID)]] = [:]
        var baselinePins: [Date: [Block]] = [:]
        var remaining = tasks
        for day in dates {
            guard !Task.isCancelled else { return [] }
            // The selected block can be a later piece of the same occurrence. A move holds back its entire remaining task.
            if target == nil { target = remaining.first { $0.id == taskID } }
            let blocks = schedule(remaining, on: day, with: baselineOptions)
            baselinePins[day] = protected(blocks, in: remaining)
            if existing == nil {
                let series = Dictionary(uniqueKeysWithValues: remaining.compactMap { member in
                    member.repeated != nil && member.repeated != .once ? (member.id, member.seriesID ?? member.id) : nil
                })
                routineBlocks[day] = blocks.compactMap { block in
                    guard case .task(let id) = block.kind, id != taskID, let group = series[id] else { return nil }
                    return (id, group)
                }
            }
            if original == nil, sourceDay.map({ calendar.isDate($0, inSameDayAs: day) }) ?? true {
                original = blocks.first { $0.kind == .task(taskID) }
            }
            WeekOutlook.advance(&remaining, after: blocks, on: day, calendar: calendar)
        }
        // A drag must still refer to the displayed block. An explicit inbox request
        // can place a task even when all seven unpinned days were already allocated.
        if sourceDay != nil && original == nil { return [] }
        guard let task = target else { return [] }
        let occurrence = existing == nil ? task.occurrence(in: calendar) : nil
        if existing == nil && occurrence == nil { return [] }
        let nextCadence: Date?
        if occurrence != nil {
            nextCadence = task.nextCadenceDay(calendar: calendar)
        } else if task.repeated == .daily, task.repeatDays != nil {
            let anchor = task.routineAnchor ?? task.plannedStart ?? task.after ?? original?.start ?? now
            let source = original?.start ?? task.firstRepeatDay(onOrAfter: max(anchor, now), calendar: calendar) ?? max(anchor, now)
            nextCadence = task.cadenceDay(from: max(source, now), anchor: anchor, calendar: calendar)
        } else {
            nextCadence = nil
        }
        let siblings = routineBlocks.mapValues { entries in
            entries.compactMap { $0.1 == occurrence?.seriesID ? Block.Kind.task($0.0) : nil }
        }
        remaining = tasks
        // Moving a recurring task can establish the cadence date used when its prerequisite rolls forward.
        let anchorSensitiveIndex: Int? = {
            guard let existing, let rule = existing.repeated, rule != .once, existing.routineAnchor == nil,
                  let dependency = existing.dependency, let prerequisite = tasks.first(where: { $0.id == dependency }),
                  prerequisite.seriesID != nil || (prerequisite.repeated ?? .once) != .once else { return nil }
            return tasks.firstIndex { $0.id == taskID }
        }()
        let skipProfile = SkipTimingProfile(records: skipRecords, calendar: calendar)
        var preparedAnchor: Date?
        var options: [TaskPlacement] = []
        for (offset, date) in dates.enumerated() {
            guard !Task.isCancelled, let day = calendar.dateInterval(of: .day, for: date),
                  let preferred = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date) else { break }
            if let nextCadence, date >= nextCadence { break }
            if let i = anchorSensitiveIndex {
                var held = task
                held.moveOccurrence(to: .distantFuture, originalDay: original?.start ?? date, calendar: calendar)
                if held.routineAnchor != preparedAnchor {
                    // An undated backlog routine takes its cadence from the chosen day. Replay that prefix
                    // once per distinct cadence, so each candidate sees the same prerequisite as a saved pin.
                    remaining = tasks
                    remaining[i] = held
                    for earlierDay in dates.prefix(offset) {
                        guard !Task.isCancelled else { return [] }
                        let blocks = schedule(remaining, on: earlierDay)
                        WeekOutlook.advance(&remaining, after: blocks, on: earlierDay, calendar: calendar)
                    }
                    preparedAnchor = held.routineAnchor
                }
            }
            guard let index = remaining.firstIndex(where: { $0.id == taskID && !$0.done }) else {
                // A future occurrence cannot move ahead of the work that creates it.
                let earlier = schedule(remaining, on: date)
                WeekOutlook.advance(&remaining, after: earlier, on: date, calendar: calendar)
                continue
            }
            remaining[index].plannedStart = .distantFuture
            let without = schedule(remaining, on: date)
            let earlyPin = task.plannedStart.flatMap { calendar.isDate($0, inSameDayAs: date) ? $0 : nil }
            let requestedPin = exactStart.flatMap { calendar.isDate($0, inSameDayAs: date) ? $0 : nil }
            let normalStart = date == today ? now : min(preferred, earlyPin ?? preferred, requestedPin ?? preferred)
            let focusStart = task.fitsDedicatedFocus && date != today ? preferences.focusIntervals(on: day, calendar: calendar).first?.start : nil
            let first = focusTarget.map { max(date == today ? now : date, $0.start) } ?? min(normalStart, focusStart ?? normalStart)
            let boundary = max(first, occurrence == nil ? task.after ?? first : first, date == today && breaks ? recoveryInterval(recovery, at: now, commitments: commitments, calendar: calendar)?.end ?? first : first)
            let reserved = baselinePins[date] ?? []
            let occupied = workExclusions(at: date, commitments: commitments, reports: reports, preferences: preferences, calendar: calendar)
            // Later pinned dependent tasks must remain feasible even when the moved task spans several days.
            let peers = siblings[date] ?? []
            let lastCheck = dates.lastIndex { $0 > date && (!(baselinePins[$0] ?? []).isEmpty || !(siblings[$0] ?? []).isEmpty) }
            func trial(_ at: Date) -> [PlanTask] {
                var proposed = remaining
                proposed[index] = task
                proposed[index].dependency = remaining[index].dependency
                if occurrence != nil, let nominal = task.routineAnchor {
                    proposed[index].applyException(at, nominalDay: nominal, calendar: calendar)
                } else {
                    proposed[index].moveOccurrence(to: at, originalDay: original?.start ?? at, calendar: calendar)
                }
                proposed[index].assignedFocusBlockID = assignedID
                return proposed
            }
            if boundary < day.end, (exactStart == nil || requestedPin != nil), focusTarget.map({ day.start <= $0.start && $0.start < day.end }) != false {
                let found = dayPlacements(task: task, original: original, day: day, first: boundary,
                                          hourStart: calendar.dateInterval(of: .hour, for: boundary)?.start ?? boundary,
                                          baseline: without, occupied: occupied, reserved: [], reports: reports,
                                          preferences: preferences, calendar: calendar, forecast: forecast, allowDailyForecast: date > today, projectedOccurrence: occurrence, normalStart: normalStart, focusTarget: focusTarget, exactStart: requestedPin, skipProfile: skipProfile) { at in
                    schedule(trial(at), on: date)
                } validate: { plan, moved in
                    var finish = moved.minutes >= task.minutes ? moved.end : nil
                    let lastPin = lastCheck ?? offset
                    guard peers.allSatisfy({ kind in plan.contains { $0.kind == kind } }) else { return .conflict }
                    if reserved.isEmpty, lastPin == offset, task.due == nil || finish != nil {
                        return .valid(finish: finish)
                    }
                    var projected = trial(moved.start)
                    if !reserved.isEmpty, !retained(reserved, by: protected(plan, in: projected)) { return .conflict }
                    var previous = plan
                    for next in (offset + 1)..<dates.count {
                        if Task.isCancelled { return .conflict }
                        if next > lastPin && (task.due == nil || finish != nil) { break }
                        WeekOutlook.advance(&projected, after: previous, on: dates[next - 1], calendar: calendar)
                        let later = schedule(projected, on: dates[next])
                        if let peers = siblings[dates[next]], !peers.allSatisfy({ kind in later.contains { $0.kind == kind } }) { return .conflict }
                        if let pins = baselinePins[dates[next]], !pins.isEmpty,
                           !retained(pins, by: protected(later, in: projected)) { return .conflict }
                        if finish == nil, let block = later.first(where: { $0.kind == .task(taskID) }),
                           block.minutes >= projected[index].minutes { finish = block.end }
                        previous = later
                    }
                    return .valid(finish: finish)
                }
                options += found
            }
            guard retained(reserved, by: protected(without, in: remaining)),
                  peers.allSatisfy({ kind in without.contains { $0.kind == kind } }) else { break }
            WeekOutlook.advance(&remaining, after: without, on: date, calendar: calendar)
        }
        guard !Task.isCancelled else { return [] }
        for i in options.indices { options[i].recommended = false }
        if let best = options.indices.min(by: { options[$0].isPreferred(to: options[$1], for: task) }) {
            options[best].recommended = true
        }
        return options
    }
}
