import Foundation
import Testing
@testable import PulseEngine

@Suite struct EnergyExpectationTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private func date(_ day: Int, _ hour: Int, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func dayAndHourEditsAgreeAcrossChartAndSchedulingWithoutHealth() throws {
        let now = date(9, 8), tomorrow = date(10, 0), goodHour = date(10, 15)
        let edits = [
            try #require(EnergyExpectation(at: tomorrow, scope: .day, score: 3, calendar: cal)),
            try #require(EnergyExpectation(at: goodHour, scope: .hour, score: 9, calendar: cal)),
        ]
        let chart = EnergyTimeline(signals: [], checkIns: [], corrections: [], now: now, calendar: cal, expectations: edits)
        #expect(chart.daily(on: tomorrow)?.source == .expected && chart.daily(on: tomorrow)?.score == 3)
        #expect(chart.hours(on: tomorrow).filter { $0.score == 9 }.map(\.date) == [goodHour])
        #expect(chart.daily(on: date(11, 0)) == nil)
        var task = PlanTask("Compose", minutes: 8)
        task.energyOverride = 9
        task.after = tomorrow
        var prefs = PlannerPreferences()
        prefs.expectations = edits
        let options = Planner.weekPlacements(for: task.id, at: now, tasks: [task], commitments: [], reports: [],
                                             dailyLimit: 20, preferences: prefs, calendar: cal, forecast: chart)
        let best = try #require(options.first { $0.recommended })
        #expect(best.start == goodHour && best.energyBasis == .expected && best.rankingCapacity == 9)
        let refreshed = EnergyTimeline(signals: [], checkIns: [], corrections: [], now: now, calendar: cal)
        #expect(refreshed.estimate(at: goodHour) == nil)
    }

    @Test func elapsedExpectationsNeverBecomeObservationsOrTrainingData() throws {
        let t = date(10, 10), past = date(9, 10)
        let edits = [try #require(EnergyExpectation(at: past, scope: .day, score: 8, calendar: cal)),
                     try #require(EnergyExpectation(at: t, scope: .hour, score: 8, calendar: cal))]
        let report = CheckIn(date: t, energy: 2, clarity: 4, interest: 4)
        let chart = EnergyTimeline(signals: [], checkIns: [report], corrections: [], now: t, calendar: cal, expectations: edits)
        #expect(chart.daily(on: past) == nil && chart.hours(on: past).isEmpty)
        #expect(chart.estimate(at: t)?.score == 2 && chart.estimate(at: t)?.source == .reported)
        #expect(chart.daily(on: date(11, 0)) == nil)
        var prefs = PlannerPreferences()
        prefs.expectations = edits
        #expect(prefs.capacity(at: t, reports: [report], calendar: cal) <= 2)
    }

    @Test func oneKnownDifficultDayDoesNotAttractAllDemandingWork() throws {
        let now = date(9, 9)
        let low = try #require(EnergyExpectation(at: date(10, 12), scope: .day, score: 2, calendar: cal))
        var task = PlanTask("Make the difficult call", minutes: 4)
        task.energyOverride = 9
        let chart = EnergyTimeline(signals: [], checkIns: [], corrections: [], now: now, calendar: cal, expectations: [low])
        var prefs = PlannerPreferences()
        prefs.expectations = [low]
        let options = Planner.weekPlacements(for: task.id, at: now, tasks: [task], commitments: [], reports: [],
                                             dailyLimit: 15, preferences: prefs, calendar: cal, forecast: chart)
        let best = try #require(options.first { $0.recommended })
        #expect(cal.isDate(best.start, inSameDayAs: now) && best.energyBasis == .capacity)
        #expect(options.contains { low.start <= $0.start && $0.start < low.end })
    }

    @Test func aZeroHourOpensAgainAndFallBackSeparatesBothClockHours() throws {
        let start = date(10, 9)
        var prefs = PlannerPreferences()
        prefs.expectations = [try #require(EnergyExpectation(at: start, scope: .hour, score: 0, calendar: cal))]
        let task = PlanTask("Open notes", minutes: 5)
        let plan = Planner.schedule(at: start, tasks: [task], commitments: [], reports: [], dailyLimit: 10,
                                    preferences: prefs, calendar: cal)
        #expect(plan.first?.start == date(10, 10))
        let first = date(25, 2, month: 10)
        let second = first.addingTimeInterval(3600)
        let repeated = try #require(EnergyExpectation(at: second, scope: .hour, score: 8, calendar: cal))
        #expect(cal.component(.hour, from: first) == cal.component(.hour, from: second))
        #expect(EnergyExpectation.applicable(at: first, in: [repeated]) == nil)
        #expect(EnergyExpectation.applicable(at: second, in: [repeated])?.score == 8)
        let day = try #require(EnergyExpectation(at: first, scope: .day, score: 4, calendar: cal))
        #expect(day.end.timeIntervalSince(day.start) == 25 * 3600)
    }

    @Test func blocksAndShortSessionsCannotRunIntoAnExplicitZeroWindow() throws {
        let cal = self.cal
        let nine = date(10, 9)
        let before = nine.addingTimeInterval(-5 * 60)
        let item = PlanTask("Check the essay", minutes: 12)
        var prefs = PlannerPreferences()
        prefs.expectations = [try #require(EnergyExpectation(at: nine, scope: .hour, score: 0, calendar: cal))]
        let scheduled = Planner.schedule(at: before, tasks: [item], commitments: [], reports: [], dailyLimit: 30,
                                          preferences: prefs, calendar: cal)
        #expect(scheduled.first?.end == nine)
        #expect(Planner.spareMoments(at: before, minutes: 15, tasks: [item], commitments: [], reports: [],
                                     dailyLimit: 30, preferences: prefs, calendar: cal).isEmpty)
    }

    @Test func travelKeepsWholeDaysLocalAndTimedPredictionsAtTheirChosenInstant() throws {
        let berlin = cal
        var west = berlin
        west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let whole = try #require(EnergyExpectation(at: date(11, 12), scope: .day, score: 4, calendar: berlin))
        let hour = try #require(EnergyExpectation(at: date(11, 17), scope: .hour, score: 7, calendar: berlin))
        let localDay = try #require(west.date(from: DateComponents(year: 2026, month: 11, day: 11)))
        let chart = EnergyTimeline(signals: [], checkIns: [], corrections: [], now: date(9, 8), calendar: west,
                                   expectations: [whole, hour])
        #expect(chart.daily(on: localDay)?.score == 4)
        #expect(chart.estimate(at: localDay.addingTimeInterval(-1)) == nil)
        #expect(chart.estimate(at: localDay.addingTimeInterval(22 * 3600))?.score == 4)
        #expect(chart.estimate(at: hour.start)?.score == 7)
    }
}
