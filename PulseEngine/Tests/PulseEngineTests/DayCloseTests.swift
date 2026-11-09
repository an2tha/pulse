import Foundation
import Testing

@testable import PulseEngine

@Suite struct DayCloseTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }

    @Test func filtersTheDayAndRevalidatesAtConfirmation() throws {
        let now = date(28, 20)
        let day = try #require(calendar.dateInterval(of: .day, for: now))
        let planned = PlanTask("Selected", minutes: 12)
        var overdue = PlanTask("Overdue", minutes: 9)
        overdue.due = date(20)
        var active = PlanTask("Active", minutes: 8)
        active.after = day.start
        var archived = planned.duplicate()
        archived.archived = true
        var future = planned.duplicate()
        future.after = day.end
        let unplanned = planned.duplicate()
        var tasks = [planned, overdue, active, archived, future, unplanned]
        let plannedIDs = Set([planned.id, archived.id, active.id, future.id])
        let offered = DayClose.candidates(in: tasks, planned: plannedIDs, active: active.id, day: day)
        #expect(Set(offered.map(\.id)) == [planned.id, overdue.id])
        tasks[0].done = true
        #expect(
            DayClose.move(
                Set(tasks.map(\.id)), in: &tasks, planned: plannedIDs, active: active.id,
                reviewedDay: now, now: now, calendar: calendar) == 1)
        #expect(tasks[1].after == day.end && tasks[1].due == overdue.due)
        #expect(tasks[0].after == nil && tasks[2] == active && tasks[3] == archived && tasks[5] == unplanned)
        let firstWrite = tasks
        #expect(
            DayClose.move(
                [overdue.id], in: &tasks, planned: plannedIDs, active: nil,
                reviewedDay: now, now: now, calendar: calendar) == 0)
        #expect(
            DayClose.move(
                [overdue.id], in: &tasks, planned: plannedIDs, active: nil,
                reviewedDay: now, now: date(29, 1), calendar: calendar) == 0)
        #expect(tasks == firstWrite)
    }

    @Test func repeatedCloseoutKeepsWeeklyCadenceAcrossDST() throws {
        var task = PlanTask("Saturday review", minutes: 20)
        task.repeated = .weekly
        task.plannedStart = date(28, 9)
        task.reminder = date(28, 8)
        task.due = date(28, 12)
        task.project = "Garden"
        task.steps = [TaskStep("List seeds"), TaskStep("Order seeds")]
        task.steps?[0].done = true
        task.recordFocus(seconds: 90, completed: false)
        var tasks = [task]
        for d in [28, 29] {
            #expect(
                DayClose.move(
                    [task.id], in: &tasks, planned: [task.id], active: nil,
                    reviewedDay: date(d), now: date(d, 20), calendar: calendar) == 1)
            #expect(tasks[0].plannedStart == date(d + 1, 9))
            #expect(tasks[0].reminder == date(d + 1, 8))
            #expect(tasks[0].due == task.due && tasks[0].remainingSeconds == task.remainingSeconds)
            #expect(tasks[0].project == task.project && tasks[0].steps == task.steps)
        }
        let decoded = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(tasks[0]))
        #expect(decoded == tasks[0])
        tasks[0].done = true
        TaskRoutines.advance(&tasks, at: date(30, 13), calendar: calendar)
        let next = try #require(tasks.last)
        let nextSaturday = try #require(calendar.date(byAdding: .day, value: 7, to: date(28, 9)))
        #expect(tasks.count == 2 && next.plannedStart == nextSaturday)
        #expect(next.reminder == nextSaturday.addingTimeInterval(-3600))
        #expect(next.movedRoutineTimes == nil)
    }

    @Test func leavesFutureReminderAndHonorsSubsequentPinEdit() throws {
        var task = PlanTask("Weekly letter", minutes: 10)
        task.plannedStart = date(8, 10)
        task.reminder = date(10, 14)
        task.repeated = .weekly
        var tasks = [task]
        #expect(
            DayClose.move(
                [task.id], in: &tasks, planned: [], active: nil,
                reviewedDay: date(8), now: date(8, 12), calendar: calendar) == 1)
        #expect(tasks[0].reminder == task.reminder)
        tasks[0].plannedStart = date(11, 13)
        tasks[0].done = true
        TaskRoutines.advance(&tasks, at: date(11, 16), calendar: calendar)
        #expect(tasks.last?.plannedStart == date(18, 13))
    }
}
