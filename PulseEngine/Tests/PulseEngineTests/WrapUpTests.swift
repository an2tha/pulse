import Foundation
import Testing
@testable import PulseEngine

@Suite struct WrapUpTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func plansOnlyBeforeWrapUpAndKeepsEveningAppointments() {
        let now = time(9, 17, 52)
        let task = PlanTask("Draft", minutes: 20)
        var pinned = PlanTask("Pinned", minutes: 10)
        pinned.plannedStart = time(9, 19)
        let event = Commitment("Dinner", start: time(9, 19), end: time(9, 20))
        let preferences = PlannerPreferences(wrapUpMinute: 18 * 60)
        let output = Planner.schedule(at: now, tasks: [task, pinned], commitments: [event],
                                      reports: [], dailyLimit: 60, preferences: preferences, calendar: calendar)
        #expect(output.first?.end == time(9, 18))
        #expect(output.last?.kind == .fixed(event.id) && output.last?.end == event.end)
        #expect(!output.contains { $0.kind == .task(pinned.id) })
        let week = WeekOutlook.project(at: now, today: output, tasks: [task, pinned], events: [event],
                                       reports: [], limit: 60, breaks: true, preferences: preferences, calendar: calendar)
        #expect(week[1].blocks.contains { $0.kind == .task(pinned.id) })
        let ordinary = Planner.schedule(at: time(9, 18), tasks: [pinned], commitments: [], reports: [],
                                        dailyLimit: 60, calendar: calendar)
        #expect(ordinary.first?.start == pinned.plannedStart)
    }

    @Test func bothCandidateSearchesAndSpareMomentsRespectTheLastMinute() {
        let prefs = PlannerPreferences(wrapUpMinute: 17 * 60 + 7)
        let now = time(9, 17)
        let small = PlanTask("Reply", minutes: 7)
        let long = PlanTask("Outline", minutes: 8)
        let event = Commitment("Dinner", start: time(9, 19), end: time(9, 20))
        let spare = Planner.spareMoments(at: now, minutes: 15, tasks: [small, long], commitments: [event],
                                         reports: [], dailyLimit: 60, preferences: prefs, calendar: calendar)
        #expect(spare.map(\.kind) == [.task(small.id)])
        #expect(Planner.spareMoments(at: time(9, 17, 7), minutes: 15, tasks: [small], commitments: [],
                                    reports: [], dailyLimit: 60, preferences: prefs, calendar: calendar).isEmpty)
        let today = Planner.placements(for: small.id, at: now, tasks: [small], commitments: [], reports: [],
                                       dailyLimit: 60, preferences: prefs, calendar: calendar)
        #expect(today.map(\.start) == [now])
        let week = Planner.weekPlacements(for: small.id, at: now, tasks: [small], commitments: [], reports: [],
                                          dailyLimit: 60, preferences: prefs, calendar: calendar)
        #expect(week.contains { $0.start == time(10, 17) })
        #expect(week.allSatisfy { slot in
            slot.start.addingTimeInterval(Double(slot.minutes) * 60) <= prefs.workEnd(on: slot.start, calendar: calendar)
        })
    }

    @Test func midnightAndClockChangesUseLocalCalendarDays() {
        let midnight = PlannerPreferences(wrapUpMinute: 0)
        #expect(midnight.workEnd(on: time(29, 0, month: 3), calendar: calendar) == time(30, 0, month: 3))
        #expect(midnight.workEnd(on: time(25, 8, month: 10), calendar: calendar) == time(26, 0, month: 10))
        let early = PlannerPreferences(wrapUpMinute: 2 * 60 + 30)
        #expect(early.workEnd(on: time(29, 0, month: 3), calendar: calendar) == time(29, 3, month: 3))
        let autumn = time(25, 0, month: 10)
        #expect(early.workEnd(on: autumn, calendar: calendar) == autumn.addingTimeInterval(2.5 * 3600))
    }
}
