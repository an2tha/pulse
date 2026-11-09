import Foundation
import Testing
@testable import PulseEngine

struct WeeklyPracticeTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.firstWeekday = 2
        return cal
    }

    private func october(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func countsUniqueLocalDaysAcrossClockChangeAndWeekBoundary() throws {
        var practice = WeeklyPractice("Walk", targetDays: 1)
        let saturday = october(24, 22)
        let sunday = october(25, 1)
        let monday = october(26, 1)
        practice.log(at: saturday, calendar: calendar)
        practice.log(at: sunday, calendar: calendar)
        practice.log(at: october(25, 23), taskID: UUID(), calendar: calendar)
        practice.log(at: monday, calendar: calendar)
        #expect(practice.logs.count == 3)
        #expect(practice.progress(at: saturday, calendar: calendar) == 1)
        #expect(practice.progress(at: sunday, calendar: calendar) == 2)
        #expect(practice.progress(at: monday, calendar: calendar) == 1)
        var saved = try JSONDecoder().decode(WeeklyPractice.self, from: JSONEncoder().encode(practice))
        saved.removeLog(on: monday, calendar: calendar)
        #expect(saved.progress(at: monday, calendar: calendar) == 0)
        #expect(saved.progress(at: sunday, calendar: calendar) == 2)
    }

    @Test func flexibleSessionsUsePlannerConstraintsAndRespectWeeklyTarget() throws {
        var practice = WeeklyPractice("Draw", targetDays: 1, minutes: 10)
        let saturday = october(24, 10)
        let sunday = october(25, 10)
        let monday = october(26, 10)
        var session = try #require(practice.session(for: saturday, tasks: [], calendar: calendar))
        #expect(session.practiceID == practice.id)
        #expect(session.plannedStart == nil && session.repeated == nil)
        #expect(session.duplicate().practiceID == nil)
        #expect(practice.session(for: sunday, tasks: [session], calendar: calendar) == nil)
        let event = Commitment("Meeting", start: saturday, end: saturday.addingTimeInterval(1800))
        let blocks = Planner.schedule(at: saturday, tasks: [session], commitments: [event], reports: [],
                                      dailyLimit: 60, calendar: calendar)
        #expect(blocks.first { $0.kind == .task(session.id) }?.start == event.end)
        session.archived = true
        #expect(practice.session(for: saturday, tasks: [session], calendar: calendar) != nil)
        session.archived = false
        session.done = true
        practice.log(at: saturday, taskID: session.id, calendar: calendar)
        #expect(practice.session(for: sunday, tasks: [session], calendar: calendar) == nil)
        #expect(practice.session(for: monday, tasks: [session], calendar: calendar) != nil)
        practice.removeLog(on: saturday, calendar: calendar)
        #expect(practice.session(for: sunday, tasks: [session], calendar: calendar) != nil)
        #expect(session.done)
    }
}
