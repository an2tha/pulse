import Foundation

public struct EnergyActivity: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case boost, drain }
    public var id: UUID
    public var title: String
    public var minutes: Int
    public var kind: Kind

    public init(id: UUID = UUID(), title: String, minutes: Int, kind: Kind) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minutes = minutes
        self.kind = kind
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 80 && (1...240).contains(minutes)
    }

    private static func preset(_ suffix: String, _ title: String, _ minutes: Int, _ kind: Kind) -> Self {
        Self(id: UUID(uuidString: "055C1A06-301E-4D02-8411-0000000000" + suffix)!, title: title, minutes: minutes, kind: kind)
    }

    public static let presetBoosts: [Self] = [
        preset("01", "Quiet break", 5, .boost), preset("02", "Step outside", 5, .boost),
        preset("03", "Listen to music", 5, .boost), preset("04", "Gentle stretch", 3, .boost),
        preset("05", "Have a snack", 10, .boost), preset("06", "Talk to a friend", 10, .boost)
    ]
    public static let presets = presetBoosts + [
        preset("11", "Long meeting", 45, .drain), preset("12", "Commute", 30, .drain),
        preset("13", "Crowded place", 20, .drain), preset("14", "Back-to-back calls", 30, .drain),
        preset("15", "Difficult conversation", 15, .drain), preset("16", "Screen time", 20, .drain)
    ]
}

public struct EnergyActivityLog: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    /// Keep the activity as it was described when logged, even after later edits.
    public let activity: EnergyActivity
    public let started: Date
    public let before: Int
    public var after: Int?
    public var finished: Date?

    public init(activity: EnergyActivity, started: Date, before: Int, after: Int? = nil, finished: Date? = nil) {
        self.activity = activity
        self.started = started
        self.before = before
        self.after = after
        self.finished = finished
    }

    public var isValid: Bool {
        activity.isValid && abs(started.timeIntervalSince1970) < 32_000_000_000 && (0...10).contains(before)
            && after.map { (0...10).contains($0) } != false && (finished == nil) == (after == nil)
            && finished.map { $0 >= started && abs($0.timeIntervalSince1970) < 32_000_000_000 } != false
    }
    public var change: Int? { after.map { $0 - before } }

    /// Show a personal pattern only after repetitions on three different days.
    /// Give each day one vote so logging frequently on one day cannot dominate.
    public static func typicalChange(for id: UUID, in logs: [Self], calendar: Calendar = .current) -> (change: Double, days: Int)? {
        let entries = logs.filter { $0.activity.id == id && $0.change != nil && $0.isValid }
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.started) }
        guard byDay.count >= 3 else { return nil }
        let daily = byDay.values.compactMap { median($0.compactMap { $0.change.map(Double.init) }) }
        return median(daily).map { ($0, daily.count) }
    }
}

private func median(_ values: [Double]) -> Double? {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return nil }
    return sorted[(sorted.count - 1) / 2] / 2 + sorted[sorted.count / 2] / 2
}

public struct PersonalHRV: Equatable, Sendable {
    public struct Day: Equatable, Identifiable, Sendable {
        public let date: Date
        public let median: Double
        public var id: Date { date }
    }
    public let dailyMedians: [Day]
    public let current: Double?
    public let lastReading: Date?
    public let samples: Int
    public let baseline: Double?
    public let days: Int
    /// Percentile of this period's median among the user's previous daily medians.
    public let percentile: Int?
    public static let minimumDays = 7

    public init(signals: [EnergySignal], at date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let beginning = calendar.date(byAdding: .day, value: -28, to: day) ?? day
        let readings = signals.compactMap { sample -> (Date, Double)? in
            guard let value = sample.variability, value.isFinite, value > 0, sample.date >= beginning, sample.date <= date else { return nil }
            return (sample.date, value)
        }
        let today = readings.filter { $0.0 >= day }
        lastReading = today.map(\.0).max()
        guard let lastReading else {
            dailyMedians = []; current = nil; samples = 0; baseline = nil; days = 0; percentile = nil
            return
        }
        let period = calendar.component(.hour, from: lastReading) / 6
        let samePeriod = readings.filter { calendar.component(.hour, from: $0.0) / 6 == period }
        let currentValues = samePeriod.filter { $0.0 >= day }.map(\.1)
        current = median(currentValues)
        samples = currentValues.count
        let history = Dictionary(grouping: samePeriod.filter { $0.0 < day }) { calendar.startOfDay(for: $0.0) }
        let prior = history.compactMap { day, samples in
            median(samples.map(\.1)).map { Day(date: day, median: $0) }
        }.sorted { $0.date < $1.date }
        dailyMedians = prior + (current.map { [Day(date: day, median: $0)] } ?? [])
        let daily = prior.map(\.median)
        days = daily.count
        baseline = median(daily)
        guard daily.count >= Self.minimumDays, let current else { percentile = nil; return }
        let below = daily.count { $0 < current }
        let equal = daily.count { $0 == current }
        percentile = Int(((Double(below) + 0.5 * Double(equal)) * 100 / Double(daily.count)).rounded())
    }
}
