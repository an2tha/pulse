import Foundation

public struct RecoveryReadings: Hashable, Sendable {
    public var restingPulse: Double?
    public var variability: Double?
    public var sleepHours: Double?

    public init(restingPulse: Double?, variability: Double?, sleepHours: Double?) {
        self.restingPulse = restingPulse
        self.variability = variability
        self.sleepHours = sleepHours
    }

    /// Estimates the user's own rating from comparable days. Instantaneous heart rate
    /// and partial-day step totals are context, never direct measures of energy.
    public func estimate(history: [(RecoveryReadings, Double)]) -> (score: Double, days: Int)? {
        let matches = history.compactMap { previous, rating -> (Double, Double)? in
            guard rating.isFinite, (0...10).contains(rating) else { return nil }
            return distance(to: previous).map { ($0, rating) }
        }.sorted { $0.0 < $1.0 }.prefix(5)
        guard matches.count >= 3 else { return nil }
        let ratings = matches.map(\.1).sorted()
        let middle = ratings.count / 2
        return ((ratings[(ratings.count - 1) / 2] + ratings[middle]) / 2, ratings.count)
    }

    func distance(to previous: Self) -> Double? {
        let pairs = [(restingPulse, previous.restingPulse), (variability, previous.variability),
                     (sleepHours, previous.sleepHours)].compactMap { pair -> Double? in
            guard let current = pair.0, let earlier = pair.1, current.isFinite,
                  earlier.isFinite, current > 0, earlier > 0 else { return nil }
            return abs(log(current / earlier))
        }
        guard pairs.count >= 2 else { return nil }
        return pairs.reduce(0, +) / Double(pairs.count)
    }
}
