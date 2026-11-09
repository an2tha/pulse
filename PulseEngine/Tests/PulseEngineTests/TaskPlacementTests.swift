import Foundation
import Testing

@testable import PulseEngine

@Suite struct TaskPlacementTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func time(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func aMissedPinDoesNotTakeTheNextOnTimeReservation() {
        var missed = PlanTask("Review notes", minutes: 8)
        missed.plannedStart = time(9)
        var onTime = PlanTask("Send the drawings", minutes: 8)
        onTime.plannedStart = time(10)
        for ends in [time(10), time(9, 58)] {
            let event = Commitment("Unexpected call", start: time(9), end: ends)
            let blocks = Planner.schedule(at: time(9), tasks: [missed, onTime], commitments: [event],
                                          reports: [], dailyLimit: 8, breaks: false, calendar: calendar)
            #expect(blocks.contains { $0.kind == .task(onTime.id) && $0.start == time(10) && $0.minutes == 8 })
        }
    }

    @Test func protectsPrerequisitesOtherPinsBuffersAndOriginalLength() throws {
        let now = time(9)
        let before = PlanTask("Gather notes", minutes: 10)
        var task = PlanTask("Draft", minutes: 10)
        task.dependency = before.id
        var pinned = PlanTask("Send report", minutes: 10)
        pinned.plannedStart = time(11)
        let event = Commitment("Class", start: time(10), end: time(10, 13))
        let options = PlannerPreferences(bufferMinutes: 5)
        let tasks = [task, pinned, before]
        let places = Planner.placements(for: task.id, at: now, tasks: tasks, commitments: [event], reports: [],
                                       dailyLimit: 30, preferences: options, calendar: calendar)
        #expect(!places.isEmpty)
        // An explicit pin can start as soon as the prerequisite ends.
        #expect(places.first?.start == time(9, 10))
        #expect(places.contains { $0.start == time(10, 18) })
        #expect(places.filter(\.recommended).count == 1)
        for place in places {
            var trial = tasks
            trial[0].plannedStart = place.start
            let plan = Planner.schedule(at: now, tasks: trial, commitments: [event], reports: [], dailyLimit: 30,
                                        preferences: options, calendar: calendar)
            let moved = try #require(plan.first { $0.kind == .task(task.id) })
            #expect(moved.start == place.start && moved.minutes == 10)
            #expect(plan.contains { $0.kind == .task(pinned.id) && $0.start == time(11) && $0.minutes == 10 })
        }
    }

    @Test func drawerDropPinsAHeldTaskAtTheChosenQuarterHour() throws {
        let now = time(9)
        let selected = time(11, 45)
        var task = PlanTask("Sketch", minutes: 8)
        task.inboxOnly = true
        func options(_ start: Date?) -> [TaskPlacement] {
            Planner.placements(for: task.id, at: now, tasks: [task], commitments: [], reports: [],
                               dailyLimit: 30, breaks: false, calendar: calendar, exactStart: start)
        }
        #expect(!options(nil).contains { $0.start == selected })
        let result = try #require(options(selected).first)
        #expect(result.start == selected && result.originalStart == nil)
        #expect(task.isInboxOnly)
        task.moveOccurrence(to: result.start)
        #expect(!task.isInboxOnly && task.assignedFocusBlockID == nil)
        let saved = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(task))
        let day = Planner.schedule(at: now, tasks: [saved], commitments: [], reports: [],
                                   dailyLimit: 30, breaks: false, calendar: calendar)
        #expect(day.contains { $0.kind == .task(task.id) && $0.start == selected })
    }

    @Test func exactDropPreservesExistingReservationsAndRejectsExpiredTimes() {
        let now = time(9)
        var task = PlanTask("Read", minutes: 8)
        task.plannedStart = time(10)
        var pinned = PlanTask("Call", minutes: 10)
        pinned.plannedStart = time(11, 15)
        let event = Commitment("Appointment", start: time(11, 45), end: time(12, 30))
        func options(_ time: Date) -> [TaskPlacement] {
            Planner.placements(for: task.id, at: now, tasks: [task, pinned], commitments: [event],
                               reports: [], dailyLimit: 30, breaks: false, calendar: calendar, exactStart: time)
        }
        #expect(options(time(10, 30)).first?.originalStart == time(10))
        for unavailable in [time(8, 45), time(11, 15), time(12), time(10, day: 11)] {
            #expect(options(unavailable).isEmpty)
        }
    }

    @Test func movingAnOccurrenceDoesNotPinFutureFlexibleRoutines() throws {
        var task = PlanTask("Walk", minutes: 5)
        task.repeated = .daily
        task.moveOccurrence(to: time(16))
        task.moveOccurrence(to: time(17))
        #expect(task.plannedStart == time(17))
        task.done = true
        var tasks = [task]
        TaskRoutines.advance(&tasks, at: time(17), calendar: calendar)
        let next = try #require(tasks.last)
        #expect(next.id != task.id && next.plannedStart == nil)
    }

    @Test func rejectsExpiredDaysAndExhaustedBudgets() {
        let task = PlanTask("Read", minutes: 10)
        #expect(Planner.placements(for: task.id, at: time(23,59).addingTimeInterval(45), tasks: [task],
                                   commitments: [], reports: [], dailyLimit: 60, calendar: calendar).isEmpty)
        #expect(Planner.placements(for: task.id, at: time(12), tasks: [task], commitments: [], reports: [],
                                   dailyLimit: 10, usedMinutes: 10, calendar: calendar).isEmpty)
    }

    @Test func ranksByForecastButNeverOverridesManualCapacityOrDeadline() throws {
        let now = time(9)
        var task = PlanTask("Research", minutes: 8)
        task.energyOverride = 8
        let reports = (4...9).flatMap { day in
            [CheckIn(date: time(10, day: day), energy: 2, clarity: 4, interest: 3),
             CheckIn(date: time(16, day: day), energy: 8, clarity: 7, interest: 8)]
        }
        let forecast = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: now, calendar: calendar)
        func best(_ item: PlanTask, preferences: PlannerPreferences = .init()) throws -> TaskPlacement {
            let options = Planner.placements(for: item.id, at: now, tasks: [item], commitments: [], reports: [],
                                            dailyLimit: 20, preferences: preferences, calendar: calendar,
                                            forecast: forecast)
            return try #require(options.first { $0.recommended })
        }
        let suggested = try best(task)
        #expect(suggested.start == time(15) && suggested.forecastScore == 8)
        #expect(suggested.capacity == 5)
        var tuning = PlanTuning(date: now)
        tuning.manualCapacity = 4
        #expect(try best(task, preferences: .init(tuning: tuning)).start == now)
        task.due = time(14)
        #expect(try best(task).start < time(14))
    }
}
