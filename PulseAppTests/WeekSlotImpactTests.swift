import Foundation
import PulseEngine
import Testing
@testable import Pulse

struct WeekSlotImpactTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func request(tasks: [PlanTask], events: [Commitment] = []) -> WeekProjection {
        var journal = Journal()
        journal.tasks = tasks
        journal.limit = 45
        journal.breaks = false
        return WeekProjection(clock: time(9, 9), journal: journal, tasks: tasks, events: events,
                              preferences: .init(bufferMinutes: 10, wrapUpMinute: 18 * 60),
                              active: nil, calendar: calendar)
    }
    private func slots(_ base: WeekProjection, for id: UUID, sourceDay: Date? = nil) -> [TaskPlacement] {
        Planner.weekPlacements(for: id, at: base.clock, tasks: base.tasks, commitments: base.events,
                               reports: [], dailyLimit: base.journal.limit, breaks: base.journal.breaks,
                               preferences: base.preferences, calendar: calendar, sourceDay: sourceDay)
    }

    @Test func resizeRetainsClockAndRejectsBufferedOrStaleIntervals() throws {
        var task = PlanTask("Outline", minutes: 8)
        task.plannedStart = time(10, 10)
        let meeting = Commitment("Review", start: time(10, 10, 45), end: time(10, 11))
        let base = request(tasks: [task], events: [meeting])
        let start = time(10, 10)
        #expect(try base.resizedTasks(task.id, start: start, end: time(10, 10, 8), minutes: 35)[0].minutes == 35)
        #expect(throws: TimelineResizeError.self) {
            try base.resizedTasks(task.id, start: start, end: time(10, 10, 8), minutes: 36)
        }
        #expect(throws: TimelineResizeError.self) {
            try base.resizedTasks(task.id, start: start, end: time(10, 10, 7), minutes: 15)
        }
    }

    @Test func fullDestinationOffersTheNextEnergyMatchWhenTheCurrentTimeIsBest() throws {
        var task = PlanTask("Outline", minutes: 8)
        task.energyOverride = 8
        task.plannedStart = time(9, 9)
        let trip = Commitment("Field trip", start: time(10, 0), end: time(11, 0))
        let base = request(tasks: [task], events: [trip])
        var preferences = base.preferences
        preferences.expectations = [
            try #require(EnergyExpectation(at: time(9, 9), scope: .hour, score: 8, calendar: calendar)),
            try #require(EnergyExpectation(at: time(11, 14), scope: .hour, score: 7, calendar: calendar)),
        ]
        let options = Planner.weekPlacements(for: task.id, at: base.clock, tasks: [task], commitments: [trip],
                                             reports: [], dailyLimit: 45, breaks: false, preferences: preferences,
                                             calendar: calendar, sourceDay: time(9, 0))
        #expect(options.first(where: \.recommended)?.start == task.plannedStart)
        #expect(!options.contains { calendar.isDate($0.start, inSameDayAs: time(10, 0)) })
        let alternative = try #require(TimeDropSuggestion(for: task, from: time(9, 0), day: time(10, 0),
                                                          hour: nil, options: options, calendar: calendar))
        #expect(alternative.start == time(11, 14))
        #expect(TimeDropSuggestion(for: task, from: time(9, 0), day: time(10, 0), hour: nil,
                                   options: options.filter(\.recommended), calendar: calendar) == nil)
    }

    @Test @MainActor func aWholeDayDropNamesTheCommitmentCoveringThatDate() throws {
        let store = Workspace()
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: .now))
        let day = try #require(Calendar.current.dateInterval(of: .day, for: tomorrow))
        store.journal.events = [Commitment("Field trip", start: day.start, end: day.end)]
        #expect(store.blockedDropMessage(taskID: UUID(), day: day.start, hour: nil) == "“Field trip” fills that day.")
    }

    @Test func delayingOneTaskFreesAnotherEarlierAndExplainsTheCalendarBuffer() throws {
        var first = PlanTask("Outline", minutes: 10)
        first.plannedStart = time(9, 9)
        let later = PlanTask("Send notes", minutes: 5)
        let meeting = Commitment("Studio", start: time(10, 13), end: time(10, 13, 50))
        // A live appointment can be present in these inputs while absent from the saved journal.
        let base = request(tasks: [first, later], events: [meeting])
        let choice = try #require(slots(base, for: first.id).first { $0.start == time(10, 14) })
        let impact = try #require(base.impact(of: choice, taskID: first.id))
        #expect(impact.selectedChanged && impact.others.count == 1)
        #expect(impact.others[0].id == later.id)
        #expect(impact.others[0].before.first?.start == time(9, 9, 10))
        #expect(impact.others[0].after.first?.start == time(9, 9))
        #expect(impact.others[0].after.first?.minutes == 5)
        #expect(impact.margin?.title == "Studio" && impact.margin?.eventIsFirst == true)
        #expect(impact.margin?.gap == 600 && impact.margin?.buffer == 10)
        #expect(base.journal.tasks == [first, later] && base.journal.events.isEmpty)
    }

    @Test func distinguishesOneChangedTaskFromAnAlreadyMatchingTime() throws {
        let only = PlanTask("Read", minutes: 7)
        let base = request(tasks: [only])
        let options = slots(base, for: only.id)
        let later = try #require(options.first { $0.start == time(10, 10) })
        let shifted = try #require(base.impact(of: later, taskID: only.id))
        #expect(shifted.selectedChanged && shifted.others.isEmpty && shifted.margin == nil)
        let same = try #require(options.first { $0.start == time(9, 9) })
        let unchanged = try #require(base.impact(of: same, taskID: only.id))
        #expect(!unchanged.selectedChanged && unchanged.others.isEmpty)
        let unavailable = request(tasks: [only], events: [Commitment("Busy", start: later.start, end: time(10, 12))])
        #expect(unavailable.impact(of: later, taskID: only.id) == nil)
    }

    @Test func projectedRoutinePreviewUsesTheOwnersExceptionWithoutSavingIt() throws {
        var thursday = PlanTask("Journal", minutes: 6)
        thursday.repeated = .weekdays
        thursday.plannedStart = time(12, 11)
        let base = request(tasks: [thursday])
        let friday = try #require(base.days()[4].projectedTasks.first)
        let saturday = try #require(slots(base, for: friday.id, sourceDay: time(13, 11)).first { $0.start == time(14, 11) })
        let impact = try #require(base.impact(of: saturday, taskID: friday.id))
        #expect(impact.selectedChanged && impact.others.isEmpty)
        #expect(base.journal.tasks == [thursday] && thursday.routineExceptions == nil)
    }

    @Test func resizesProjectedWorkInAPersonalEnergyWindow() throws {
        var short = PlanTask("Print notes", minutes: 5)
        short.plannedStart = time(9, 9, 56)
        var long = PlanTask("Research", minutes: 24)
        long.after = time(9, 9, 56)
        let base = request(tasks: [short, long])
        var preferences = base.preferences
        preferences.expectations = [try #require(EnergyExpectation(at: time(9, 10), scope: .hour, score: 8, calendar: calendar))]
        let expected = WeekProjection(clock: base.clock, journal: base.journal, tasks: base.tasks, events: [],
                                      preferences: preferences, active: nil, calendar: calendar)
        let choice = try #require(slots(expected, for: short.id).first { $0.start == time(10, 11) })
        let impact = try #require(expected.impact(of: choice, taskID: short.id))
        let changed = try #require(impact.others.first { $0.id == long.id })
        #expect(changed.before.first?.minutes == 24)
        #expect(changed.after.first?.minutes == 15)
    }

    @Test func identifiesTheNextDaysBuffer() throws {
        var task = PlanTask("Read", minutes: 5)
        task.plannedStart = time(9, 23, 50)
        let next = Commitment("Night shift", start: time(10, 0), end: time(10, 6))
        let base = request(tasks: [task], events: [next])
        let late = WeekProjection(clock: base.clock, journal: base.journal, tasks: base.tasks, events: base.events,
                                  preferences: .init(bufferMinutes: 5), active: nil, calendar: calendar)
        let day = try #require(late.days().first)
        let item = try #require(day.blocks.first { $0.kind == .task(task.id) })
        let adjacent = WeekSlotImpact.adjacent(to: item, in: day, events: [next], buffer: 5, calendar: calendar)
        #expect(adjacent?.eventIsFirst == false && adjacent?.gap == 300)
    }

    @Test func anActiveHoldIsIdentifiedAsFocusAndConsumesItsRemainingBudget() throws {
        let focus = PlanTask("Outline", minutes: 10)
        let next = PlanTask("Send notes", minutes: 7)
        let base = request(tasks: [focus, next])
        var journal = base.journal
        let running = ActiveSession(task: focus, minutes: 10, now: base.clock, tick: 1, boot: "test")
        journal.active = running
        journal.limit = 16
        let active = running.record(now: base.clock, tick: 1, boot: "test")
        let request = WeekProjection(clock: base.clock, journal: journal, tasks: base.tasks, events: [],
                                     preferences: base.preferences, active: active, calendar: calendar)
        let input = try #require(DayScheduleInputs(journal: journal, events: [], tasks: base.tasks,
                                                   at: base.clock, active: active, calendar: calendar))
        let options = Planner.weekPlacements(for: next.id, at: base.clock, tasks: input.tasks, commitments: input.events,
                                             reports: [], dailyLimit: journal.limit, usedMinutes: input.used,
                                             breaks: journal.breaks, preferences: base.preferences, calendar: calendar)
        let immediatelyAfter = try #require(options.first { $0.start == time(9, 9, 20) })
        #expect(immediatelyAfter.minutes == 6)
        let margin = try #require(request.impact(of: immediatelyAfter, taskID: next.id)?.margin)
        #expect(margin.isFocus && margin.gap == 600)
    }
}
