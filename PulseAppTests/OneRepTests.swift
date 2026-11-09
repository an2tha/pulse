import Foundation
import Testing

@testable import Pulse

@Suite struct OneRepTests {
    @Test func quickLogCarriesOnlyTheLocalGregorianDate() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-01-01T01:30:00Z"))
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(OneRepDestination.quickLog.url(at: now, timeZone: pacific).absoluteString == "onerep://workouts?logPast=2025-12-31")
        #expect(OneRepDestination.quickLog.url(at: now, timeZone: .gmt).absoluteString == "onerep://workouts?logPast=2026-01-01")
        #expect(OneRepDestination.coach.url().absoluteString == "onerep://coach")
        #expect(OneRepDestination.progress.url().absoluteString == "onerep://progress")
    }

    @Test func missingMeasurementsStayDistinctFromARecordedZero() {
        var stats = OneRepHealthStats()
        #expect(!stats.hasReadings)
        stats.waterML = 0
        #expect(stats.hasReadings)
        #expect(OneRepHealthReader.sourceBundle == "com.ananthh.onerep")
    }
}
