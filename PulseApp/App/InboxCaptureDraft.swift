import Foundation
import PulseEngine

struct InboxCaptureDraft: Sendable {
    let task: PlanTask
    let literal: PlanTask
    let interpreted: Bool
    let unresolved: Bool

    let calendar: Calendar

    init?(_ input: String, at date: Date, calendar: Calendar = .current, commitments: [Commitment], distraction: Bool = false) {
        self.calendar = calendar
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        literal = PlanTask(text, minutes: Category.personal.estimate, category: .personal)
        let draft = LocalDayInput.parse(text, at: date, calendar: calendar, commitments: commitments, singleTimesAreTaskPins: distraction)
        if draft.tasks.count == 1, let parsed = draft.tasks.first, draft.commitments.isEmpty,
           draft.unrecognized.isEmpty,
           parsed.plannedStart != nil || parsed.after != nil || parsed.due != nil || parsed.repeated != nil || parsed.availability != nil
            || parsed.title.localizedCaseInsensitiveCompare(text) != .orderedSame {
            task = parsed
            interpreted = true
            unresolved = false
        } else {
            task = literal
            interpreted = false
            unresolved = !draft.commitments.isEmpty || !draft.unrecognized.isEmpty
        }
    }

    var details: String {
        ([task.captureTiming(in: calendar), task.captureRecurrence(in: calendar)].compactMap { $0 } + ["\(task.minutes) min"]).joined(separator: " · ")
    }
}

extension PlanTask {
    func captureRecurrence(in calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard repeated == .daily, let repeatDays else { return repeated?.rawValue }
        var localized = calendar
        localized.locale = locale
        let days = calendar.pulseWeekdays.filter(repeatDays.contains).map { localized.shortWeekdaySymbols[$0 - 1] }
        return "Every " + days.joined(separator: ", ")
    }

    var captureTiming: String? { captureTiming(in: .current) }

    func captureTiming(in calendar: Calendar) -> String? {
        func formatted(_ date: Date, midnight: Bool = false) -> String {
            var style = Date.FormatStyle(date: .abbreviated, time: midnight ? .omitted : .shortened)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            let label = style.format(date)
            guard calendar.timeZone != TimeZone.current else { return label }
            return label + " " + (calendar.timeZone.abbreviation(for: date) ?? calendar.timeZone.identifier)
        }
        let times = [
            plannedStart.map { "Scheduled " + formatted($0) },
            // A clock pin already names its date; keep independent earliest-start constraints visible.
            after.flatMap { date -> String? in
                if let plannedStart, date == calendar.startOfDay(for: plannedStart) { return nil }
                let midnight = calendar.startOfDay(for: date) == date
                return "Earliest " + formatted(date, midnight: midnight)
            },
            availability.map { "Available " + $0.formattedHours(in: calendar) },
            due.map { "Due " + formatted($0) },
        ].compactMap { $0 }
        return times.isEmpty ? nil : times.joined(separator: " · ")
    }
}
