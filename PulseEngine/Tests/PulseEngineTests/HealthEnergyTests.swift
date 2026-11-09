import Testing
@testable import PulseEngine

@Suite struct HealthEnergyTests {
    @Test func needsComparableDaysAndMultipleSignals() {
        let today = RecoveryReadings(restingPulse: 55, variability: 50, sleepHours: nil)
        #expect(today.estimate(history: [(today, 6), (today, 7)]) == nil)
        let sparse = RecoveryReadings(restingPulse: 55, variability: nil, sleepHours: nil)
        #expect(today.estimate(history: Array(repeating: (sparse, 7), count: 4)) == nil)
        #expect(today.estimate(history: [(today, 3), (today, 6), (today, 8)])?.score == 6)
    }
}
