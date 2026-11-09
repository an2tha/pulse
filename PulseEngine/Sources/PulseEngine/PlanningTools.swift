import Foundation

public struct TaskStep: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var done = false
    public init(_ title: String) { self.title = title }
}

public struct PlanTuning: Codable, Equatable, Sendable {
    public var date: Date
    public var minimumDay = false
    public var manualCapacity: Double?
    public init(date: Date) { self.date = date }
}

public struct SuggestionVote: Identifiable, Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case fits, tooMuch, later }
    public var id = UUID()
    public var date: Date
    public var category: Category
    public var verdict: Verdict
    public init(_ verdict: Verdict, category: Category, date: Date = .now) {
        self.verdict = verdict
        self.category = category
        self.date = date
    }
}

public struct PlannerPreferences: Sendable {
    public var tuning: PlanTuning?
    public var order: [UUID]
    public var timeBlocks: [WeeklyTimeBlock] = [] { didSet { windowsByDay = nil; boostPins = nil } }
    var boostPins: [DateInterval]?
    public var timeBlockBoosts: [UUID: EnergyActivity] = [:]
    public var wrapUpMinute: Int?
    public var bufferMinutes: Int
    public var votes: [SuggestionVote] { didSet { categoryWeights = nil } }
    public var energyTimeline: EnergyTimeline?
    public var energyAsOf: Date?
    public var energyOnlyToday = false
    public var corrections: [EnergyCorrection] = []
    public var expectations: [EnergyExpectation] = []
    private var windowsByDay: [Date: DayTaskWindows]?

    func preparingAvailability(_ tasks: [PlanTask], on days: [Date], calendar: Calendar) -> Self {
        var copy = self
        let rules = Set(tasks.compactMap(\.availability))
        var cached: [Date: DayTaskWindows] = [:]
        if !rules.isEmpty || !timeBlocks.isEmpty || tasks.contains(where: { $0.repeatDays != nil }) {
            for date in days {
                if let day = calendar.dateInterval(of: .day, for: date) {
                    cached[day.start] = DayTaskWindows(rules: rules, on: day, calendar: calendar, bufferMinutes: bufferMinutes, focusRules: timeBlocks)
                }
            }
        }
        copy.windowsByDay = cached
        return copy
    }

    func taskWindows(_ tasks: [PlanTask], on date: Date, calendar: Calendar) -> DayTaskWindows {
        if let windowsByDay {
            if windowsByDay.isEmpty { return DayTaskWindows(bufferMinutes: bufferMinutes) }
            if let cached = windowsByDay[calendar.startOfDay(for: date)] { return cached }
        }
        let rules = Set(tasks.compactMap(\.availability))
        guard !rules.isEmpty || !timeBlocks.isEmpty || tasks.contains(where: { $0.repeatDays != nil }),
              let day = calendar.dateInterval(of: .day, for: date) else { return DayTaskWindows(bufferMinutes: bufferMinutes) }
        return DayTaskWindows(rules: rules, on: day, calendar: calendar, bufferMinutes: bufferMinutes, focusRules: timeBlocks)
    }

    private var hourlyBaseline: Capacity.HourlyBaseline?
    private var categoryWeights: (latest: Date, values: [Category: Double])?

    func preparingVotes() -> Self {
        guard categoryWeights == nil, let latest = votes.map(\.date).max() else { return self }
        var copy = self
        copy.categoryWeights = (latest, Dictionary(uniqueKeysWithValues: Category.allCases.map {
            ($0, preference(for: $0, at: latest))
        }))
        return copy
    }

    func preparingHistory(_ reports: [CheckIn], calendar: Calendar) -> Self {
        var copy = preparingVotes()
        copy.hourlyBaseline = Capacity.HourlyBaseline(reports, calendar: calendar)
        return copy
    }

    private func hasReport(since start: Date, through time: Date, reports: [CheckIn]) -> Bool {
        if let hourlyBaseline {
            guard let latest = hourlyBaseline.latest else { return false }
            // A future slot only needs the last observation in the prepared history.
            if latest.date <= time { return latest.date >= start }
        }
        return reports.contains { $0.date >= start && $0.date <= time }
    }

