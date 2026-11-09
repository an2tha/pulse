import Foundation

/// A time window the person chose while planning. It never contributes a sample
/// to personal history, calibration, or future forecast training.
public struct EnergyExpectation: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable { case day, hour }
    public let id: UUID
    public let start: Date
    public let end: Date
    public let score: Double
    public let scope: Scope
    public let timeZoneID: String?

    public init?(at date: Date, scope: Scope, score: Double, calendar: Calendar = .current) {
        guard (0...10).contains(score),
              let window = calendar.dateInterval(of: scope == .day ? .day : .hour, for: date) else { return nil }
        self.id = UUID()
        self.start = window.start
        self.end = window.end
        self.score = score
        self.scope = scope
        self.timeZoneID = calendar.timeZone.identifier
    }

    public var isValid: Bool {
        (0...10).contains(score) && start < end && abs(start.timeIntervalSince1970) < 32_000_000_000
            && abs(end.timeIntervalSince1970) < 32_000_000_000
            && end.timeIntervalSince(start) <= (scope == .hour ? 7200 : 26 * 3600)
            && timeZoneID.map { TimeZone(identifier: $0) != nil } != false
    }

    /// An entire Wednesday stays Wednesday after travel. An individual hour
    /// keeps its chosen instant, like a timed appointment on the same plan.
    public func interval(in calendar: Calendar) -> DateInterval {
        let recorded = DateInterval(start: start, duration: max(0, end.timeIntervalSince(start)))
        guard scope == .day, let timeZoneID, timeZoneID != calendar.timeZone.identifier,
              let originalZone = TimeZone(identifier: timeZoneID) else { return recorded }
        var original = calendar
        original.timeZone = originalZone
        let civil = original.dateComponents([.era, .year, .month, .day], from: start)
        guard let date = calendar.date(from: civil), let window = calendar.dateInterval(of: .day, for: date) else { return recorded }
        return window
    }

    public static func applicable(at time: Date, in edits: [Self], calendar: Calendar = .current) -> Self? {
        let matches: (Self) -> Bool = { edit in
            let window = edit.interval(in: calendar)
            return window.start <= time && time < window.end
        }
        return edits.last { $0.scope == .hour && matches($0) } ?? edits.last { $0.scope == .day && matches($0) }
    }
}

extension PlannerPreferences {
    /// These intervals affect flexible work. Fixed appointments retain their
    /// actual times, including appointments inside a zero-energy window.
    func zeroEnergyWindows(on date: Date, reports: [CheckIn], calendar: Calendar) -> [DateInterval] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        let edits = expectations.filter { edit in
            let window = edit.interval(in: calendar)
            return window.start < day.end && day.start < window.end
        }
        guard edits.contains(where: { $0.score == 0 }) else { return [] }
        var boundaries = Set([day.start, day.end])
        for edit in edits {
            let window = edit.interval(in: calendar)
            boundaries.insert(max(day.start, window.start))
            boundaries.insert(min(day.end, window.end))
        }
        // Observations take effect at their timestamp and override a forecast in
        // their own hour. Past and future hours retain their separate meanings.
        for time in reports.map(\.date) + corrections.map(\.date) where time >= day.start && time < day.end {
            boundaries.insert(time)
            if let end = calendar.dateInterval(of: .hour, for: time)?.end { boundaries.insert(min(end, day.end)) }
        }
        let sorted = boundaries.sorted()
        return zip(sorted, sorted.dropFirst()).compactMap { start, end in
            guard EnergyExpectation.applicable(at: start, in: edits, calendar: calendar)?.score == 0,
                  capacity(at: start, reports: reports, calendar: calendar) == 0 else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}
