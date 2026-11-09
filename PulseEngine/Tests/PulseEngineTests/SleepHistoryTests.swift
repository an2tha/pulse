import Foundation
import Testing
@testable import PulseEngine

struct SleepHistoryTests {
    let calendar = Calendar(identifier: .gregorian)
    @Test func learnedTargetAndRecoveryUseRecordedNights() throws {
        let wake = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 7)))
        let nights = try (0..<14).map { offset in
            let end = try #require(calendar.date(byAdding: .day, value: offset - 13, to: wake))
            let duration = offset == 12 ? 6.0 : 9.0
            return DateInterval(start: end.addingTimeInterval(-duration * 3600), end: end)
        }
        let records = SleepNight.collect(nights, calendar: calendar)
        let learned = SleepHistory(nights: records, at: wake, calendar: calendar)
        #expect(learned.need == 9)
        #expect(learned.debt == 3)
        let adjusted = SleepHistory(nights: records, at: wake, target: 8, calendar: calendar)
        #expect(adjusted.debt == 1)
        let timeline = EnergyTimeline(signals: [], checkIns: [], corrections: [], now: wake,
                                      calendar: calendar, sleepNights: records, sleepTarget: 8)
        #expect(timeline.estimate(at: wake)?.score == adjusted.energy)
        #expect(timeline.estimate(at: wake)?.sleepBased == true)
        let evening = try #require(timeline.estimate(at: wake.addingTimeInterval(14 * 3600)))
        #expect(evening.sleepBased)
        #expect(evening.score < (adjusted.energy ?? 0))
        #expect(timeline.estimate(at: wake.addingTimeInterval(24 * 3600)) == nil)
    }

    @Test func mergesOvernightStagesAndDevices() throws {
        let wake = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 7)))
        let nights = SleepNight.collect([
            DateInterval(start: wake.addingTimeInterval(-8 * 3600), end: wake.addingTimeInterval(-4 * 3600)),
            DateInterval(start: wake.addingTimeInterval(-7 * 3600), end: wake.addingTimeInterval(-4 * 3600)),
            DateInterval(start: wake.addingTimeInterval(-3 * 3600), end: wake)
        ], calendar: calendar)
        #expect(nights.count == 1)
        #expect(nights.first?.hours == 7)
        let history = SleepHistory(nights: nights, at: wake, target: 8, calendar: calendar)
        #expect(history.debt == 1)
        #expect(history.energy != nil)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: wake))
        let stale = SleepHistory(nights: nights, at: tomorrow, target: 8, calendar: calendar)
        #expect(stale.debt == 1)
        #expect(stale.energy == nil)
        #expect(SleepHistory(nights: nights, at: wake.addingTimeInterval(-1)).debt == nil)
    }
}