    public func capacity(at time: Date, reports: [CheckIn], calendar: Calendar) -> Double {
        if let tuning, calendar.isDate(tuning.date, inSameDayAs: time), let manual = tuning.manualCapacity {
            return Capacity.scale(manual)
        }
        if let hour = calendar.dateInterval(of: .hour, for: time),
           let correction = corrections.last(where: { $0.date >= hour.start && $0.date <= time }) {
            return Capacity.scale(correction.score)
        }
        let reference = energyAsOf.flatMap { calendar.isDate($0, equalTo: time, toGranularity: .hour) ? min(time, $0) : nil } ?? time
        let base = hourlyBaseline?.estimate(at: time, calendar: calendar)
            ?? Capacity.estimate(at: time, reports: reports, calendar: calendar)
        if let expected = EnergyExpectation.applicable(at: time, in: expectations, calendar: calendar) {
            // What someone actually reported in this hour takes precedence.
            let hour = calendar.dateInterval(of: .hour, for: time)
            let reported = hour.map { hasReport(since: $0.start, through: time, reports: reports) } ?? false
            return reported ? base : expected.score
        }
        guard let timeline = energyTimeline, !energyOnlyToday || energyAsOf.map({ calendar.isDate($0, inSameDayAs: time) }) == true else { return base }
        let laterDay = energyAsOf.map { calendar.startOfDay(for: time) > calendar.startOfDay(for: $0) } ?? false
        guard let point = timeline.estimate(at: reference) ?? (laterDay ? timeline.daily(on: time) : nil)
        else { return base }
        let reportedToday = hasReport(since: calendar.startOfDay(for: time), through: time, reports: reports)
        return reportedToday ? min(base, point.score) : point.score
    }
    public init(
        tuning: PlanTuning? = nil, order: [UUID] = [], votes: [SuggestionVote] = [],
        bufferMinutes: Int = 0, wrapUpMinute: Int? = nil
    ) {
        self.wrapUpMinute = wrapUpMinute
        self.tuning = tuning
        self.order = order
        self.votes = votes
        self.bufferMinutes = max(0, min(30, bufferMinutes))
    }
    /// A midnight wrap-up is the end of this local day. Across DST gaps, stop at the
    /// first available local time; on a repeated hour, stop at its first occurrence.
    public func workEnd(on date: Date, calendar: Calendar = .current) -> Date {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return date }
        guard let minute = wrapUpMinute, (1..<1440).contains(minute) else { return day.end }
        let end = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.start,
                                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        return min(end ?? day.end, day.end)
    }

    public func preference(for category: Category, at date: Date) -> Double {
        if let categoryWeights, date >= categoryWeights.latest { return categoryWeights.values[category] ?? 0 }
        let recent = votes.filter { $0.category == category && $0.date <= date }.suffix(20)
        return recent.reduce(0.0) { prior, vote in
            prior * 0.85 + (vote.verdict == .fits ? 0.14 : -0.09)
        }
    }
}

public enum TaskRoutines {
    /// Only the next occurrence is materialized. Missed days never build up a backlog.
    public static func advance(_ tasks: inout [PlanTask], at now: Date, calendar: Calendar = .current) {
        advance(&tasks, at: now, calendar: calendar, releasing: nil)
    }

