import Foundation
import Testing
@testable import PulseEngine

struct TaskAvailabilityTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func rule(_ weekdays: Set<Int>, _ start: Int, _ end: Int) -> TaskAvailability {
        TaskAvailability(weekdays: weekdays, startMinute: start, endMinute: end)!
    }

    @Test func codingRejectsInvalidWindowsAndKeepsTheRuleInNewRoutineOccurrences() throws {
        #expect(TaskAvailability(weekdays: [], startMinute: 0, endMinute: 0) == nil)
        #expect(TaskAvailability(weekdays: [0, 2], startMinute: 0, endMinute: 1) == nil)
        #expect(TaskAvailability(weekdays: [1], startMinute: -1, endMinute: 1) == nil)
        #expect(TaskAvailability(weekdays: [1], startMinute: 0, endMinute: 1440) == nil)
        let invalid = Data(#"{"weekdays":[8],"startMinute":0,"endMinute":0}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TaskAvailability.self, from: invalid) }
        var task = PlanTask("Visit library", minutes: 12)
        let legacy = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(PlanTask.self, from: legacy).availability == nil)
        task.availability = rule([2, 5], 540, 690)
        task.repeated = .weekly
        task.routineAnchor = time(9, 10)
        task.completedAt = time(9, 11)
        task.done = true
        var tasks = [task]
        TaskRoutines.advance(&tasks, at: time(9, 11), calendar: calendar)
        #expect(tasks.count == 2 && tasks[1].availability == task.availability)
        #expect(task.duplicate().availability == task.availability)
        #expect(try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(task)) == task)
    }

    @Test func overnightAndFullLocalDaysUseTheOpeningWeekdayAndExclusiveEnd() {
        let overnight = rule([2], 22 * 60, 2 * 60)
        let monday = DateInterval(start: time(9, 22), end: time(10, 2))
        #expect(overnight.interval(containing: time(10, 1, 59), calendar: calendar) == monday)
        #expect(overnight.interval(containing: time(9, 22), calendar: calendar) == monday)
        #expect(overnight.interval(containing: time(10, 2), calendar: calendar) == nil)
        #expect(overnight.interval(containing: time(10, 22), calendar: calendar) == nil)
        let consecutive = rule([2, 3], 10 * 60, 10 * 60)
        #expect(consecutive.interval(containing: time(10, 10), calendar: calendar) ==
                DateInterval(start: time(9, 10), end: time(11, 10)))
        #expect(consecutive.interval(containing: time(9, 9, 59), calendar: calendar) == nil)
        let sundayNight = rule([1], 23 * 60, 15)
        #expect(sundayNight.interval(containing: time(9, 0), calendar: calendar)?.end == time(9, 0, 15))
    }

    @Test func daylightSavingHolesAndRepeatedMinutesAreMatchedByTheLocalClock() throws {
        let spring = calendar.dateInterval(of: .day, for: time(29, 12, month: 3))!
        #expect(rule([1], 130, 165).intervals(on: spring, calendar: calendar).isEmpty)
        let jump = rule([1], 110, 190).intervals(on: spring, calendar: calendar)
        #expect(jump == [DateInterval(start: time(29, 1, 50, month: 3), end: time(29, 3, 10, month: 3))])
        #expect(try #require(jump.first).duration == 1200)
        let autumn = calendar.dateInterval(of: .day, for: time(25, 12, month: 10))!
        let folded = rule([1], 135, 165)
        let intervals = folded.intervals(on: autumn, calendar: calendar)
        #expect(intervals.count == 2 && intervals.allSatisfy { $0.duration == 30 * 60 })
        if let first = intervals.first, let last = intervals.last {
            #expect(last.start.timeIntervalSince(first.start) == 3600)
            #expect(folded.interval(containing: first.end, calendar: calendar) == nil)
            #expect(folded.interval(containing: last.start, calendar: calendar) == last)
        }
        let fullSunday = rule([1], 0, 0)
        #expect(try #require(fullSunday.interval(containing: spring.start, calendar: calendar)).duration == 82_800)
        #expect(try #require(fullSunday.interval(containing: autumn.start, calendar: calendar)).duration == 90_000)
    }

    @Test func skippedPinDoesNotReserveBudgetAndPartialBlocksDoNotReleaseDependencies() {
        let day = time(9, 9)
        var call = PlanTask("Call studio", minutes: 16)
        call.after = time(9, 9, 5)
        call.availability = rule([2], 9 * 60 + 7, 9 * 60 + 12)
        var next = PlanTask("Confirm booking", minutes: 3)
        next.dependency = call.id
        var closed = PlanTask("Pick up parcel", minutes: 20)
        closed.plannedStart = time(9, 10)
        closed.availability = rule([4], 600, 720)
        let free = PlanTask("Send notes", minutes: 5)
        let tasks = [call, next, closed, free]
        let result = Planner.schedule(at: day, tasks: tasks, commitments: [], reports: [], dailyLimit: 10, breaks: false, calendar: calendar)
        #expect(result.map(\.kind) == [.task(free.id), .task(call.id)])
        #expect(result.last?.start == time(9, 9, 7) && result.last?.end == time(9, 9, 12))
        var booked = PlanTask("Reserved call", minutes: 2)
        booked.plannedStart = time(9, 9, 10)
        let pinned = Planner.schedule(at: day, tasks: [call, next, closed, free, booked], commitments: [], reports: [],
                                      dailyLimit: 10, breaks: false, calendar: calendar)
        #expect(pinned.map(\.kind) == [.task(free.id), .task(call.id), .task(booked.id)])
        #expect(pinned[1].minutes == 3 && pinned[2].start == booked.plannedStart)
    }

    @Test func whenACommitmentOccupiesTheEntireOpeningThereIsNoPhantomPinReservation() {
        let today = time(9, 9)
        var call = PlanTask("Call studio", minutes: 6)
        call.plannedStart = time(9, 10)
        call.availability = rule([2], 600, 606)
        let free = PlanTask("Read", minutes: 6)
        let meeting = Commitment("Appointment", start: time(9, 10), end: time(9, 11))
        let blocks = Planner.schedule(at: today, tasks: [free, call], commitments: [meeting], reports: [],
                                      dailyLimit: 6, breaks: false, calendar: calendar)
        #expect(blocks.contains { $0.kind == .task(free.id) && $0.minutes == 6 && $0.start == today })
        #expect(!blocks.contains { $0.kind == .task(call.id) })
    }

    @Test func weeklyPickerOffersUnroundedOpeningsAndItsChoicesSurviveARealPlannerReplay() throws {
        let now = time(9, 9)
        var call = PlanTask("Call studio", minutes: 11)
        call.availability = rule([3, 5], 9 * 60 + 7, 9 * 60 + 14)
        call.due = time(12, 17)
        var dependent = PlanTask("Collect key", minutes: 4)
        dependent.dependency = call.id
        let meeting = Commitment("Dentist", start: time(10, 9, 11), end: time(10, 10))
        let options = Planner.weekPlacements(for: call.id, at: now, tasks: [call, dependent], commitments: [meeting],
                                             reports: [], dailyLimit: 45, breaks: false, calendar: calendar)
        #expect(options.map(\.start) == [time(10, 9, 7), time(12, 9, 7)])
        #expect(options.first?.minutes == 4 && options.first?.projectedFinish == time(12, 9, 14))
        for choice in options {
            var moved = call
            moved.moveOccurrence(to: choice.start)
            let tasks = [moved, dependent]
            let today = Planner.schedule(at: now, tasks: tasks, commitments: [meeting], reports: [], dailyLimit: 45,
                                         breaks: false, calendar: calendar)
            let week = WeekOutlook.project(at: now, today: today, tasks: tasks, events: [meeting], reports: [], limit: 45,
                                           breaks: false, preferences: .init(), calendar: calendar)
            let actual = try #require(week.flatMap(\.blocks).first { $0.kind == .task(call.id) })
            #expect(actual.start == choice.start && actual.minutes == choice.minutes)
            let released = week.flatMap(\.blocks).first { $0.kind == .task(dependent.id) }
            if let finish = choice.projectedFinish { #expect(released?.start == finish) }
            else { #expect(released == nil) }
        }
    }

    @Test func spareMomentsRequireAllMinutesToFitTheCurrentWindow() {
        var short = PlanTask("Call studio", minutes: 4)
        short.availability = rule([2], 9 * 60 + 7, 9 * 60 + 11)
        var long = short.duplicate()
        long.minutes = 5
        func offered(_ date: Date) -> [Block] {
            Planner.spareMoments(at: date, minutes: 10, tasks: [short, long], commitments: [], reports: [],
                                 dailyLimit: 20, calendar: calendar)
        }
        #expect(offered(time(9, 9, 6)).isEmpty)
        #expect(offered(time(9, 9, 7)).map(\.kind) == [.task(short.id)])
        #expect(offered(time(9, 9, 8)).isEmpty)
        #expect(offered(time(10, 9, 7)).isEmpty)
    }
}
