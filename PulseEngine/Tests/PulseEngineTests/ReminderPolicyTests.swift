import Foundation
import Testing

@testable import PulseEngine

@Suite struct ReminderPolicyTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private var day: Date { Date(timeIntervalSince1970: 0) }
    @Test func dailyCheckInKeepsItsChosenWallTimeThroughClockChanges() {
        var prefs = ReminderPreferences()
        prefs.morningCheckIn = true
        prefs.morningMinute = 2 * 60 + 30
        prefs.quietHours = false
        #expect(prefs.morningDeliveryMinute == 150)
        prefs.quietHours = true
        #expect(prefs.morningDeliveryMinute == prefs.quietEnd)
        prefs.quietEnd = prefs.quietStart
        #expect(prefs.morningDeliveryMinute == nil)
    }

    @Test func quietHoursCrossMidnightAndHoldUntilMorning() {
        var prefs = ReminderPreferences()
        prefs.enabled = true
        let requests = [
            PlanningAlert(id: "a", date: day.addingTimeInterval(22 * 3600)),
            PlanningAlert(id: "b", date: day.addingTimeInterval(23 * 3600)),
        ]
        let scheduled = ReminderPolicy.schedule(requests, after: day, preferences: prefs, calendar: calendar)
        #expect(scheduled.map(\.date) == [day.addingTimeInterval(32 * 3600), day.addingTimeInterval(32 * 3600 + 900)])
        prefs.quietEnd = prefs.quietStart
        #expect(ReminderPolicy.schedule(requests, after: day, preferences: prefs, calendar: calendar).isEmpty)
    }
    @Test func offExpiredAndExcessAlertsStaySilent() {
        var prefs = ReminderPreferences()
        let requests = (0..<12).map { PlanningAlert(id: "\($0)", date: day.addingTimeInterval(40000 + Double($0))) }
        #expect(ReminderPolicy.schedule(requests, after: day, preferences: prefs, calendar: calendar).isEmpty)
        prefs.enabled = true
        let scheduled = ReminderPolicy.schedule(
            requests, after: day, preferences: prefs, occupied: [day.addingTimeInterval(39000)], calendar: calendar)
        #expect(scheduled.count == 5)
        #expect(
            ReminderPolicy.schedule(
                requests, after: day.addingTimeInterval(50000), preferences: prefs, calendar: calendar
            ).isEmpty)
    }
}
