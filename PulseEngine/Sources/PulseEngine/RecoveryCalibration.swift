import Foundation

/// Pair each rating with measurements already available when it was entered.
/// Each local day can cast one vote for the current recovery estimate.
struct RecoveryCalibration: Sendable {
    private struct Profile: Sendable {
        let readings: RecoveryReadings
        let rating: Double
        let first: Date
    }
    private var days: [(date: Date, profiles: [Profile])] = []

    init(ratings: [Date: [EnergyPoint]], signals: [Date: [EnergySignal]], calendar: Calendar) {
        for day in signals.keys.sorted() {
            guard let samples = signals[day], let points = ratings[day] else { continue }
            let buckets = Dictionary(grouping: points) { calendar.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date }
            var paired: [RecoveryReadings: [Date: [Double]]] = [:]
            var firstRating: [RecoveryReadings: Date] = [:]
            var index = 0
            var readings = RecoveryReadings(restingPulse: nil, variability: nil, sleepHours: nil)
            for hour in buckets.keys.sorted() {
                guard let bucket = buckets[hour] else { continue }
                // A correction replaces the reported values for the same hour.
                let rated = bucket.last(where: { $0.source == .corrected }).map { [$0] } ?? bucket
                for point in rated {
                    while index < samples.count && samples[index].date <= point.date {
                        readings.include(samples[index])
                        index += 1
                    }
                    guard readings.signalCount >= 2 else { continue }
                    if firstRating[readings] == nil { firstRating[readings] = point.date }
                    paired[readings, default: [:]][hour, default: []].append(point.score)
                }
            }
            let profiles: [Profile] = paired.compactMap { readings, hours in
                guard let first = firstRating[readings] else { return nil }
                let hourlyScores = hours.keys.sorted().compactMap { hours[$0] }.map { $0.reduce(0, +) / Double($0.count) }
                return Profile(readings: readings, rating: hourlyScores.reduce(0, +) / Double(hourlyScores.count), first: first)
            }.sorted { $0.first < $1.first }
            if !profiles.isEmpty { days.append((day, profiles)) }
        }
    }

    func matchedDays(_ current: RecoveryReadings, before day: Date) -> [EnergyModelBasis.Day] {
        let candidates = days.prefix { $0.date < day }.compactMap { history -> (Double, EnergyModelBasis.Day)? in
            let closest = history.profiles.compactMap { profile in
                current.distance(to: profile.readings).map { ($0, profile) }
            }.min { $0.0 < $1.0 }
            guard let (distance, profile) = closest else { return nil }
            return (distance, .init(date: history.date, rating: profile.rating, readings: profile.readings))
        }
        return candidates.sorted { $0.0 < $1.0 }.prefix(5).map(\.1)
    }
}

extension RecoveryReadings {
    var signalCount: Int {
        [restingPulse, variability, sleepHours].compactMap { $0 }.count { $0.isFinite && $0 > 0 }
    }

    mutating func include(_ signal: EnergySignal) {
        if let value = signal.restingPulse, value.isFinite, value > 0 { restingPulse = value }
        if let value = signal.variability, value.isFinite, value > 0 { variability = value }
        if let value = signal.sleepHours, value.isFinite, value > 0 { sleepHours = value }
    }
}
