import Foundation

/// Historical observations used to produce one modeled score. Raw recovery
/// readings live only in memory, alongside the Health timeline.
public struct EnergyModelBasis: Sendable {
    public enum Method: Sendable {
        case recovery(RecoveryReadings)
        case forecast(sameWeekday: Bool, hourly: Bool)
    }

    public struct Day: Identifiable, Sendable {
        public let date: Date
        public let rating: Double
        public let readings: RecoveryReadings?
        public var id: Date { date }
    }

    public let method: Method
    public let days: [Day]
    public var score: Double {
        let ratings = days.map(\.rating).sorted()
        return (ratings[(ratings.count - 1) / 2] + ratings[ratings.count / 2]) / 2
    }
}
