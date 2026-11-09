import Foundation

/// A journal correction takes effect at its recorded time. Replacing the same date edits that observation.
public struct EnergyCorrection: Codable, Equatable, Identifiable, Sendable {
    public let date: Date
    public let score: Double
    public var id: Date { date }
    public init(date: Date, score: Double) {
        self.date = date
        self.score = score
    }
}

public struct EnergySignal: Equatable, Sendable {
    public let date: Date
    public let restingPulse: Double?
    public let variability: Double?
    public let sleepHours: Double?
    public init(date: Date, restingPulse: Double? = nil, variability: Double? = nil, sleepHours: Double? = nil) {
        self.date = date
        self.restingPulse = restingPulse
        self.variability = variability
        self.sleepHours = sleepHours
    }
}

public enum EnergySource: String, Sendable, Codable {
    case corrected, reported, estimated, forecast, expected, rhythm
}

public struct EnergyPoint: Equatable, Identifiable, Sendable {
    public let date: Date
    public let score: Double
    public let source: EnergySource
    public let supportDays: Int
    public internal(set) var sleepBased = false
    public var id: Date { date }
}

/// Historical estimates use only information available by the requested instant.
/// Forecast support counts distinct local days, so frequent logging cannot manufacture confidence.
public struct EnergyTimeline: Sendable {
    private let sleepNights: [SleepNight]
    private let sleepTarget: Double?
    let now: Date
    private let calendar: Calendar
    private let signals: [Date: [EnergySignal]]
    private let ratings: [Date: [EnergyPoint]]
    private let ratedHours: [Date: [EnergyPoint]]
    private let calibration: RecoveryCalibration
    private let expectations: [EnergyExpectation]
    public static let forecastDays = 6

    public init(signals: [EnergySignal], checkIns: [CheckIn], corrections: [EnergyCorrection],
                now: Date = .now, calendar: Calendar = .current, expectations: [EnergyExpectation] = [],
                sleepNights: [SleepNight] = [], sleepTarget: Double? = nil) {
        self.sleepNights = sleepNights.filter { $0.wake <= now }
        self.sleepTarget = sleepTarget
        self.now = now
        self.calendar = calendar
        let horizon = calendar.date(byAdding: .day, value: Self.forecastDays + 1, to: calendar.startOfDay(for: now)) ?? now
        self.expectations = expectations.filter {
            guard $0.isValid else { return false }
            let window = $0.interval(in: calendar)
            return window.end > now && window.start < horizon
        }
        let group = { (date: Date) in calendar.startOfDay(for: date) }
        self.signals = Dictionary(grouping: signals.filter { $0.date <= now }.sorted { $0.date < $1.date }) { group($0.date) }
        var scores: [Date: EnergyPoint] = [:]
        for check in checkIns where check.date <= now && (0...10).contains(check.energy) {
            scores[check.date] = EnergyPoint(date: check.date, score: check.energy, source: .reported, supportDays: 1)
        }
        for correction in corrections where correction.date <= now && (0...10).contains(correction.score) {
            scores[correction.date] = EnergyPoint(date: correction.date, score: correction.score, source: .corrected, supportDays: 1)
        }
        ratings = Dictionary(grouping: scores.values.sorted { $0.date < $1.date }) { group($0.date) }
        ratedHours = ratings.mapValues { points in
            let buckets = Dictionary(grouping: points) { calendar.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date }
            return buckets.map { hour, points in
                if let correction = points.last(where: { $0.source == .corrected }) { return correction }
                return EnergyPoint(date: hour, score: Self.mean(points.map(\.score)), source: .reported, supportDays: 1)
            }.sorted { $0.date < $1.date }
        }
        calibration = RecoveryCalibration(ratings: ratings, signals: self.signals, calendar: calendar)
    }

    private func recovery(at date: Date) -> (readings: RecoveryReadings, days: [EnergyModelBasis.Day])? {
        let day = calendar.startOfDay(for: date)
        guard let samples = signals[day] else { return nil }
        var current = RecoveryReadings(restingPulse: nil, variability: nil, sleepHours: nil)
        for sample in samples.prefix(while: { $0.date <= date }) { current.include(sample) }
        guard current.signalCount >= 2 else { return nil }
        return (current, calibration.matchedDays(current, before: day))
    }

    /// Used by Health to show how many prior days can support today's estimate.
    public func comparableDays(at date: Date) -> Int? { recovery(at: date)?.days.count }

    private static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

