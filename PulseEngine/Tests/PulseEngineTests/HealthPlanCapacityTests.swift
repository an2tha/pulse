import Foundation
import Testing
@testable import PulseEngine

@Suite struct HealthPlanCapacityTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func correctionReachesScheduleAndRespectsManualSetting() throws {
        let cal = Calendar.current
        let date = try #require(cal.date(bySettingHour: 10, minute: 5, second: 0, of: now))
        let correction = EnergyCorrection(date: date, score: 1)
        var options = PlannerPreferences()
        options.corrections = [correction]
        let task = PlanTask("Draft a chapter", minutes: 30)
        let plan = Planner.schedule(at: date, tasks: [task], commitments: [], reports: [], dailyLimit: 60, preferences: options)
        #expect(plan.first?.minutes == 3)
        #expect(options.capacity(at: date.addingTimeInterval(3600), reports: [], calendar: cal) == 5)
        var manual = PlanTuning(date: date)
        manual.manualCapacity = 7
        options.tuning = manual
        #expect(options.capacity(at: date, reports: [], calendar: cal) == 7)
    }

    @Test func forecastInformsTomorrowOnlyWhenEnabled() throws {
        let cal = Calendar.current
        let tomorrow = try #require(cal.date(byAdding: .day, value: 1, to: now))
        let reports = try (1...5).map { offset in
            CheckIn(date: try #require(cal.date(byAdding: .day, value: -offset, to: now)), energy: Double(offset + 2), clarity: 5, interest: 5)
        }
        var options = PlannerPreferences()
        let base = options.capacity(at: tomorrow, reports: reports, calendar: cal)
        options.energyTimeline = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: now, calendar: cal)
        options.energyAsOf = now
        let forecast = try #require(options.energyTimeline?.estimate(at: tomorrow))
        #expect(forecast.source == .forecast)
        #expect(options.capacity(at: tomorrow, reports: reports, calendar: cal) == forecast.score)
        let otherHour = tomorrow.addingTimeInterval(6 * 3600)
        #expect(options.energyTimeline?.estimate(at: otherHour) == nil)
        #expect(options.capacity(at: otherHour, reports: reports, calendar: cal) == forecast.score)
        options.energyTimeline = nil
        #expect(options.capacity(at: tomorrow, reports: reports, calendar: cal) == base)
    }
}

extension HealthPlanCapacityTests {
    @Test func preparedHistoryUsesOnlyReportsInsideTheQueriedLocalDayOrHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // Both 02:30 readings have the same clock label on the autumn change.
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let firstFold = day.addingTimeInterval(2.5 * 3600)
        let secondFold = firstFold.addingTimeInterval(3600)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        let reports = [secondFold, tomorrow.addingTimeInterval(3600), firstFold,
                       day.addingTimeInterval(-60), day.addingTimeInterval(-86_400 * 3)].map {
            CheckIn(date: $0, energy: 2, clarity: 4, interest: 3)
        }
        let timeline = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: tomorrow, calendar: calendar)
        let expected = try #require(EnergyExpectation(at: day, scope: .day, score: 9, calendar: calendar))
        let instants = [day, firstFold.addingTimeInterval(-1), firstFold, secondFold.addingTimeInterval(-1),
                        secondFold, tomorrow, tomorrow.addingTimeInterval(3600), tomorrow.addingTimeInterval(7200)]
        for edits in [[], [expected]] {
            var preferences = PlannerPreferences()
            preferences.energyTimeline = timeline
            preferences.expectations = edits
            let prepared = preferences.preparingHistory(reports, calendar: calendar)
            for time in instants {
                let base = Capacity.estimate(at: time, reports: reports, calendar: calendar)
                let reference: Double
                if let edit = EnergyExpectation.applicable(at: time, in: edits, calendar: calendar) {
                    let hour = try #require(calendar.dateInterval(of: .hour, for: time))
                    let observed = reports.contains { $0.date >= hour.start && $0.date <= time }
                    reference = observed ? base : edit.score
                } else if let modeled = timeline.estimate(at: time) {
                    let observed = reports.contains { $0.date <= time && calendar.isDate($0.date, inSameDayAs: time) }
                    reference = observed ? min(base, modeled.score) : modeled.score
                } else {
                    reference = base
                }
                #expect(preferences.capacity(at: time, reports: reports, calendar: calendar) == reference)
                #expect(prepared.capacity(at: time, reports: reports, calendar: calendar) == reference)
            }
        }
    }
}
