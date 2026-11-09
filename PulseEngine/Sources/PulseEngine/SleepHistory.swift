import Foundation

public struct SleepNight: Equatable, Sendable {
    public let wake: Date
    public let hours: Double

    // Join nearby stages into one sleep period. Overlapping sources count once.
    public static func collect(_ intervals: [DateInterval], calendar: Calendar = .current) -> [Self] {
        var sessions: [Self] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let last = sessions.last, interval.start.timeIntervalSince(last.wake) <= 7200 {
                let extra = max(0, interval.end.timeIntervalSince(max(last.wake, interval.start)))
                sessions[sessions.count - 1] = Self(wake: max(last.wake, interval.end), hours: last.hours + extra / 3600)
            } else {
                sessions.append(Self(wake: interval.end, hours: interval.duration / 3600))
            }
        }
        let byDay = Dictionary(grouping: sessions.filter { (2...16).contains($0.hours) }) { calendar.startOfDay(for: $0.wake) }
        return byDay.values.compactMap { $0.max { $0.hours < $1.hours } }.sorted { $0.wake < $1.wake }
    }
}

public struct SleepHistory: Sendable {
    public let nights: [SleepNight]
    public let recentCount: Int
    public let need: Double
    public let debt: Double?
    public let energy: Double?

    public init(nights: [SleepNight], at date: Date, target: Double? = nil, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -27, to: day)!
        self.nights = nights.filter { $0.wake >= start && $0.wake <= date }.sorted { $0.wake < $1.wake }
        let durations = self.nights.map(\.hours).sorted()
        // A conservative starting target shifts toward longer observed sleeps as coverage grows.
        let weight = min(1, Double(durations.count) / 14)
        let upper = durations.isEmpty ? 8 : durations[Int(Double(durations.count - 1) * 0.75)]
        let suggested = min(9, max(7, 8 + weight * (upper - 8)))
        need = target.flatMap { (4...12).contains($0) ? $0 : nil } ?? (suggested * 4).rounded() / 4
        let recentStart = calendar.date(byAdding: .day, value: -13, to: day)!
        let recent = self.nights.filter { $0.wake >= recentStart }
        recentCount = recent.count
        var balance = 0.0
        for night in recent { balance = max(0, balance + need - night.hours) }
        debt = recent.isEmpty ? nil : balance
        if let last = recent.last, calendar.isDate(last.wake, inSameDayAs: date) {
            let awake = date.timeIntervalSince(last.wake) / 3600
            let shortfall = max(0, need - last.hours)
            energy = min(10, max(0, 8 - shortfall - min(3, balance / 4) - max(0, awake - 10) / 3))
        } else { energy = nil }
    }
}