    static func advance(_ tasks: inout [PlanTask], at now: Date, calendar: Calendar, releasing releasedID: UUID?) {
        let closed = tasks.indices.filter {
            (tasks[$0].done || tasks[$0].id == releasedID) && tasks[$0].repeated != nil && tasks[$0].repeated != .once
                && tasks[$0].seriesAdvanced != true
        }
        var generated = false
        for index in closed {
            let previous = tasks[index]
            tasks[index].seriesAdvanced = true
            let series = previous.seriesID ?? previous.id
            tasks[index].seriesID = series
            guard previous.archived != true, previous.preparation == nil,
                !tasks.contains(where: { $0.id != previous.id && $0.seriesID == series && !$0.done && $0.archived != true })
            else { continue }
            let anchor =
                previous.templatePin ?? previous.routineAnchor ?? previous.after ?? previous.completedAt
                ?? now
            let anchorDay = calendar.startOfDay(for: anchor)
            let today = calendar.startOfDay(for: max(now, previous.after ?? now))
            guard let rule = previous.repeated,
                  var day = previous.cadenceDay(from: max(anchorDay, today), anchor: anchorDay, calendar: calendar)
            else { continue }
            var exceptions = previous.routineExceptions ?? []
            if previous.repeatDays != nil {
                exceptions.removeAll { !previous.keepsRepeatException($0, calendar: calendar) }
            }
            // A Friday moved to Saturday is still upcoming if the predecessor finishes on Saturday morning.
            for move in exceptions where move.detached != true && move.occurrence.seriesID == series && move.occurrence.rule == rule
                && move.start >= max(now, previous.completedAt ?? now) {
                guard let nominal = move.occurrence.day(in: calendar), nominal > anchorDay, nominal < day else { continue }
                guard previous.matchesCadence(on: nominal, anchor: anchorDay, calendar: calendar) else { continue }
                var template = previous
                template.routineAnchor = nominal
                if template.nextCadenceDay(calendar: calendar).map({ move.start < $0 }) == true { day = nominal }
            }
            var occurrence = RoutineOccurrence(seriesID: series, rule: rule, day: day, calendar: calendar)
            let detached = Set(exceptions.filter { $0.detached == true }.map(\.occurrence))
            while detached.contains(occurrence) {
                guard let following = previous.cadenceDay(from: day, anchor: anchorDay, calendar: calendar),
                      following > day else { break }
                day = following
                occurrence = RoutineOccurrence(seriesID: series, rule: rule, day: day, calendar: calendar)
            }
            guard !detached.contains(occurrence), !tasks.contains(where: { $0.id == occurrence.id }),
                  let days = calendar.dateComponents([.day], from: anchorDay, to: day).day else { continue }
            var next = previous.duplicate(id: occurrence.id)
            next.seriesID = series
            next.dependency = previous.dependency
            next.minutes = estimatedMinutes(for: series, original: next.minutes, history: tasks)
            next.routineAnchor = calendar.date(byAdding: .day, value: days, to: anchor)
            if previous.repeatDays != nil {
                let release: Date?
                if let moved = previous.movedRoutineTimes?.availability, moved.moved == previous.after { release = moved.original }
                else { release = previous.after }
                next.after = max(day, release.flatMap { calendar.date(byAdding: .day, value: days, to: $0) } ?? day)
            } else {
                next.after = previous.after == nil ? day : next.routineAnchor
            }
            next.createdAt = now
            next.due = previous.due.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
            next.reminder = previous.templateReminder.flatMap {
                calendar.date(byAdding: .day, value: days, to: $0)
            }
            next.plannedStart = previous.templatePin.flatMap {
                calendar.date(byAdding: .day, value: days, to: $0)
            }
            if let move = exceptions.first(where: { $0.occurrence == occurrence }),
               move.start >= max(now, previous.completedAt ?? now),
               next.nextCadenceDay(calendar: calendar).map({ move.start < $0 }) == true {
                next.applyException(move.start, nominalDay: day, calendar: calendar)
            }
            let future = exceptions.filter { $0.occurrence.seriesID == series && $0.occurrence.rule == rule
                && $0.occurrence.nominalDay > occurrence.nominalDay && $0.start >= now }
            if previous.routineExceptions != nil {
                next.routineExceptions = future
                if next.repeatDays != nil { next.pruneRepeatExceptions(calendar: calendar) }
                tasks[index].routineExceptions = []
            }
            generated = true
            tasks.append(next)
        }

        guard generated else { return }
        let seriesByOccurrence = tasks.reduce(into: [UUID: UUID]()) { result, task in
            result[task.id] = task.seriesID
        }
        for index in tasks.indices where !tasks[index].done {
            guard let day = tasks[index].routineAnchor,
                let dayEnd = calendar.dateInterval(of: .day, for: day)?.end,
                let dependency = tasks[index].dependency, let series = seriesByOccurrence[dependency],
                let next = tasks.first(where: { $0.seriesID == series && !$0.done && $0.archived != true && $0.id != releasedID }),
                let requiredDay = next.routineAnchor, requiredDay < dayEnd
            else { continue }
            tasks[index].dependency = next.id
        }
    }

