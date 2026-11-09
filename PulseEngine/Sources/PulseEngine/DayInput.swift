import Foundation

public struct DayDraft: Sendable {
    public var tasks: [PlanTask] = []
    public var commitments: [Commitment] = []
    public var unrecognized: [String] = []
    fileprivate var prompts: [String: String] = [:]

    public func clarification(for input: String) -> String {
        let instruction = prompts[input] ?? "Check the date and time."
        return "“" + input.trimmingCharacters(in: .whitespacesAndNewlines) + "” · " + instruction
    }

    public init(tasks: [PlanTask] = [], commitments: [Commitment] = [], unrecognized: [String] = []) {
        self.tasks = tasks
        self.commitments = commitments
        self.unrecognized = unrecognized
    }
}

/// A cloud provider could implement this contract after explicit user opt-in.
public protocol DayInputProvider: Sendable {
    func draft(_ text: String, at date: Date, calendar: Calendar) async throws -> DayDraft
}

public struct LocalDayInput: DayInputProvider {
    private let commitments: [Commitment]

    public init(commitments: [Commitment] = []) { self.commitments = commitments }
    public func draft(_ text: String, at date: Date, calendar: Calendar) async throws -> DayDraft {
        Self.parse(text, at: date, calendar: calendar, commitments: commitments)
    }
    public static func parse(_ text: String, at date: Date, calendar: Calendar = .current,
                             commitments: [Commitment] = [], singleTimesAreTaskPins: Bool = false) -> DayDraft {
        var draft = DayDraft()
        let quotes = QuotedPhrases(text)
        for raw in inputLines(quotes.masked) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            guard !line.isEmpty else { continue }
            line = line.replacingOccurrences(
                of: #"(?i)^(?:and\s+)?(?:I\s+)?(?:need to\s+|want to\s+|have\s+(?:to\s+)?)?"#, with: "",
                options: .regularExpression)
            do {
                try add(line, to: &draft, at: date, calendar: calendar, commitments: commitments, singleTimesAreTaskPins: singleTimesAreTaskPins)
            } catch {
                let original = quotes.restore(raw)
                draft.unrecognized.append(original)
                draft.prompts[original] = (error as? InputError)?.prompt
            }
        }
        if !quotes.literals.isEmpty {
            for i in draft.tasks.indices { draft.tasks[i].title = quotes.restore(draft.tasks[i].title) }
            for i in draft.commitments.indices { draft.commitments[i].title = quotes.restore(draft.commitments[i].title) }
        }
        return draft
    }

    private enum InputError: Error {
        case invalidTime, date, duration, recurrence, title, lunch, relative, repeatedClock, availability

        var prompt: String {
            switch self {
            case .availability: "Use hours like ‘only on weekdays from 9am to 5pm’."
            case .repeatedClock: "That clock time occurs twice. Choose a different time or an elapsed delay."
            case .invalidTime: "Use a time like 9am or a range like 9am to 10am."
            case .date: "Use one date, such as Friday, tomorrow or 2026-11-09."
            case .duration: "Use one duration in minutes or hours."
            case .recurrence: "Choose a repeat such as daily, every Tuesday, or every Tue and Thu."
            case .title: "Include a task or event name."
            case .lunch: "Give a clock time or add one Lunch commitment for that day."
            case .relative: "Use one delay like ‘in 20 minutes’ or deadline like ‘within 2 hours’."
            }
        }
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let weekdayPattern = weekdays.joined(separator: "|")

    private static func add(_ input: String, to draft: inout DayDraft, at date: Date, calendar: Calendar,
                            commitments: [Commitment], singleTimesAreTaskPins: Bool) throws {
        var line = input
        let availability = try extractAvailability(from: &line, at: date, calendar: calendar)
        let relative = try extractRelative(from: &line, at: date)
        let recurrence = try extractRecurrence(from: &line, at: date, calendar: calendar)
        let duration = try extractDuration(from: &line)
        var due = relative.due
        if let suffix = line.range(
            of: #"(?i)\s+(?:due\s+)?by\s+(?=(?:today|tomorrow|next\s+|this\s+|noon|midnight|\#(weekdayPattern)|\d))"#,
            options: .regularExpression)
        {
            guard due == nil else { throw InputError.date }
            var deadline = String(line[suffix.upperBound...])
            let day = try extractDay(from: &deadline, at: date, calendar: calendar) ?? date
            if deadline.isEmpty {
                guard let range = calendar.dateInterval(of: .day, for: day) else { throw InputError.date }
                due = range.end.addingTimeInterval(-1)
            } else {
                if deadline.lowercased().hasPrefix("at ") { deadline.removeFirst(3) }
                due = try clock(deadline, on: day, calendar: calendar)
            }
            line.removeSubrange(suffix.lowerBound..<line.endIndex)
        }
        let explicitDay = try extractDay(from: &line, at: date, calendar: calendar)
        let hasRelative = relative.after != nil || relative.due != nil
        guard relative.after == nil || explicitDay == nil, !hasRelative || recurrence.rule == .once else {
            throw InputError.date
        }
        var day = explicitDay ?? date
        if let weekday = recurrence.weekday {
            guard explicitDay == nil || calendar.component(.weekday, from: day) == weekday else { throw InputError.date }
            day = try nextWeekday(weekday, from: day, includeToday: true, calendar: calendar)
        }
        if recurrence.rule == .weekdays, calendar.isDateInWeekend(day) {
            guard explicitDay == nil, let weekend = calendar.dateIntervalOfWeekend(containing: day) else {
                throw InputError.date
            }
            day = weekend.end
        }

        var earliest = relative.after
        if let lunch = line.range(of: #"(?i)\s+at\s+lunch$"#, options: .regularExpression) {
            guard earliest == nil, recurrence.rule == .once else { throw InputError.lunch }
            let matches = commitments.filter {
                ["lunch", "lunch break"].contains($0.title.trimmingCharacters(in: .whitespaces).lowercased())
            }.flatMap { $0.intervals(on: day, calendar: calendar) }
            guard matches.count == 1, let meal = matches.first, meal.end > date else { throw InputError.lunch }
            earliest = meal.start
            line.removeSubrange(lunch)
        }

        let atClock = #"(?i)\s+at\s+(?=\d|noon|midnight)"#
        var pin: Date?
        var cadenceClock: Int?
        var taskClock: Int?
        var endClock: Int?
        let fromClock = #"(?i)\s+from\s+(?=\d|noon|midnight)"#
        if singleTimesAreTaskPins, let from = line.range(of: fromClock, options: .regularExpression) {
            guard duration == nil else { throw InputError.duration }
            guard let to = line.range(of: #"(?i)\h+to\h+"#, options: .regularExpression, range: from.upperBound..<line.endIndex)
            else { throw InputError.invalidTime }
            taskClock = try clockMinute(String(line[from.upperBound..<to.lowerBound]), allowBareAfternoon: false)
            endClock = try clockMinute(String(line[to.upperBound...]), allowBareAfternoon: false)
            guard taskClock != endClock else { throw InputError.invalidTime }
            line.removeSubrange(from.lowerBound..<line.endIndex)
        } else if singleTimesAreTaskPins || recurrence.days != nil, let at = line.range(of: atClock, options: .regularExpression) {
            taskClock = try clockMinute(String(line[at.upperBound...]), allowBareAfternoon: false)
            line.removeSubrange(at.lowerBound..<line.endIndex)
        }
        if let time = taskClock {
            guard earliest == nil else { throw InputError.date }
            if explicitDay == nil, calendar.isDate(day, inSameDayAs: date),
               recurrence.days?.contains(calendar.component(.weekday, from: date)) != false {
                let current = calendar.dateComponents([.hour, .minute], from: date)
                if time < (current.hour ?? 0) * 60 + (current.minute ?? 0) {
                    // During the first pass through a folded hour, its second pass may still be ahead.
                    if let late = calendar.date(bySettingHour: time / 60, minute: time % 60, second: 0, of: day,
                                                matchingPolicy: .strict, repeatedTimePolicy: .last),
                       calendar.isDate(late, inSameDayAs: day), late >= date { throw InputError.repeatedClock }
                    guard let next = calendar.date(byAdding: .day, value: recurrence.rule == .weekly ? 7 : 1, to: day) else { throw InputError.date }
                    day = next
                    if recurrence.rule == .weekdays, let weekend = calendar.dateIntervalOfWeekend(containing: day) { day = weekend.end }
                }
            }
            if recurrence.days != nil {
                // Resolve the clock on the actual first occurrence, never on an excluded weekday.
                cadenceClock = time
            } else {
                pin = try clock(minuteOfDay: time, on: day, calendar: calendar)
            }
        }

        let start: Date
        let end: Date
        if let from = line.range(of: #"(?i)\s+from\s+(?=\d|noon|midnight)"#, options: .regularExpression),
            let to = line.range(of: " to ", options: .caseInsensitive, range: from.upperBound..<line.endIndex)
        {
            guard duration == nil else { throw InputError.duration }
            start = try clock(String(line[from.upperBound..<to.lowerBound]), on: day, calendar: calendar)
            let finish = try clock(String(line[to.upperBound...]), on: day, calendar: calendar)
            guard start != finish else { throw InputError.invalidTime }
            end = finish < start ? calendar.date(byAdding: .day, value: 1, to: finish)! : finish
            line.removeSubrange(from.lowerBound..<line.endIndex)
        } else if let until = line.range(of: " until ", options: .caseInsensitive) {
            guard duration == nil else { throw InputError.duration }
            end = try clock(String(line[until.upperBound...]), on: day, calendar: calendar)
            let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
            let assumedStart = calendar.isDate(day, inSameDayAs: date) ? min(date, morning) : morning
            start = min(end.addingTimeInterval(-60), assumedStart)
            line.removeSubrange(until.lowerBound..<line.endIndex)
        } else if let at = line.range(of: atClock, options: .regularExpression) {
            start = try clock(String(line[at.upperBound...]), on: day, calendar: calendar)
            end = start.addingTimeInterval(Double(duration ?? 30) * 60)
            line.removeSubrange(at.lowerBound..<line.endIndex)
        } else {
            guard !line.isEmpty else { throw InputError.title }
            if line.range(of: #"(?i)\s+(?:from|at)\s+(?:\d|noon|midnight|one\b|two\b|three\b|four\b|five\b|six\b|seven\b|eight\b|nine\b|ten\b|eleven\b|twelve\b|lunch\b)"#, options: .regularExpression) != nil {
                throw InputError.invalidTime
            }
            if line.range(of: #"(?i)\s\d{1,2}(?::\d{2}|\s*[ap]m)\b"#, options: .regularExpression) != nil {
                throw InputError.invalidTime
            }
            if let due, (earliest ?? calendar.startOfDay(for: day)) > due { throw InputError.date }
            let category: Category = line.lowercased().contains("study") ? .study : .focus
            var task = PlanTask(title(line), minutes: duration ?? category.estimate, category: category)
            task.due = due
            task.availability = availability
            if recurrence.rule != .once {
                task.repeated = recurrence.rule
                task.routineAnchor = calendar.startOfDay(for: day)
            }
            task.after = earliest ?? (calendar.isDate(day, inSameDayAs: date) ? nil : calendar.startOfDay(for: day))
            if let selected = recurrence.days {
                task.repeatDays = selected
                guard let first = task.firstRepeatDay(onOrAfter: day, calendar: calendar),
                      due.map({ first <= $0 }) != false else { throw InputError.date }
                if let cadenceClock {
                    pin = try clock(minuteOfDay: cadenceClock, on: first, calendar: calendar)
                }
                task.after = first
            }
            if let pin {
                guard pin.addingTimeInterval(60) > date, due.map({ pin <= $0 }) != false else { throw InputError.date }
                if let availability, availability.interval(containing: pin, calendar: calendar) == nil { throw InputError.availability }
                if let endClock, let taskClock {
                    var endDay = pin
                    if endClock < taskClock {
                        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: pin)) else { throw InputError.date }
                        endDay = next
                    }
                    let finish = try clock(minuteOfDay: endClock, on: endDay, calendar: calendar)
                    let minutes = Int(finish.timeIntervalSince(pin) / 60)
                    guard (1...1440).contains(minutes) else { throw InputError.duration }
                    guard due.map({ finish <= $0 }) != false else { throw InputError.date }
                    if let availability, let opening = availability.interval(containing: pin, calendar: calendar),
                       finish > opening.end { throw InputError.availability }
                    task.minutes = minutes
                    task.originalMinutes = minutes
                }
                task.plannedStart = pin
            }
            task.alignFirstRepeatDay(at: date, calendar: calendar)
            draft.tasks.append(task)
            return
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { throw InputError.title }
        guard availability == nil else { throw InputError.availability }
        guard recurrence.days == nil else { throw InputError.recurrence }
        guard due == nil, earliest == nil, pin == nil else { throw InputError.date }
        guard recurrence.rule == .once || end.timeIntervalSince(start) < 86400 else { throw InputError.duration }
        draft.commitments.append(Commitment(title(line), start: start, end: end, recurrence: recurrence.rule))
    }

    private static func title(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespaces)
        return clean.prefix(1).uppercased() + clean.dropFirst()
    }

    private static func extractRecurrence(from text: inout String, at date: Date, calendar: Calendar) throws
        -> (rule: Recurrence, weekday: Int?, days: Set<Int>?) {
        let matches = recurringListPhrase.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var selected: Set<Int>?
        if let match = matches.first {
            guard matches.count == 1, let phrase = Range(match.range, in: text),
                  let list = Range(match.range(at: 1), in: text),
                  let days = parsedWeekdays(String(text[list]), at: date, calendar: calendar),
                  days.count >= 2 else { throw InputError.recurrence }
            selected = days
            text.removeSubrange(phrase)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: weekendCadence, options: .regularExpression) {
            guard selected == nil, let days = parsedWeekdays("weekends", at: date, calendar: calendar), !days.isEmpty else {
                throw InputError.recurrence
            }
            selected = days
            text.removeSubrange(range)
            if text.range(of: weekendCadence, options: .regularExpression) != nil { throw InputError.recurrence }
        }
        if recurringDayList.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            || text.range(of: #"(?i)\bevery\h+\#(dayNamePattern)\h+(?:and|through|to)\b"#, options: .regularExpression) != nil {
            throw InputError.recurrence
        }
        let pattern = #"(?i)(?:^|\s)(?:every\s+(?:day|weekday|week|\#(weekdayPattern))|(?:weekly\s+)?on\s+(?:\#(weekdayPattern))s|(?:weekdays|weekly|daily)(?=$|\s+(?:on|at|from|until|for|by|today|tomorrow|\d)\b))\b"#
        var rule: Recurrence = selected == nil ? .once : .daily
        var weekday: Int?
        if let range = text.range(of: pattern, options: .regularExpression) {
            guard selected == nil else { throw InputError.recurrence }
            let token = text[range].lowercased()
            if token.contains("weekday") { rule = .weekdays }
            else if token.contains("daily") || token.contains("every day") { rule = .daily }
            else {
                rule = .weekly
                weekday = weekdays.firstIndex(where: { token.contains($0) }).map { $0 + 1 }
            }
            text.removeSubrange(range)
        }
        if text.range(of: #"(?i)\b(?:every\s+(?:other|\d+|weekend|month|year|morning|evening|day|week|\#(weekdayPattern))|monthly|annually|fortnightly|biweekly)\b"#, options: .regularExpression) != nil {
            throw InputError.recurrence
        }
        return (rule, weekday, selected)
    }

    private static let relativeExpression = try! NSRegularExpression(
        pattern: #"(?i)\s+(due\s+(?:in|within)|within|in|after)\s+([0-9]+|an?\b|one\b|two\b|three\b|half\s+an?\b)\s*(minutes?|mins?|m|hours?|hrs?|h)\b(?=$|\s+(?:for|by)\b)"#)

    private static func extractRelative(from text: inout String, at date: Date) throws -> (after: Date?, due: Date?) {
        // Elapsed hours cross clock changes exactly. Named days below use the user's calendar.
        var after: Date?
        var due: Date?
        let fullRange = NSRange(text.startIndex..., in: text)
        if let match = relativeExpression.firstMatch(in: text, range: fullRange),
           let whole = Range(match.range, in: text), let word = Range(match.range(at: 1), in: text),
           let number = Range(match.range(at: 2), in: text), let unit = Range(match.range(at: 3), in: text) {
            let name = text[..<whole.lowerBound].trimmingCharacters(in: .whitespaces)
            if name.range(of: #"(?i)(?:^|\s)(?:due|by|after|within|at|in)$"#, options: .regularExpression) != nil {
                throw InputError.relative
            }
            let multiplier = text[unit].lowercased().hasPrefix("h") ? 3600.0 : 60.0
            let amount = text[number].lowercased()
            let spoken = ["a": 1.0, "an": 1.0, "one": 1.0, "two": 2.0, "three": 3.0]
            let n = amount.hasPrefix("half") ? 0.5 : (spoken[amount] ?? Double(amount))
            guard let n, n > 0 else { throw InputError.relative }
            let time = date.addingTimeInterval(n * multiplier)
            guard time.timeIntervalSince1970.isFinite, abs(time.timeIntervalSince1970) < 32_000_000_000 else {
                throw InputError.relative
            }
            let kind = text[word].lowercased()
            if kind == "after" || kind == "in" { after = time } else { due = time }
            text.removeSubrange(whole)
        }
        if text.range(of: #"(?i)\b(?:in|within|after)\s+(?:[+.-]?\d|(?:an?|one|two|three|half)\s+(?:an?\s+)?(?:hour|minute))"#, options: .regularExpression) != nil {
            throw InputError.relative
        }
        return (after, due)
    }

    private static func extractDuration(from text: inout String) throws -> Int? {
        let pattern = #"(?i)\s+(?:for\s+)?\d+(?:\.\d+)?\s*(?:min(?:ute)?s?|hours?|hrs?)\b"#
        var minutes: Int?
        if let range = text.range(of: pattern, options: .regularExpression) {
            let token = String(text[range]).lowercased()
            let unit = token.contains("h") ? 60.0 : 1.0
            guard let amount = Double(token.filter { $0.isNumber || $0 == "." }) else { throw InputError.duration }
            let value = amount * unit
            guard (1...1440).contains(value), value.rounded() == value else { throw InputError.duration }
            minutes = Int(value)
            text.removeSubrange(range)
        }
        // An unsupported amount must never become part of a task with a default estimate.
        if text.range(of: pattern, options: .regularExpression) != nil
            || text.range(of: #"(?i)\s+for\s+(?:[\d+.-]|(?:one|two|three|half|an?|twenty|thirty)\s+(?:hours?|minutes?)\b)"#, options: .regularExpression) != nil {
            throw InputError.duration
        }
        return minutes
    }

    private static func nextWeekday(_ weekday: Int, from date: Date, includeToday: Bool, calendar: Calendar) throws -> Date {
        let distance = (weekday - calendar.component(.weekday, from: date) + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: distance == 0 && !includeToday ? 7 : distance, to: date) else {
            throw InputError.date
        }
        return day
    }

    private static func extractDay(from text: inout String, at date: Date, calendar: Calendar) throws -> Date? {
        let pattern = #"(?i)(?:^|\s)(?:on\s+)?(?:today|tomorrow|\d{4}-\d{2}-\d{2}|(?:(?:this|next)\s+)?(?:\#(weekdayPattern)))(?=$|\s+(?:at|from|until|for|by|every|daily|weekdays|\d))"#
        var result: Date?
        if let match = text.range(of: pattern, options: .regularExpression) {
            let token = text[match].lowercased().trimmingCharacters(in: .whitespaces)
            let last = token.split(separator: " ").last.map(String.init) ?? token
            if let weekday = weekdays.firstIndex(of: last) {
                result = try nextWeekday(weekday + 1, from: date, includeToday: !token.contains("next "), calendar: calendar)
            } else if last == "today" || last == "tomorrow" {
                result = calendar.date(byAdding: .day, value: last == "today" ? 0 : 1, to: date)
            } else {
                let parts = last.split(separator: "-").compactMap { Int($0) }
                var gregorian = Calendar(identifier: .gregorian)
                gregorian.timeZone = calendar.timeZone
                guard parts.count == 3,
                    let day = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                    gregorian.component(.year, from: day) == parts[0], gregorian.component(.month, from: day) == parts[1],
                    gregorian.component(.day, from: day) == parts[2] else { throw InputError.date }
                result = day
            }
            text.removeSubrange(match)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if text.range(of: pattern, options: .regularExpression) != nil
            || text.range(of: #"(?i)(?:^|\s)(?:(?:next|this)\s+(?:week|weekend|month|year)|\d{1,4}[/.-]\d{1,2}[/.-]\d{1,4}|(?:today|tomorrow|\#(weekdayPattern))\s+(?:morning|evening|afternoon)|(?:on\s+)?(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2})\b"#, options: .regularExpression) != nil {
            throw InputError.date
        }
        return result
    }

    private static let clauseSeparator = try! NSRegularExpression(
        pattern: #"(?i)(?<!\d),|,(?!\d)|;|\R|\s+and\s+(?=(?:I\s+)?(?:want|need|have|study|work|finish|read|do|go|call|write|meet)\b)"#)
    private static let dayNames: [String: Int] = {
        var names = ["tues": 3, "weds": 4, "thur": 5, "thurs": 5]
        for (index, day) in weekdays.enumerated() {
            for name in [day, day + "s", String(day.prefix(3))] { names[name] = index + 1 }
        }
        return names
    }()

    private static let dayNamePattern = "(?:" + dayNames.keys.sorted { $0.count > $1.count }.joined(separator: "|") + #")\.?"#
    private static let weekdayListPattern: String = {
        let joiner = #"(?:\h*,\h*(?:and\h+)?|\h+and\h+|\h*&\h*|\h+(?:through|to)\h+|\h*[–-]\h*)"#
        return #"\#(dayNamePattern)(?:\#(joiner)\#(dayNamePattern))+"#
    }()
    private static let dayListPhrase = try! NSRegularExpression(
        pattern: #"(?i)\bonly\h+(?:on\h+)?(\#(weekdayListPattern))\h+(?:from|between)\b"#)
    private static let recurringDayList = try! NSRegularExpression(
        pattern: #"(?i)\bevery\h+(\#(weekdayListPattern))(?=$|[^\p{L}\p{N}])"#)
    private static let recurringListPhrase = try! NSRegularExpression(
        pattern: #"(?i)\bevery\h+(\#(weekdayListPattern))(?=$|[.,;\r\n]|\h+(?:at|for|by|due|from|between|until|after|in|within|on|next|this|today|tomorrow|every|daily|weekly|only|\d+|and\h+(?:I\h+)?(?:want|need|have|study|work|finish|read|do|go|call|write|meet))\b)"#)

    /// Commas inside an explicit weekday list belong to that task.
    private static func inputLines(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var dayLists: [NSRange] = []
        if text.contains(",") {
            if text.localizedCaseInsensitiveContains("only") {
                dayLists = dayListPhrase.matches(in: text, range: range).map { $0.range(at: 1) }
            }
            if text.localizedCaseInsensitiveContains("every") {
                dayLists += recurringDayList.matches(in: text, range: range).map { $0.range(at: 1) }
                dayLists.sort { $0.location < $1.location }
            }
        }
        var listIndex = 0
        var lines: [String] = []
        var start = text.startIndex
        for separator in clauseSeparator.matches(in: text, range: range) {
            while listIndex < dayLists.count && NSMaxRange(dayLists[listIndex]) <= separator.range.location { listIndex += 1 }
            if listIndex < dayLists.count, NSLocationInRange(separator.range.location, dayLists[listIndex]) { continue }
            guard let hit = Range(separator.range, in: text) else { continue }
            lines.append(String(text[start..<hit.lowerBound]))
            start = hit.upperBound
        }
        lines.append(String(text[start...]))
        return lines
    }

    private static func parsedWeekdays(_ input: String, at date: Date, calendar: Calendar) -> Set<Int>? {
        let days = input.lowercased().trimmingCharacters(in: .whitespaces)
        switch days {
        case "daily", "every day", "all days": return Set(1...7)
        case "weekdays", "weekends":
            let wantsWeekend = days == "weekends"
            let localDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
            return Set(localDays.filter { calendar.isDateInWeekend($0) == wantsWeekend }
                .map { calendar.component(.weekday, from: $0) })
        default: break
        }
        let list = days.replacingOccurrences(of: #"\s*,\s*(?:and\s+)?|\s+and\s+|\s*&\s*"#, with: ",", options: .regularExpression)
        var selected = Set<Int>()
        for token in list.components(separatedBy: ",") {
            let range = token.replacingOccurrences(of: #"\s+(?:through|to)\s+|\s*[–-]\s*"#, with: "-", options: .regularExpression)
                .components(separatedBy: "-")
            let numbers = range.compactMap { dayNames[$0.trimmingCharacters(in: CharacterSet(charactersIn: "."))] }
            guard range.count <= 2, numbers.count == range.count, let first = numbers.first, let last = numbers.last else { return nil }
            for offset in 0...((last - first + 7) % 7) { selected.insert((first - 1 + offset) % 7 + 1) }
        }
        return selected.isEmpty ? nil : selected
    }

    private static let availabilityCue = #"(?i)\bonly\s+(?:on\s+|(?=(?:weekdays|weekends|daily|every day|all days)\b))"#
    private static func cue(in text: String) -> Range<String.Index>? {
        guard let match = text.range(of: availabilityCue, options: .regularExpression) else { return nil }
        let tail = text[match.upperBound...]
        let first = String(tail.prefix(while: { $0.isLetter })).lowercased()
        // Ordinary titles such as “Write only on paper” stay intact.
        guard dayNames[first] != nil || ["weekdays", "weekends", "daily", "every", "all"].contains(first)
                || tail.range(of: #"(?i)\s+(?:from|between)\s+(?:\d|noon|midnight)"#, options: .regularExpression) != nil else { return nil }
        return match
    }

    /// Keep an explicit scheduling rule intact when a caller also supports model-assisted rewording.
    public static func hasAvailabilityCue(in input: String) -> Bool { cue(in: QuotedPhrases(input).masked) != nil }

    private static let weekendCadence = #"(?i)\b(?:every\h+weekend|on\h+weekends)\b"#

    public static func hasSelectedWeekdayCadence(in input: String) -> Bool {
        let text = QuotedPhrases(input).masked
        return text.range(of: weekendCadence, options: .regularExpression) != nil
            || recurringDayList.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let clockToken = #"(?:noon|midnight|\d{1,2}(?::\d{2})?(?:\s*[ap]m)?)"#
    private static let availabilityHours = try! NSRegularExpression(
        pattern: #"(?i)^(from|between)\s+(\#(clockToken))\s+(to|and)\s+(\#(clockToken))(?=$|\s+(?:for|due|by|within|in|after|every|weekly|daily|today|tomorrow|on|next|this|\d+)\b)"#)

    private static func extractAvailability(from text: inout String, at date: Date, calendar: Calendar) throws -> TaskAvailability? {
        guard let marker = cue(in: text) else { return nil }
        let tail = String(text[marker.upperBound...])
        guard let range = tail.range(of: #"(?i)\s+(?:from|between)\s+"#, options: .regularExpression),
              let days = parsedWeekdays(String(tail[..<range.lowerBound]), at: date, calendar: calendar) else { throw InputError.availability }
        let times = String(tail[range.lowerBound...].drop(while: { $0.isWhitespace }))
        guard let match = availabilityHours.firstMatch(in: times, range: NSRange(times.startIndex..., in: times)),
              let span = Range(match.range, in: times) else { throw InputError.availability }
        let fields = (1...4).compactMap { index in Range(match.range(at: index), in: times).map { times[$0].lowercased() } }
        guard fields.count == 4, (fields[0] == "from" && fields[2] == "to") || (fields[0] == "between" && fields[2] == "and"),
              let start = try? clockMinute(fields[1], allowBareAfternoon: false),
              let end = try? clockMinute(fields[3], allowBareAfternoon: false),
              let rule = TaskAvailability(weekdays: days, startMinute: start, endMinute: end) else { throw InputError.availability }
        let remaining = text[..<marker.lowerBound].trimmingCharacters(in: .whitespaces) + times[span.upperBound...]
        guard cue(in: remaining) == nil else { throw InputError.availability }
        text = remaining.trimmingCharacters(in: .whitespaces)
        return rule
    }

    private static func clockMinute(_ text: String, allowBareAfternoon: Bool) throws -> Int {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "noon" { value = "12pm" } else if value == "midnight" { value = "12am" }
        let pm = value.hasSuffix("pm")
        let am = value.hasSuffix("am")
        if am || pm {
            value.removeLast(2)
            value = value.trimmingCharacters(in: .whitespaces)
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, (1...2).contains(first.count), first.allSatisfy(\.isNumber),
            var hour = Int(first), (0...23).contains(hour), parts.count <= 2,
            (!am && !pm) || (1...12).contains(hour)
        else { throw InputError.invalidTime }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute),
            parts.count == 1 || (parts[1].count == 2 && parts[1].allSatisfy(\.isNumber))
        else { throw InputError.invalidTime }
        if am || pm {
            hour = hour % 12 + (pm ? 12 : 0)
        } else if parts.count == 1 && !first.hasPrefix("0") && (1...12).contains(hour) {
            guard allowBareAfternoon else { throw InputError.invalidTime }
            if hour <= 7 { hour += 12 }
        }
        return hour * 60 + minute
    }

    private static func clock(_ text: String, on day: Date, calendar: Calendar) throws -> Date {
        try clock(minuteOfDay: clockMinute(text, allowBareAfternoon: true), on: day, calendar: calendar)
    }

    private static func clock(minuteOfDay value: Int, on day: Date, calendar: Calendar) throws -> Date {
        let hour = value / 60, minute = value % 60
        guard let result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
            calendar.isDate(result, inSameDayAs: day),
            calendar.component(.hour, from: result) == hour, calendar.component(.minute, from: result) == minute else {
            throw InputError.invalidTime
        }
        if let last = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                    matchingPolicy: .strict, repeatedTimePolicy: .last),
           last != result, calendar.isDate(last, inSameDayAs: day) {
            throw InputError.repeatedClock
        }
        return result
    }
}

/// Protect quoted names while splitting a paragraph and reading its timing modifiers.
private struct QuotedPhrases {
    let masked: String
    let literals: [(token: String, text: String)]

    private static let expression = try! NSRegularExpression(
        pattern: #"(?m)"[^"\n]*(?:"|$)|“[^”\n]*(?:”|$)|‘[^\n]*?’(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])'[^'\n]+'(?![\p{L}\p{N}])"#)

    init(_ text: String) {
        var masked = ""
        var literals: [(String, String)] = []
        var start = text.startIndex
        for match in Self.expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let span = Range(match.range, in: text) else { continue }
            let token = "<" + UUID().uuidString + ">"
            literals.append((token, String(text[span])))
            masked += text[start..<span.lowerBound] + token
            start = span.upperBound
        }
        masked += text[start...]
        self.masked = masked
        self.literals = literals
    }

    func restore(_ string: String) -> String {
        literals.reduce(string) { $0.replacingOccurrences(of: $1.token, with: $1.text) }
    }
}
