import Foundation
import Testing
@testable import PulseEngine

struct SelectedWeekdayRoutineTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }
    private func t(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func routine() -> PlanTask {
        var task = PlanTask("Practice piano", minutes: 5)
        task.repeated = .daily
        task.repeatDays = [2, 4, 6]
        return task
    }
    private func week(_ tasks: [PlanTask], now: Date) -> [OutlookDay] {
        let today = Planner.schedule(at: now, tasks: tasks, commitments: [], reports: [], dailyLimit: 45,
                                     breaks: false, calendar: calendar)
        return WeekOutlook.project(at: now, today: today, tasks: tasks, events: [], reports: [], limit: 45,
                                   breaks: false, preferences: .init(), startHour: 9, calendar: calendar)
    }

    @Test func nullableFieldKeepsOlderTaskDataAndOnlyAcceptsValidDailyWeekdays() throws {
        let old = PlanTask("Legacy", minutes: 8)
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        data.removeValue(forKey: "repeatDays")
        let loaded = try JSONDecoder().decode(PlanTask.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(loaded.repeatDays == nil && loaded.hasValidRepeatDays)
        var picked = routine()
        #expect(try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(picked)).repeatDays == [2,4,6])
        #expect(picked.duplicate().repeatDays == [2,4,6])
        picked.repeatDays = []
        #expect(!picked.hasValidRepeatDays && !picked.permitsRoutineWork(at: t(9), calendar: calendar))
        picked.repeatDays = [2,8]
        #expect(!picked.hasValidRepeatDays && picked.firstRepeatDay(onOrAfter: t(9), calendar: calendar) == nil)
        picked.repeated = .weekly
        picked.repeatDays = [2]
        #expect(!picked.hasValidRepeatDays)
    }

    @Test func alignsNewClockAndPreviousEveningReminderAcrossTheAutumnChange() throws {
        var task = routine()
        task.repeatDays = [2]
        task.plannedStart = t(23,9,15,month:10)
        task.after = t(23,8,30,month:10)
        task.reminder = t(22,19,month:10)
        task.due = t(30,12,month:10)
        task.availability = TaskAvailability(weekdays:[2,3,4,5,6],startMinute:8*60,endMinute:18*60)
        task.alignFirstRepeatDay(at: t(23,8,month:10), calendar: calendar)
        #expect(task.plannedStart == t(26,9,15,month:10) && task.after == t(26,8,30,month:10))
        #expect(task.reminder == t(25,19,month:10) && task.due == t(30,12,month:10))
        task.done = true
        task.completedAt = t(26,10,month:10)
        var tasks = [task]
        TaskRoutines.advance(&tasks, at: t(26,10,month:10), calendar: calendar)
        let next = try #require(tasks.last)
        #expect(next.plannedStart == t(2,9,15) && next.after == t(2,8,30))
        #expect(next.reminder == t(1,19) && next.repeatDays == [2] && next.availability == task.availability)
    }

    @Test func theConcreteWeekContainsOnlyChosenDaysAndNoMissedBacklog() throws {
        let monday = t(9,9)
        let source = routine()
        let days = week([source], now: monday)
        let running = days.filter { $0.blocks.contains(where: { if case .task = $0.kind { return true }; return false }) }
        #expect(running.map(\.date) == [t(9),t(11),t(13)])
        let wednesday = try #require(running[1].projectedTasks.first)
        let friday = try #require(running[2].projectedTasks.first)
        #expect(wednesday.occurrence(in: calendar)?.nominalDay == 20261111)
        #expect(friday.occurrence(in: calendar)?.nominalDay == 20261113)
        let tue = t(10,9)
        #expect(Planner.spareMoments(at: tue, minutes: 15, tasks: [source], commitments: [], reports: [],
                                     dailyLimit: 45, calendar: calendar).isEmpty)
        var old = source
        old.plannedStart = monday
        old.done = true
        old.completedAt = t(19,14)
        var saved = [old]
        TaskRoutines.advance(&saved, at: t(19,14), calendar: calendar)
        TaskRoutines.advance(&saved, at: t(19,14), calendar: calendar)
        #expect(saved.count == 2 && saved.last?.plannedStart == t(20,9))
    }

    @Test func aligningAnUndatedFirstOccurrenceKeepsItsAuthoredReminder() {
        var task = routine()
        task.reminder = t(10,19)
        task.alignFirstRepeatDay(at: t(10,12), calendar: calendar)
        #expect(task.after == t(11) && task.reminder == t(10,19))
    }

    @Test func movingOneOccurrenceOffDayPreservesTheFollowingDayAndTheHoursRule() throws {
        var root = routine()
        root.plannedStart = t(9,9)
        root.availability = TaskAvailability(weekdays: [2,3,4,6], startMinute: 9*60, endMinute: 12*60)
        let source = week([root], now: t(9,9))
        let wed = try #require(source[2].projectedTasks.first)
        let key = try #require(wed.occurrence(in: calendar))
        let choices = Planner.weekPlacements(for: wed.id, at: t(9,9), tasks: [root], commitments: [],
                                             reports: [], dailyLimit: 45, breaks: false, calendar: calendar, sourceDay: t(11))
        let tue = try #require(choices.first { $0.start == t(10,10) })
        #expect(choices.allSatisfy { $0.start < t(13) && !calendar.isDate($0.start, inSameDayAs: t(12)) })
        root.setException(.init(occurrence: key, start: tue.start), for: key, calendar: calendar)
        let moved = week([root], now: t(9,9))
        #expect(moved[1].blocks.contains { $0.kind == .task(wed.id) && $0.start == tue.start })
        #expect(moved[4].projectedTasks.first?.plannedStart == t(13,9))
        root.done = true
        root.completedAt = t(9,9,5)
        var real = [root]
        TaskRoutines.advance(&real, at: t(9,9,5), calendar: calendar)
        #expect(real[1].id == wed.id && real[1].plannedStart == tue.start && real[1].repeatDays == [2,4,6])
        real[1].done = true
        TaskRoutines.advance(&real, at: t(10,10,5), calendar: calendar)
        #expect(real.count == 3 && real.last?.plannedStart == t(13,9))
    }

    @Test func liveMoveAndUndatedDayCloseCanUseTheInterveningDay() throws {
        var item = routine()
        let options = Planner.weekPlacements(for: item.id, at: t(9,9), tasks: [item], commitments: [],
                                             reports: [], dailyLimit: 45, breaks: false, calendar: calendar, sourceDay: t(9))
        #expect(options.contains { $0.start == t(10,11) })
        #expect(options.allSatisfy { $0.start < t(11) })
        var items = [item]
        #expect(DayClose.move([item.id], in: &items, planned: [item.id], active: nil,
                              reviewedDay: t(9), now: t(9,20), calendar: calendar) == 1)
        item = items[0]
        #expect(item.plannedStart == nil && item.permitsRoutineWork(at: t(10,9), calendar: calendar))
        #expect(week([item], now: t(10,9))[0].blocks.contains { $0.kind == .task(item.id) })
        #expect(!item.permitsRoutineWork(at: t(12,9), calendar: calendar))
    }

    @Test func explicitCadenceEditPrunesOnlyInvalidMoves() {
        var owner = routine()
        owner.routineAnchor = t(9,11)
        func move(_ day: Int, _ start: Date) -> RoutineException {
            RoutineException(occurrence: RoutineOccurrence(seriesID: owner.id, rule: .daily, day: t(day), calendar: calendar),
                             start: start)
        }
        let wed = move(11,t(12,11))
        let fri = move(13,t(14,11))
        let nextMon = move(16,t(16,15))
        owner.routineExceptions = [wed,fri,nextMon]
        owner.repeatDays = [2,4,5]
        owner.pruneRepeatExceptions(calendar: calendar)
        // Wednesday's Thursday move crosses the newly added Thursday occurrence; Friday was removed.
        #expect(owner.routineExceptions == [nextMon])
        #expect(!owner.owns(fri.occurrence) && owner.owns(nextMon.occurrence))
    }

    @Test func closingAPinnedMondayKeepsWednesdaysReleaseAndPin() throws {
        var root = routine()
        root.plannedStart = t(9,13)
        root.after = t(9,9)
        var tasks = [root]
        #expect(DayClose.move([root.id], in: &tasks, planned: [root.id], active: nil,
                              reviewedDay: t(9), now: t(9,20), calendar: calendar) == 1)
        #expect(tasks[0].plannedStart == t(10,13) && tasks[0].after == t(10))
        tasks[0].done = true
        tasks[0].completedAt = t(10,14)
        TaskRoutines.advance(&tasks, at: t(10,14), calendar: calendar)
        let next = try #require(tasks.first { !$0.done })
        #expect(next.plannedStart == t(11,13) && next.after == t(11,9))
    }

    @Test func dependentOccurrencesRebindToTheCorrectChosenDay() throws {
        var first = routine()
        first.plannedStart = t(9,9)
        var second = routine()
        second.plannedStart = t(9,10)
        second.dependency = first.id
        first.done = true; second.done = true
        first.completedAt = t(9,10); second.completedAt = t(9,11)
        var tasks = [second, first]
        TaskRoutines.advance(&tasks, at: t(9,11), calendar: calendar)
        let newFirst = try #require(tasks.first { !$0.done && $0.seriesID == first.id })
        let newSecond = try #require(tasks.first { !$0.done && $0.seriesID == second.id })
        #expect(newFirst.plannedStart == t(11,9) && newSecond.plannedStart == t(11,10))
        #expect(newSecond.dependency == newFirst.id)
    }
}
