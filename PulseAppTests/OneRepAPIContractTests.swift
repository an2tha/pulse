import Foundation
import Testing

@testable import Pulse

@Suite struct OneRepAPIContractTests {
    private let day = "2026-11-09"
    private let diary = Data(#"{"date":"2026-11-09","nutrition":{"protein":0,"entries":[{"name":"Black coffee"}]},"waterMl":0,"waterEntries":[],"workouts":[{"durationMinutes":20},{"durationMinutes":15}],"restDay":false}"#.utf8)

    @Test func selectedDayIncludesAllSessionsAndOnlyItsOwnHealthReadings() throws {
        let health = Data(#"{"days":[{"date":"2026-11-08","steps":9999},{"date":"2026-11-09","sleepMinutes":450,"restingHeartRateBpm":56,"hrvMs":null,"steps":0,"activeEnergyKcal":412}]}"#.utf8)
        let result = try OneRepAPI.summary(diaryData: diary, healthData: health, day: day)
        #expect(result.workoutCount == 2)
        #expect(result.trainingMinutes == 35)
        #expect(result.proteinGrams == 0)
        #expect(result.waterML == nil)
        #expect(result.sleepMinutes == 450)
        #expect(result.restingHeartRateBPM == 56)
        #expect(result.steps == 0)
        #expect(result.hrvMS == nil)
        #expect(result.activeEnergyKcal == 412)
    }

    @Test func absenceOfHealthSyncPreservesDiaryAndRestDay() throws {
        let rest = Data(#"{"date":"2026-11-09","nutrition":{"protein":0,"entries":[]},"waterMl":250,"waterEntries":[{"amountMl":250}],"workouts":[],"restDay":true}"#.utf8)
        let result = try OneRepAPI.summary(diaryData: rest, healthData: Data(#"{"days":[]}"#.utf8), day: day)
        #expect(result.restDay && result.workoutCount == 0)
        #expect(result.waterML == 250)
        #expect(result.proteinGrams == nil && result.steps == nil)
    }

    @Test func wrongDayOrInvalidResponseRaisesError() {
        #expect(throws: OneRepAPIError.self) {
            try OneRepAPI.summary(diaryData: diary, healthData: Data(#"{"days":[]}"#.utf8), day: "2026-11-08")
        }
        #expect(throws: OneRepAPIError.self) {
            try OneRepAPI.summary(diaryData: diary, healthData: Data(#"{}"#.utf8), day: day)
        }
    }

    @Test func dateForAPIUsesLocalDayAtMidnightBoundary() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-11-09T00:15:00Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(OneRepAPI.dayKey(instant, timeZone: zone) == "2026-11-08")
    }

    @Test func bearerCredentialCannotBeSentToAnotherOrigin() async throws {
        let url = try #require(URL(string: "https://another.example/v1/days"))
        await #expect(throws: OneRepAPIError.invalidResponse) {
            try await OneRepAPI().send(URLRequest(url: url), token: "fixture")
        }
    }
}
