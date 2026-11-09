import Foundation

/// A prospective, one-day-ahead value. No history is manufactured on first launch.
public struct DayAheadForecast: Codable, Equatable, Identifiable, Sendable {
    public let day: Date
    public let end: Date
    public let madeAt: Date
    public let score: Double
    public let supportDays: Int
    public let timeZoneID: String
    public var id: Date { day }

    public init?(from timeline: EnergyTimeline, calendar: Calendar = .current) {
        let date = timeline.now
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)),
              let window = calendar.dateInterval(of: .day, for: tomorrow),
              let point = timeline.modeledDailyForecast(on: tomorrow) else { return nil }
        day = window.start
        end = window.end
        madeAt = date
        score = point.score
        supportDays = point.supportDays
        timeZoneID = calendar.timeZone.identifier
    }

    public var isValid: Bool {
        madeAt < day && day < end && day.timeIntervalSince(madeAt) <= 26 * 3600
            && end.timeIntervalSince(day) <= 26 * 3600 && (0...10).contains(score)
            && (3...366).contains(supportDays) && TimeZone(identifier: timeZoneID) != nil
            && [madeAt, day, end].allSatisfy { abs($0.timeIntervalSince1970) < 32_000_000_000 }
    }

    public func isForDay(_ target: Date, calendar: Calendar) -> Bool {
        var original = calendar
        original.timeZone = TimeZone(identifier: timeZoneID) ?? calendar.timeZone
        let parts: Set<Calendar.Component> = [.era, .year, .month, .day]
        return original.dateComponents(parts, from: day) == calendar.dateComponents(parts, from: target)
    }
}

public struct ForecastComparison: Identifiable, Sendable {
    public let forecast: DayAheadForecast
    public let observed: Double?
    public var id: Date { forecast.day }
}

public enum ForecastHistory {
    /// Only completed days and self-reported hours can contribute an observation.
    /// Each record keeps the time zone in which the person planned that day.
    public static func compare(_ records: [DayAheadForecast], reports: [CheckIn], corrections: [EnergyCorrection],
                               now: Date = .now, calendar: Calendar = .current) -> [ForecastComparison] {
        let ordered = records.filter(\.isValid).sorted { $0.day > $1.day }
        var timelines: [String: EnergyTimeline] = [:]
        return ordered.map { record in
            var observed: Double?
            if record.end <= now {
                var local = calendar
                local.timeZone = TimeZone(identifier: record.timeZoneID) ?? calendar.timeZone
                let timeline = timelines[record.timeZoneID] ?? EnergyTimeline(signals: [], checkIns: reports,
                    corrections: corrections, now: now, calendar: local)
                timelines[record.timeZoneID] = timeline
                if let point = timeline.daily(on: record.day), point.source == .corrected || point.source == .reported {
                    observed = point.score
                }
            }
            return ForecastComparison(forecast: record, observed: observed)
        }
    }
}
