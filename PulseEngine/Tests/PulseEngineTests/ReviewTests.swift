import Foundation
import Testing

@testable import PulseEngine

@Suite struct ReviewTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func report(day: Int, energy: Double, sleep: Double? = nil) -> CheckIn {
        CheckIn(
            date: Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200),
            energy: energy, clarity: 5, interest: 5, sleep: sleep)
    }

    @Test func sleepRequiresDistinctDaysWithBothMeasures() throws {
        let checks = (1...5).map { report(day: $0, energy: Double($0), sleep: Double(9 - $0)) }
        let sameDay = Array(repeating: checks[0], count: 10)
        #expect(ReviewStats.sleepAssociation(sameDay, calendar: calendar) == nil)
        let result = try #require(
            ReviewStats.sleepAssociation(checks + [report(day: 7, energy: 8)], calendar: calendar))
        #expect(result.days == 5)
        #expect(abs(result.correlation + 1) < 0.00001)
        #expect(
            ReviewStats.sleepAssociation(
                (1...7).map { report(day: $0, energy: 5, sleep: 6) }, calendar: calendar) == nil)
    }

    @Test func longerTermChangeWeightsObservedDaysEqually() {
        let earlier = (1...5).map { report(day: $0, energy: 4) }
        let later = (16...20).map { report(day: $0, energy: 7) }
        let now = report(day: 28, energy: 5).date
        let reports =
            earlier + later + [
                report(day: 21, energy: 10), report(day: 21, energy: 4), report(day: 29, energy: 0),
            ]
        #expect(ReviewStats.longerChange(reports, at: now, calendar: calendar) == 3)
        #expect(
            ReviewStats.longerChange(Array(earlier.prefix(4)) + later, at: now, calendar: calendar) == nil
        )
    }

    @Test func firstSavedPlanContainsOnlyWork() throws {
        let date = report(day: 20, energy: 3).date
        let event = Commitment("Meeting", start: date, end: date.addingTimeInterval(1200))
        let task = PlanTask("Read", minutes: 8)
        let blocks = Planner.schedule(
            at: date, tasks: [task], commitments: [event], reports: [], dailyLimit: 8, calendar: calendar)
        let record = try #require(DayPlanRecord(date: date, blocks: blocks, calendar: calendar))
        #expect(record.tasks == [task.id])
        #expect(record.minutes == 8)
        #expect(DayPlanRecord(date: date, blocks: [], calendar: calendar) == nil)
    }
}
