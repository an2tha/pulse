import Foundation

public struct DayPlanRecord: Codable, Equatable, Sendable {
    public let day: Date
    public let minutes: Int
    public let tasks: [UUID]
    public init?(date: Date, blocks: [Block], calendar: Calendar = .current) {
        let work = blocks.compactMap { b -> (UUID, Int)? in
            if case .task(let id) = b.kind { return (id, b.minutes) }
            return nil
        }
        guard !work.isEmpty else { return nil }
        day = calendar.startOfDay(for: date)
        minutes = work.reduce(0) { $0 + $1.1 }
        tasks = work.map(\.0)
    }
}

public enum ReviewStats {
    public struct Association: Sendable {
        public let days: Int
        public let correlation: Double
    }
    public static func sleepAssociation(_ reports: [CheckIn], calendar: Calendar = .current)
        -> Association?
    {
        let pairs = Dictionary(
            grouping: reports.filter { $0.sleep != nil }, by: { calendar.startOfDay(for: $0.date) }
        )
        .values.map { values in
            (
                values.compactMap(\.sleep).reduce(0, +) / Double(values.count),
                values.map(\.energy).reduce(0, +) / Double(values.count)
            )
        }
        guard pairs.count >= 5 else { return nil }
        let x = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let y = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        var covariance = 0.0
        var xx = 0.0
        var yy = 0.0
        for pair in pairs {
            let dx = pair.0 - x
            let dy = pair.1 - y
            covariance += dx * dy
            xx += dx * dx
            yy += dy * dy
        }
        guard xx > 0, yy > 0 else { return nil }
        return Association(days: pairs.count, correlation: max(-1, min(1, covariance / sqrt(xx * yy))))
    }
    public static func longerChange(_ reports: [CheckIn], at now: Date, calendar: Calendar = .current)
        -> Double?
    {
        guard let end = calendar.dateInterval(of: .day, for: now)?.end,
            let middle = calendar.date(byAdding: .day, value: -14, to: end),
            let begin = calendar.date(byAdding: .day, value: -28, to: end)
        else { return nil }
        let grouped = Dictionary(
            grouping: reports.filter { $0.date >= begin && $0.date <= now },
            by: { calendar.startOfDay(for: $0.date) })
        func mean(_ sample: [Double]) -> Double? {
            sample.count >= 5 ? sample.reduce(0, +) / Double(sample.count) : nil
        }
        let daily = grouped.mapValues { $0.map(\.energy).reduce(0, +) / Double($0.count) }
        guard let old = mean(daily.filter { $0.key < middle }.map(\.value)),
            let new = mean(daily.filter { $0.key >= middle }.map(\.value))
        else { return nil }
        return new - old
    }
}
