import Foundation
import Testing
@testable import PulseEngine

struct WeekCarryoverTests {
    @Test func unfinishedEarlierPinCannotTakeTomorrowsEarlyAppointment() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func time(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let monday = time(9, 9)
        var long = PlanTask("Review manuscript", minutes: 60)
        long.plannedStart = monday
        var early = PlanTask("Call London", minutes: 5)
        early.plannedStart = time(10, 6)
        let tasks = [long, early]
        let today = Planner.schedule(at: monday, tasks: tasks, commitments: [], reports: [], dailyLimit: 30, calendar: calendar)
        let days = WeekOutlook.project(at: monday, today: today, tasks: tasks, events: [], reports: [], limit: 30,
                                       breaks: false, preferences: .init(), startHour: 9, calendar: calendar)
        let call = try #require(days[1].blocks.first { $0.kind == .task(early.id) })
        let continued = try #require(days[1].blocks.first { $0.kind == .task(long.id) })
        #expect(call.start == time(10, 6))
        #expect(continued.start == time(10, 9))
    }

    @Test func deadlineScoreUsesTheEntireTaskAcrossSeveralDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func time(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let now = time(9, 9)
        let reports = (1...27).map { offset -> CheckIn in
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            let score = calendar.component(.weekday, from: date) == 3 ? 9.0 : 5.0
            return CheckIn(date: date, energy: score, clarity: score, interest: score)
        }
        let forecast = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: now, calendar: calendar)
        var essay = PlanTask("Finish essay", minutes: 25)
        essay.due = time(10, 18)
        essay.energyOverride = 9
        let prefs = PlannerPreferences(wrapUpMinute: 18 * 60)
        let slots = Planner.weekPlacements(for: essay.id, at: now, tasks: [essay], commitments: [], reports: reports,
                                           dailyLimit: 15, preferences: prefs, calendar: calendar, forecast: forecast)
        let best = try #require(slots.first { $0.recommended })
        let tuesday = try #require(slots.first { $0.recommendedForDay && calendar.isDate($0.start, inSameDayAs: time(10, 9)) })
        #expect(calendar.isDate(best.start, inSameDayAs: now))
        #expect(best.rankingCapacity < tuesday.rankingCapacity)
        #expect(best.projectedFinish == time(10, 9).addingTimeInterval(600))
        #expect(tuesday.projectedFinish == time(11, 9).addingTimeInterval(600))
        #expect(slots.last?.projectedFinish == nil)
        for slot in [best, tuesday] {
            var pinned = essay
            pinned.moveOccurrence(to: slot.start, originalDay: slot.originalStart, calendar: calendar)
            let today = Planner.schedule(at: now, tasks: [pinned], commitments: [], reports: reports, dailyLimit: 15,
                                         preferences: prefs, calendar: calendar)
            let week = WeekOutlook.project(at: now, today: today, tasks: [pinned], events: [], reports: reports,
                                           limit: 15, breaks: true, preferences: prefs, calendar: calendar)
            let pieces = week.flatMap(\.blocks).filter { $0.kind == .task(essay.id) }
            #expect(pieces.reduce(0) { $0 + $1.minutes } == essay.minutes)
            #expect(pieces.last?.end == slot.projectedFinish)
        }
    }

    @Test func aBreakCannotDelayThePinnedTaskItsPrerequisiteJustUnlocked() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9))!
        let prep = PlanTask("Attach the file", minutes: 5)
        var call = PlanTask("Review the file together", minutes: 10)
        call.dependency = prep.id
        call.plannedStart = now.addingTimeInterval(300)
        let plan = Planner.schedule(at: now, tasks: [prep, call], commitments: [], reports: [], dailyLimit: 20, calendar: calendar)
        #expect(plan.first { $0.kind == .task(call.id) }?.start == call.plannedStart)
    }
}
