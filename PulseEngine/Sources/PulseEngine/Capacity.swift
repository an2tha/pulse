import Foundation

public enum Capacity {
    public static func scale(_ x: Double) -> Double { x.isFinite ? min(10, max(0, x)) : 0 }
    public static func score(_ report: CheckIn) -> Double {
        let reported = 0.35 * report.energy + 0.25 * report.interest + 0.20 * report.clarity
        // When sleep is unreported, normalize the three observed weights.
        return report.sleep.map { reported + 0.20 * $0 } ?? reported / 0.80
    }
    public static func baseline(_ values: [Double], alpha: Double = 0.15) -> Double? {
        guard let first = values.first else { return nil }
        let a = min(1, max(0, alpha))
        return values.dropFirst().reduce(scale(first)) { a * scale($1) + (1 - a) * $0 }
    }
    public static func residual(observed: Double, predicted: Double) -> Double { observed - predicted }
    public static func errors(_ reports: [CheckIn]) -> [Double] {
        var estimate: Double?
        var result: [Double] = []
        for r in reports.sorted(by: { $0.date < $1.date }) {
            if let previous = estimate { result.append(residual(observed: r.energy, predicted: previous)) }
            estimate = estimate.map { 0.15 * r.energy + 0.85 * $0 } ?? r.energy
        }
        return result
    }
    /// Root mean squared error, in scale points. This is descriptive, not a probability.
    public static func uncertainty(_ errors: [Double], window: Int = 14) -> Double? {
        let recent = errors.suffix(max(0, window))
        guard recent.count >= 3 else { return nil }
        return sqrt(recent.reduce(0) { $0 + $1 * $1 } / Double(recent.count))
    }
    /// Compares the newest residual only against earlier errors. A two-point
    /// floor avoids flagging tiny changes following a flat reporting period.
    public static func unusualResidual(_ errors: [Double]) -> Double? {
        guard let latest = errors.last, let previous = uncertainty(Array(errors.dropLast())) else { return nil }
        return abs(latest) > max(2, 2 * previous) ? latest : nil
    }
    /// Empirical middle 80% of recent signed errors around a baseline.
    /// A descriptive range, without a claim of calibrated future coverage.
    public static func usualRange(baseline: Double, errors: [Double]) -> ClosedRange<Double>? {
        let values = errors.suffix(30).sorted()
        guard values.count >= 10 else { return nil }
        let n = Double(values.count - 1)
        let lower = values[Int((n * 0.1).rounded(.down))]
        let upper = values[Int((n * 0.9).rounded(.up))]
        return scale(baseline + lower)...scale(baseline + upper)
    }
    public static func friction(effort: Double, overwhelm: Double, setup: Double) -> Double {
        0.4 * scale(effort) + 0.3 * scale(overwhelm) + 0.3 * scale(setup)
    }
    public static func priority(_ task: PlanTask, capacity: Double, at date: Date) -> Double {
        let days = task.due.map { max(0, $0.timeIntervalSince(date) / 86400) }
        let urgency = days.map { 10 / (1 + $0) } ?? 0
        let resistance = friction(effort: task.effort, overwhelm: task.overwhelm, setup: task.setup)
        let mismatch = max(0, task.energyDemand - scale(capacity))
        let fit = 0.09 * max(0, scale(capacity) - 6) * min(task.energyDemand, scale(capacity))
        return fit - 0.45 * mismatch + 0.4 * scale(task.importance) + 0.3 * urgency + 0.2 * (10 - max(0, resistance - capacity)) + 0.1
            * (10 - resistance)
    }
    public static func block(minutes: Int, capacity: Double, limit: Int) -> Int {
        guard minutes > 0, limit > 0, capacity > 0 else { return 0 }
        return min(minutes, limit, max(3, Int((scale(capacity) * 3).rounded())))
    }
    public static func workloadLimit(userLimit: Int, reports: [CheckIn], at date: Date, calendar: Calendar) -> Int {
        let history = reports.filter { $0.date <= date }.sorted { $0.date < $1.date }
        let limit = max(0, userLimit)
        guard let latest = history.last else { return limit }
        let today = calendar.isDate(latest.date, inSameDayAs: date)
        let recentStart = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: date)) ?? date
        let recent = history.filter { $0.date >= recentStart }
        let lowDays = Set(recent.filter { $0.energy <= 3 }.map { calendar.startOfDay(for: $0.date) })
        if today && latest.feltWorseAfterActivity == true { return 0 }
        if lowDays.count >= 2 { return min(limit, Int(recent.map(\.energy).min() ?? 0) * 3) }
        if today && latest.energy <= 3 {
            return min(limit, max(0, Int(latest.energy) * 3))
        }
        return limit
    }
    public static func estimate(at date: Date, reports: [CheckIn], calendar: Calendar) -> Double {
        let history = reports.filter { $0.date <= date }.sorted { $0.date < $1.date }
        let recent = history.last.flatMap { calendar.isDate($0.date, inSameDayAs: date) ? $0 : nil }
        let hour = calendar.component(.hour, from: date)
        let nearby = history.filter { abs(calendar.component(.hour, from: $0.date) - hour) <= 1 }
        let usual = baseline((nearby.count >= 3 ? nearby : history).map(\.energy)) ?? 5
        // A prediction may lower a suggestion, but cannot override a lower report.
        return combine(usual: usual, latestToday: recent)
    }

    private static func combine(usual: Double, latestToday: CheckIn?) -> Double {
        latestToday.map { min(score($0), $0.energy, usual * 0.2 + score($0) * 0.8) } ?? usual
    }

    /// Every trial in a placement search uses the same check-in history. Once all
    /// reports precede a trial, only its local hour and its latest same-day report matter.
    struct HourlyBaseline: Sendable {
        let latest: CheckIn?
        private let hours: [Double]

        init(_ reports: [CheckIn], calendar: Calendar) {
            let sorted = reports.sorted { $0.date < $1.date }
            latest = sorted.last
            let fallback = Capacity.baseline(sorted.map(\.energy)) ?? 5
            var readings = Array(repeating: [Double](), count: 24)
            for report in sorted {
                let hour = calendar.component(.hour, from: report.date)
                for target in max(0, hour - 1)...min(23, hour + 1) { readings[target].append(report.energy) }
            }
            hours = readings.map { $0.count >= 3 ? (Capacity.baseline($0) ?? fallback) : fallback }
        }

        func estimate(at time: Date, calendar: Calendar) -> Double? {
            guard let latest else { return 5 }
            guard latest.date <= time else { return nil }
            let hour = calendar.component(.hour, from: time)
            return Capacity.combine(usual: hours[hour], latestToday: calendar.isDate(latest.date, inSameDayAs: time) ? latest : nil)
        }
    }
}

public enum Rhythms {
    public static func firstActionDelays(reports: [CheckIn], sessions: [SessionRecord], calendar: Calendar = .current)
        -> [(Date, Double)]
    {
        let firstReports = Dictionary(grouping: reports, by: { calendar.startOfDay(for: $0.date) })
        return firstReports.compactMap { day, checks in
            guard let first = checks.map(\.date).min(),
                let start = sessions.filter({ calendar.isDate($0.start, inSameDayAs: day) }).map(\.start).min(),
                start >= first
            else { return nil }
            return (day, start.timeIntervalSince(first) / 60)
        }.sorted { $0.0 < $1.0 }
    }
}
