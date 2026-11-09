import Foundation
import Testing
@testable import PulseEngine

struct RecurringCommitmentProjectionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func time(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func weeklyWeekendCommitmentBlocksSundayAndItsBuffer() throws {
        let event = Commitment("Family weekend", start: time(10, 16, 19), end: time(10, 18, 14), recurrence: .weekly)
        let sunday = time(10, 25, 0)
        #expect(event.intervals(on: sunday, calendar: calendar) == [DateInterval(start: sunday, end: time(10, 25, 14))])
        let task = PlanTask("Food shopping", minutes: 8)
        let now = time(10, 23, 17)
        let prefs = PlannerPreferences(bufferMinutes: 10, wrapUpMinute: 18 * 60)
        let options = Planner.weekPlacements(for: task.id, at: now, tasks: [task], commitments: [event],
                                             reports: [], dailyLimit: 30, preferences: prefs, calendar: calendar)
        let sundayOptions = options.filter { calendar.isDate($0.start, inSameDayAs: sunday) }
        #expect(sundayOptions.first?.start == time(10, 25, 14).addingTimeInterval(600))
    }

    @Test func overnightRepeatsEndAtTheirLocalClockTimeAcrossDST() {
        let spring = Commitment("Shift", start: time(3, 26, 22), end: time(3, 27, 6), recurrence: .daily)
        let springDay = time(3, 29, 0)
        #expect(spring.intervals(on: springDay, calendar: calendar).first == DateInterval(start: springDay, end: time(3, 29, 6)))
        let fall = Commitment("Shift", start: time(10, 22, 22), end: time(10, 23, 6), recurrence: .daily)
        let fallDay = time(10, 25, 0)
        #expect(fall.intervals(on: fallDay, calendar: calendar).first == DateInterval(start: fallDay, end: time(10, 25, 6)))
    }
}
