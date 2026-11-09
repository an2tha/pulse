import Foundation

/// Converts a gesture on an elapsed-time ruler into a lossless local-clock rule.
public struct TimelineBlockProposal: Sendable {
    public var rule: WeeklyTimeBlock
    public let occurrence: DateInterval

    public enum Issue: Error, LocalizedError {
        case empty, changed, unrepresentable
        public var errorDescription: String? {
            switch self {
            case .empty: "Choose a range of at least one minute."
            case .changed: "This block changed. Open it again to resize it."
            case .unrepresentable: "These endpoints cannot be saved as a single local-clock range. Choose different times."
            }
        }
    }

    public init(kind: WeeklyTimeBlock.Kind, interval: DateInterval, original: WeeklyTimeBlock? = nil,
                displayedSlice: DateInterval? = nil, calendar: Calendar = .current) throws {
        guard interval.duration >= 60 else { throw Issue.empty }
        var full = interval
        if let original {
            guard let slice = displayedSlice, let day = calendar.dateInterval(of: .day, for: slice.start),
                  original.intervals(on: day, calendar: calendar).contains(slice),
                  let yesterday = calendar.date(byAdding: .day, value: -1, to: day.start) else { throw Issue.changed }
            let candidates = [yesterday, day.start].compactMap { openingDay -> DateInterval? in
                guard original.appliesOn(openingDay, calendar: calendar) else { return nil }
                let span = Self.span(original.hours, on: openingDay, calendar: calendar)
                return span?.intersection(with: day) == slice ? span : nil
            }
            guard candidates.count == 1, let old = candidates.first else { throw Issue.unrepresentable }
            let startChanged = slice.start != interval.start
            let endChanged = slice.end != interval.end
            guard (!startChanged || slice.start == old.start), (!endChanged || slice.end == old.end) else { throw Issue.unrepresentable }
            let start = startChanged ? interval.start : old.start
            let end = endChanged ? interval.end : old.end
            guard start < end, calendar.isDate(start, inSameDayAs: old.start) else { throw Issue.unrepresentable }
            full = DateInterval(start: start, end: end)
        }
        func minute(_ date: Date) -> Int { calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
        let openingDay = calendar.startOfDay(for: full.start)
        let weekdays = original?.hours.weekdays ?? [calendar.component(.weekday, from: full.start)]
        guard let hours = TaskAvailability(weekdays: weekdays, startMinute: minute(full.start), endMinute: minute(full.end)),
              Self.span(hours, on: openingDay, calendar: calendar) == full else { throw Issue.unrepresentable }
        var proposed = original ?? WeeklyTimeBlock(kind: kind, hours: hours)
        proposed.hours = hours
        if original == nil { proposed.setSingleDate(openingDay, calendar: calendar) }
        rule = proposed
        occurrence = full
    }

    /// Resolve just one opening day. A folded clock can produce two disjoint
    /// pieces, which cannot faithfully describe one dragged interval.
    private static func span(_ hours: TaskAvailability, on date: Date, calendar: Calendar) -> DateInterval? {
        guard let day = calendar.dateInterval(of: .day, for: date),
              let next = calendar.dateInterval(of: .day, for: day.end),
              let single = TaskAvailability(weekdays: [calendar.component(.weekday, from: date)],
                                            startMinute: hours.startMinute, endMinute: hours.endMinute) else { return nil }
        let parts = single.intervals(on: day, calendar: calendar) + single.intervals(on: next, calendar: calendar)
        guard let first = parts.first, let last = parts.last,
              zip(parts, parts.dropFirst()).allSatisfy({ $0.end == $1.start }) else { return nil }
        return DateInterval(start: first.start, end: last.end)
    }
}