    private static func estimatedMinutes(for series: UUID, original: Int, history: [PlanTask]) -> Int {
        let samples = history.filter {
            $0.seriesID == series && $0.done && $0.originalMinutes == original
                && ($0.focusedSeconds ?? 0) >= 60 && $0.focusedSeconds?.isFinite == true
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(5).compactMap(\.focusedSeconds).sorted()
        guard samples.count >= 3 else { return original }
        let mid = samples.count / 2
        let medianMinutes = (samples[(samples.count - 1) / 2] + samples[mid]) / 120
        let estimate = (Double(original) + medianMinutes) / 2
        return max(
            1, min(1440, Int(min(Double(original) * 1.25, max(Double(original) * 0.75, estimate)).rounded())))
    }

}

public struct OutlookDay: Identifiable, Sendable {
    public var date: Date
    public var blocks: [Block]
    public var projectedTasks: [PlanTask] = []
    public var id: Date { date }
}

public enum WeekOutlook {
    /// Future blocks are conditional on the previous day's proposed work being finished.
    public static func project(
        at now: Date, today: [Block], tasks: [PlanTask], events: [Commitment],
        reports: [CheckIn], limit: Int, breaks: Bool, preferences: PlannerPreferences,
        startHour: Int = 9, calendar: Calendar = .current
    ) -> [OutlookDay] {
        var remaining = tasks.resolvingPreparations(with: events, bufferMinutes: preferences.bufferMinutes, calendar: calendar)
        var result: [OutlookDay] = []
        let realIDs = Set(tasks.map(\.id))
        for offset in 0..<7 {
            guard !Task.isCancelled else { return [] }
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { break }
            let blocks = offset == 0 ? today : futureBlocks(on: day, tasks: remaining, events: events, reports: reports,
                                                          limit: limit, breaks: breaks, preferences: preferences,
                                                          startHour: startHour, calendar: calendar)
            let projectedIDs = Set(blocks.compactMap { block -> UUID? in
                if case .task(let id) = block.kind, !realIDs.contains(id) { return id }
                return nil
            })
            let previews = projectedIDs.isEmpty ? [] : remaining.filter { projectedIDs.contains($0.id) }
            result.append(OutlookDay(date: day, blocks: blocks, projectedTasks: previews))
            advance(&remaining, after: blocks, on: day, calendar: calendar)
        }
        return result
    }

    static func futureBlocks(on day: Date, tasks: [PlanTask], events: [Commitment], reports: [CheckIn],
                             limit: Int, breaks: Bool, preferences: PlannerPreferences,
                             startHour: Int, calendar: Calendar) -> [Block] {
        guard let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day) else { return [] }
        // A day can have appointments and explicit task times before its normal work period.
        var prepared = tasks
        if !preferences.timeBlocks.isEmpty, let bounds = calendar.dateInterval(of: .day, for: day),
           let first = preferences.focusIntervals(on: bounds, calendar: calendar).first?.start, first < start {
            let busy = Planner.workExclusions(at: day, commitments: events, reports: reports, preferences: preferences, calendar: calendar)
            let finished = Set(tasks.filter(\.done).map(\.id))
            let budget = Capacity.workloadLimit(userLimit: limit, reports: reports, at: first, calendar: calendar)
            Planner.placeInFocusTime(&prepared, at: first, until: start, room: budget, occupied: busy,
                                     windows: preferences.taskWindows(tasks, on: day, calendar: calendar), finished: finished,
                                     nextTaskID: nil, preferences: preferences, reports: reports, calendar: calendar)
        }
        let earlyPins = prepared.compactMap { task -> Date? in
            guard !task.done, task.archived != true, let pin = task.plannedStart,
                  pin >= day, task.earliest < start else { return nil }
            return task.earliest
        }
        let planningTime = earlyPins.min() ?? start
        if planningTime < start {
            // Finishing yesterday's pinned task does not reserve this morning before work begins.
            for index in prepared.indices where !prepared[index].done && prepared[index].archived != true {
                let task = prepared[index]
                if task.earliest < start && (task.plannedStart ?? .distantPast) < day {
                    prepared[index].after = start
                }
            }
        }
        let earlyEvents = events.flatMap { event in
            event.intervals(on: day, calendar: calendar).filter { $0.end <= planningTime }.map {
                Block(kind: .fixed(event.id), title: event.title, start: $0.start, end: $0.end)
            }
        }
        let earlyRules = preferences.weeklyBlocks(on: day, commitments: events, reports: reports, calendar: calendar).filter { $0.end <= planningTime }
        return (earlyEvents + earlyRules).sorted { $0.start < $1.start } + Planner.schedule(
            at: planningTime, tasks: prepared, commitments: events, reports: reports,
            dailyLimit: limit, breaks: breaks, preferences: preferences, calendar: calendar)
    }

    static func advance(_ remaining: inout [PlanTask], after blocks: [Block], on day: Date, calendar: Calendar) {
        for block in blocks {
            guard case .task(let id) = block.kind, let i = remaining.firstIndex(where: { $0.id == id }) else { continue }
            remaining[i].recordFocus(seconds: block.end.timeIntervalSince(block.start),
                                     completed: block.minutes >= remaining[i].minutes)
            // Forecast completions can release dependencies but cannot train a routine's duration.
            remaining[i].focusedSeconds = nil
            if remaining[i].done { remaining[i].completedAt = block.end }
        }
        TaskRoutines.advance(&remaining, at: day, calendar: calendar)
    }
}