    /// A correction overrides this hour; subsequent hours use their own evidence.
    /// A check-in carries into at most the next three hours.
    public func estimate(at date: Date) -> EnergyPoint? {
        let day = calendar.startOfDay(for: date)
        if date > now {
            if let end = calendar.dateInterval(of: .hour, for: now)?.end, date < end,
               let current = estimate(at: now) {
                return EnergyPoint(date: date, score: current.score, source: current.source, supportDays: current.supportDays, sleepBased: current.sleepBased)
            }
            return expected(at: date) ?? forecast(at: date, hourly: true)
                ?? (calendar.isDate(date, inSameDayAs: now) ? sleepEstimate(at: date) : nil)
        }
        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        if let correction = ratings[day]?.last(where: { $0.source == .corrected && $0.date >= hourStart && $0.date <= date }) {
            return EnergyPoint(date: date, score: correction.score, source: .corrected, supportDays: 1)
        }
        if let recent = ratings[day]?.last(where: { $0.source == .reported && $0.date <= date }),
           date.timeIntervalSince(recent.date) < 3 * 3600 {
            if date == now, recent.date < hourStart, let point = expected(at: date) { return point }
            return EnergyPoint(date: date, score: recent.score, source: recent.date >= hourStart ? .reported : .estimated, supportDays: 1)
        }
        if date == now, let point = expected(at: date) { return point }
        guard let match = recovery(at: date), match.days.count >= 3 else {
            return sleepEstimate(at: date)
        }
        let basis = EnergyModelBasis(method: .recovery(match.readings), days: match.days)
        return EnergyPoint(date: date, score: basis.score, source: .estimated, supportDays: match.days.count)
    }

    private func sleepEstimate(at date: Date) -> EnergyPoint? {
        guard !sleepNights.isEmpty else { return nil }
        let history = SleepHistory(nights: sleepNights, at: date, target: sleepTarget, calendar: calendar)
        guard let score = history.energy else { return nil }
        return EnergyPoint(date: date, score: score, source: .estimated, supportDays: history.nights.count, sleepBased: true)
    }

    /// Local calendar days include the repeated hour in autumn and omit the skipped hour in spring.
    public func hours(on date: Date) -> [EnergyPoint] {
        guard let bounds = calendar.dateInterval(of: .day, for: date) else { return [] }
        var result: [EnergyPoint] = []
        var hour = bounds.start
        while hour < bounds.end {
            let end = min(bounds.end, hour.addingTimeInterval(3600))
            let point = estimate(at: hour > now ? hour : min(now, end.addingTimeInterval(-0.001)))
            if let point { result.append(EnergyPoint(date: hour, score: point.score, source: point.source, supportDays: point.supportDays, sleepBased: point.sleepBased)) }
            hour = end
        }
        return result
    }

    /// Learn local deviations from the schedule without counting frequent check-ins
    /// on one day as independent days. Only completed earlier days contribute.
    private func rhythmPoint(at hour: Date, prior: ScheduleEnergyRhythm, baseline: Double) -> EnergyPoint {
        let day = calendar.startOfDay(for: min(hour, now))
        let start = calendar.date(byAdding: .day, value: -28, to: day) ?? day
        let slot = calendar.component(.hour, from: hour)
        var total = 0.0
        var weight = 0.0
        var days = 0
        for (observedDay, samples) in ratedHours where observedDay >= start && observedDay < day {
            var residual = 0.0
            var proximity = 0.0
            for sample in samples {
                let distance = abs(calendar.component(.hour, from: sample.date) - slot)
                let hoursApart = min(distance, 24 - distance)
                guard hoursApart <= 2 else { continue }
                let influence = 1 / Double(1 + hoursApart)
                residual += (sample.score - prior.score(at: sample.date)) * influence
                proximity += influence
            }
            guard proximity > 0 else { continue }
            let age = day.timeIntervalSince(observedDay) / 86400
            let dayWeight = min(1, proximity) * exp(-age / 14)
            total += dayWeight * residual / proximity
            weight += dayWeight
            days += 1
        }
        // Four prior-equivalent days keep isolated observations from dominating.
        let score = min(10, max(0, baseline + total / (4 + weight)))
        return EnergyPoint(date: hour, score: score, source: .rhythm, supportDays: days)
    }

