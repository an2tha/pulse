import Foundation
import Testing
@testable import PulseEngine

struct ForecastHistoryTests {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test func earlierForecastStaysFixedAndUsesOnlyTheCompletedDaysOwnReports() throws {
        let cal = berlin
        func date(_ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let prior = [20, 21, 22, 23].map { CheckIn(date: date($0, 10), energy: 4, clarity: 5, interest: 5) }
        let expected = try #require(EnergyExpectation(at: date(25, 9), scope: .day, score: 9, calendar: cal))
        let timeline = EnergyTimeline(signals: [], checkIns: prior, corrections: [], now: date(24, 13), calendar: cal, expectations: [expected])
        let forecast = try #require(DayAheadForecast(from: timeline, calendar: cal))
        #expect(forecast.madeAt == date(24, 13) && forecast.score == 4 && forecast.supportDays == 4)
        #expect(forecast.end.timeIntervalSince(forecast.day) == 25 * 3600 && forecast.isValid)
        let actual = prior + [CheckIn(date: date(25, 10), energy: 7, clarity: 6, interest: 5)]
        let inProgress = ForecastHistory.compare([forecast], reports: actual, corrections: [], now: date(25, 17), calendar: cal)
        #expect(inProgress.first?.observed == nil)
        var traveled = cal
        traveled.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sameCivilDay = try #require(traveled.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        #expect(forecast.isForDay(sameCivilDay, calendar: traveled))
        let finished = ForecastHistory.compare([forecast], reports: actual, corrections: [], now: date(26, 1), calendar: traveled)
        #expect(finished.first?.observed == 7 && finished.first?.forecast.score == 4)
        #expect(ForecastHistory.compare([forecast], reports: prior, corrections: [], now: date(26, 1)).first?.observed == nil)
    }

    @Test func emptyHistoryDoesNotInventPastForecasts() {
        let timeline = EnergyTimeline(signals: [], checkIns: [], corrections: [])
        #expect(DayAheadForecast(from: timeline) == nil)
    }
}
