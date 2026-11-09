import Foundation
import Testing
@testable import PulseEngine

struct FocusAssignmentTests {
    let calendar = Calendar(identifier: .gregorian)
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func rule(_ day: Int, _ start: Int, _ end: Int) -> WeeklyTimeBlock {
        let date = time(day, 0)
        var rule = WeeklyTimeBlock(kind: .focus, hours: TaskAvailability(weekdays: [calendar.component(.weekday, from: date)], startMinute: start, endMinute: end)!)
        rule.setSingleDate(date, calendar: calendar)
        return rule
    }

    @Test func personalInboxTaskCanUseOnlyAssignedWindowIncludingBeforeUsualDayStart() throws {
        let first = rule(10, 390, 405)
        let second = rule(10, 405, 430)
        var prefs = PlannerPreferences()
        prefs.timeBlocks = [first, second]
        var task = PlanTask("Return the keys", minutes: 45, category: .personal)
        task.inboxOnly = true
        let day = try #require(calendar.dateInterval(of: .day, for: time(10, 0)))
        let target = try #require(first.blocks(on: day, calendar: calendar).first)
        let options = Planner.weekPlacements(for: task.id, at: time(9, 9), tasks: [task], commitments: [], reports: [],
                                             dailyLimit: 120, breaks: false, preferences: prefs, calendar: calendar, focusTarget: target)
        let choice = try #require(options.first { $0.recommended })
        #expect(choice.start == time(10, 6, 30) && choice.minutes <= 15)
        task.moveOccurrence(to: choice.start)
        task.assignedFocusBlockID = first.id
        let actual = WeekOutlook.futureBlocks(on: day.start, tasks: [task], events: [], reports: [],
                                              limit: 120, breaks: false, preferences: prefs, startHour: 9, calendar: calendar)
        let result = try #require(actual.first { $0.kind == .task(task.id) })
        #expect(result.start == choice.start && result.end <= target.end)
        #expect(prefs.focusBoundary(for: task, at: time(10, 6, 35), calendar: calendar) == target.end)
        #expect(prefs.focusBoundary(for: task, at: time(10, 6, 46), calendar: calendar) == time(10, 6, 46))
        task.releaseTimePin()
        #expect(task.assignedFocusBlockID == nil && task.category == .personal)
    }

    @Test func distantAttachmentsStopBeforeBuildingTheReplay() throws {
        let start = time(9, 9)
        let distant = try #require(calendar.date(byAdding: .year, value: 500, to: start))
        var focus = rule(9, 600, 650)
        focus.setSingleDate(distant, calendar: calendar)
        var prefs = PlannerPreferences()
        prefs.timeBlocks = [focus]
        let day = try #require(calendar.dateInterval(of: .day, for: distant))
        let target = try #require(focus.blocks(on: day, calendar: calendar).first)
        let task = PlanTask("Later", minutes: 5)
        let choices = Planner.weekPlacements(for: task.id, at: start, tasks: [task], commitments: [], reports: [],
                                             dailyLimit: 60, preferences: prefs, calendar: calendar, focusTarget: target)
        #expect(choices.isEmpty)
    }

    @Test func narrowNonHourTargetFindsLegalStartAndPreservesPriorPinWhenCreatingRule() throws {
        let requested = rule(19, 631, 640)
        var prefs = PlannerPreferences()
        prefs.timeBlocks = [requested]
        var inbox = PlanTask("Water plants", minutes: 5, category: .recovery)
        inbox.inboxOnly = true
        let date = time(19, 0)
        let day = try #require(calendar.dateInterval(of: .day, for: date))
        let target = try #require(requested.blocks(on: day, calendar: calendar).first)
        let visit = Commitment("School", start: time(19, 10), end: time(19, 10, 33))
        func options(_ tasks: [PlanTask]) -> [TaskPlacement] {
            Planner.weekPlacements(for: inbox.id, at: time(9, 9), tasks: tasks, commitments: [visit], reports: [], dailyLimit: 120,
                                   breaks: false, preferences: prefs, calendar: calendar, focusTarget: target, priorPreferences: .init())
        }
        let choice = try #require(options([inbox]).first)
        #expect(choice.start == time(19, 10, 33))
        var pin = PlanTask("Call a friend", minutes: 5, category: .personal)
        pin.plannedStart = time(19, 10, 34)
        #expect(options([inbox, pin]).isEmpty)
        inbox.after = time(19, 11)
        #expect(options([inbox]).isEmpty)
    }
}