public enum ScheduleConflicts {
    public static func overlapping(
        _ proposed: Commitment, in events: [Commitment], calendar: Calendar = .current
    )
        -> [Commitment]
    {
        guard proposed.end > proposed.start else { return [] }
        return events.filter { other in
            guard other.id != proposed.id, other.end > other.start else { return false }
            if proposed.recurrence == .once && other.recurrence == .once {
                return proposed.start < other.end && other.start < proposed.end
            }
            if proposed.recurrence == .once && proposed.end <= other.start { return false }
            if other.recurrence == .once && other.end <= proposed.start { return false }
            let anchor = max(
                calendar.startOfDay(for: proposed.start), calendar.startOfDay(for: other.start))
            for offset in 0..<8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: anchor) else { continue }
                let theirs = other.intervals(on: day, calendar: calendar)
                if proposed.intervals(on: day, calendar: calendar).contains(where: { a in
                    theirs.contains { a.start < $0.end && $0.start < a.end }
                }) {
                    return true
                }
            }
            return false
        }
    }
    public static func nextFree(
        _ event: Commitment, in events: [Commitment], calendar: Calendar = .current
    )
        -> Commitment?
    {
        let duration = event.end.timeIntervalSince(event.start)
        guard duration > 0 else { return nil }
        var candidate = event
        // Snap to the next five-minute boundary and check the next 24 hours.
        let first = (floor(event.start.timeIntervalSinceReferenceDate / 300) + 1) * 300
        for slot in 0..<288 {
            candidate.start = Date(timeIntervalSinceReferenceDate: first + Double(slot * 300))
            candidate.end = candidate.start.addingTimeInterval(duration)
            if overlapping(candidate, in: events, calendar: calendar).isEmpty { return candidate }
        }
        return nil
    }
}

public enum TaskBreakdown {
    private static let actions: Set<String> = [
        "add", "arrange", "book", "bring", "buy", "call", "check", "choose", "clean", "collect",
        "compare", "cook", "deliver", "draft", "draw", "edit", "email", "file", "find", "finish",
        "gather", "make", "open", "order", "organize", "outline", "pack", "pay", "pick", "plan",
        "prepare", "print", "proofread", "read", "reply", "research", "review", "revise", "run",
        "schedule", "send", "sketch", "sort", "study", "submit", "text", "tidy", "walk", "wash", "write"
    ]

    private static func verb(_ text: String) -> String {
        String(text.prefix(while: \.isLetter)).lowercased()
    }

    public static func suggestions(for task: PlanTask) -> [String] {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep noun pairs together, including in a compound instruction such as
        // “Pack a notebook and pencil and call the studio”.
        var clauses: [String] = []
        for part in title.components(separatedBy: " and ") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let next = text.lowercased().hasPrefix("then ") ? String(text.dropFirst(5)) : text
            if clauses.isEmpty || actions.contains(verb(next)) {
                clauses.append(next)
            } else {
                clauses[clauses.count - 1] += " and " + text
            }
        }
        if clauses.count > 1 { return clauses }

        switch verb(title) {
        case "write", "draft":
            let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            if !words.isDisjoint(with: ["code", "function", "test", "tests", "query", "script"]) {
                return ["Write down one example input", "Try the smallest version", "Check the result against your example"]
            }
            return ["Write the first sentence", "Add one supporting detail", "Read the draft once"]
        case "outline", "plan":
            return ["Write one bullet point", "Add the next point", "Choose which point to start with"]
        case "proofread":
            return ["Read one passage", "Make one change", "Read the changed passage"]
        case "edit", "revise":
            return ["Open the item you want to change", "Make one edit", "Check the result"]
        case "email", "reply", "text":
            return ["Open the conversation or a new message", "Write the main point", "Read it once before sending"]
        case "call":
            return ["Find the number or open the contact", "Note what you want to ask", "Make the call"]
        case "read", "study":
            return ["Read the first paragraph", "Note one idea or question", "Choose where to pick up next"]
        case "sort", "tidy", "organize", "clean":
            return ["Pick one small area", "Take care of one item", "Choose the next item"]
        case "draw", "sketch":
            return ["Make the first mark", "Sketch the main shape", "Add one detail"]
        default:
            switch task.category {
            case .study: return ["Open your study material", "Read one section", "Write down one question"]
            case .focus: return ["Open what you need to start", "Try the first part", "Review what you have so far"]
            case .recovery: return ["Find a comfortable place", "Take a brief pause", "Decide whether to continue"]
            case .personal: return ["Gather what you need", "Do the first part", "Choose what can wait"]
            }
        }
    }
}