    /// Every planning hour has a value, even before Health access or the first check-in.
    /// Evidence-only APIs stay sparse for reports, calibration and forecast evaluation.
    public func projectedHours(on date: Date, sleepWindow: PlannedSleepWindow, referenceWindow: PlannedSleepWindow? = nil) -> [EnergyPoint] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        let rhythm = ScheduleEnergyRhythm(window: sleepWindow, calendar: calendar)
        let reference = ScheduleEnergyRhythm(window: referenceWindow ?? sleepWindow, calendar: calendar)
        let observations = Dictionary(uniqueKeysWithValues: hours(on: date).map { ($0.date, $0) })
        let history = SleepHistory(nights: sleepNights, at: min(now, date), target: sleepTarget, calendar: calendar)
        let futureDay = day.start > calendar.startOfDay(for: now)
        let projectedDebt = max(0, (history.debt ?? 0) + history.need - Double(sleepWindow.minutes) / 60)
        let debtPenalty = futureDay ? min(3, projectedDebt / 4) : 0
        var result: [EnergyPoint] = []
        var hour = day.start
        while hour < day.end {
            let baseline = max(0, rhythm.score(at: hour) - debtPenalty)
            if let point = observations[hour] {
                if point.source == .forecast || point.sleepBased || (point.source == .estimated && point.supportDays >= 3) {
                    // A few comparable days should nudge the prior. More days give
                    // the person's own estimates proportionally greater influence.
                    let weight = Double(point.supportDays) / Double(point.supportDays + 4)
                    let personalized: Double
                    if point.sleepBased {
                        // Sleep supplies a daily level. Preserve the variation by time of day.
                        personalized = baseline + point.score - 7
                    } else {
                        personalized = baseline + point.score - reference.score(at: hour)
                    }
                    let score = min(10, max(0, baseline + weight * (personalized - baseline)))
                    result.append(EnergyPoint(date: hour, score: score, source: point.source,
                                              supportDays: point.supportDays, sleepBased: point.sleepBased))
                } else {
                    result.append(point)
                }
            } else {
                result.append(rhythmPoint(at: hour, prior: reference, baseline: baseline))
            }
            hour = hour.addingTimeInterval(3600)
        }
        return result
    }

    public func daily(on date: Date) -> EnergyPoint? {
        guard let bounds = calendar.dateInterval(of: .day, for: date) else { return nil }
        if bounds.start > now {
            if let edit = expectations.last(where: { $0.scope == .day && $0.interval(in: calendar) == bounds }) {
                return EnergyPoint(date: bounds.start, score: edit.score, source: .expected, supportDays: 0)
            }
            return forecast(at: bounds.start, hourly: false)
        }
        if let points = ratedHours[bounds.start] {
            let corrected = points.allSatisfy { $0.source == .corrected }
            return EnergyPoint(date: bounds.start, score: Self.mean(points.map(\.score)),
                               source: corrected ? .corrected : .reported, supportDays: 1)
        }
        guard let point = estimate(at: min(now, bounds.end.addingTimeInterval(-0.001))) else { return nil }
        return EnergyPoint(date: bounds.start, score: point.score, source: point.source, supportDays: point.supportDays, sleepBased: point.sleepBased)
    }

    private func expected(at date: Date) -> EnergyPoint? {
        EnergyExpectation.applicable(at: date, in: expectations, calendar: calendar).map {
            EnergyPoint(date: date, score: $0.score, source: .expected, supportDays: 0)
        }
    }

    public func modeledDailyForecast(on date: Date) -> EnergyPoint? {
        let day = calendar.startOfDay(for: date)
        guard day > now else { return nil }
        return forecast(at: day, hourly: false)
    }

    private func forecast(at date: Date, hourly: Bool) -> EnergyPoint? {
        guard let basis = forecastBasis(at: date, hourly: hourly) else { return nil }
        return EnergyPoint(date: date, score: basis.score, source: .forecast, supportDays: basis.days.count)
    }

    private func forecastBasis(at date: Date, hourly: Bool) -> EnergyModelBasis? {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: Self.forecastDays + 1, to: today), date < end,
              let start = calendar.date(byAdding: .day, value: -28, to: today) else { return nil }
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        var all: [EnergyModelBasis.Day] = []
        var sameWeekday: [EnergyModelBasis.Day] = []
        for (day, points) in ratedHours where day >= start {
            let relevant = hourly ? points.filter {
                let distance = abs(calendar.component(.hour, from: $0.date) - hour)
                return min(distance, 24 - distance) <= 1
            } : points
            guard !relevant.isEmpty else { continue }
            let value = EnergyModelBasis.Day(date: day, rating: Self.mean(relevant.map(\.score)), readings: nil)
            all.append(value)
            if calendar.component(.weekday, from: day) == weekday { sameWeekday.append(value) }
        }
        let usesWeekday = sameWeekday.count >= 3
        let sample = usesWeekday ? sameWeekday : all
        guard sample.count >= 3 else { return nil }
        return EnergyModelBasis(method: .forecast(sameWeekday: usesWeekday, hourly: hourly), days: sample)
    }

    /// Return the observations behind the score shown in Health. Direct entries and
    /// manually chosen expectations have their own attribution on the main screen.
    public func modelBasis(at date: Date, daily: Bool) -> EnergyModelBasis? {
        let displayed = daily ? self.daily(on: date) : estimate(at: date)
        if displayed?.source == .forecast { return forecastBasis(at: date, hourly: !daily) }
        guard displayed?.source == .estimated, displayed?.sleepBased == false, (displayed?.supportDays ?? 0) >= 3,
              let day = calendar.dateInterval(of: .day, for: date) else { return nil }
        let requested = daily ? min(now, day.end.addingTimeInterval(-0.001)) : min(now, date)
        guard let match = recovery(at: requested), match.days.count >= 3 else { return nil }
        return EnergyModelBasis(method: .recovery(match.readings), days: match.days)
    }
}
