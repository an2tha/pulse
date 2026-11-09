import Foundation
import Testing
@testable import PulseEngine

struct ProjectedRoutineTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }
    private func time(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func outlook(_ tasks: [PlanTask], events: [Commitment] = []) -> [OutlookDay] {
        let now = time(22, 9)
        let today = Planner.schedule(at: now, tasks: tasks, commitments: events, reports: [], dailyLimit: 45, calendar: calendar)
        return WeekOutlook.project(at: now, today: today, tasks: tasks, events: events,
                                   reports: [], limit: 45, breaks: true, preferences: .init(), calendar: calendar)
    }

    @Test func movingFridayDoesNotMaterializeOrShiftMondayAcrossDST() throws {
        var current = PlanTask("Evening journal", minutes: 6)
        current.repeated = .weekdays
        current.plannedStart = time(22, 11)
        let unavailable = Commitment("Lunch", start: time(24, 12), end: time(24, 13))
        let preview = outlook([current], events: [unavailable])
        let friday = try #require(preview[1].projectedTasks.first)
        let monday = try #require(preview[4].projectedTasks.first)
        #expect(outlook([current])[1].projectedTasks.first?.id == friday.id)
        let key = try #require(friday.occurrence(in: calendar))
        let options = Planner.weekPlacements(for: friday.id, at: time(22, 9), tasks: [current],
                                             commitments: [unavailable], reports: [], dailyLimit: 45,
                                             calendar: calendar, sourceDay: time(23, 11))
        #expect(options.allSatisfy { $0.start >= time(23, 0) && $0.start < time(26, 0) && $0.projectedOccurrence == key })
        #expect(!options.contains { $0.start == time(24, 12) })
        let chosen = try #require(options.first { $0.start == time(24, 14) })
        current.setException(RoutineException(occurrence: key, start: chosen.start), for: key)
        let saved = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(current))
        #expect(!saved.done && saved.plannedStart == time(22, 11))
        let after = outlook([saved], events: [unavailable])
        #expect(!after[1].blocks.contains { $0.kind == .task(friday.id) })
        #expect(after[2].blocks.contains { $0.kind == .task(friday.id) && $0.start == chosen.start })
        #expect(after[4].blocks.contains { $0.kind == .task(monday.id) && $0.start == time(26, 11) })
        var real = [saved]
        real[0].done = true
        real[0].completedAt = time(22, 12)
        TaskRoutines.advance(&real, at: time(22, 12), calendar: calendar)
        #expect(real.map(\.id) == [saved.id, friday.id])
        #expect(real[1].plannedStart == chosen.start && real[1].routineAnchor == time(23, 11))
        #expect(real.allSatisfy { ($0.routineExceptions ?? []).isEmpty })
        real[1].done = true
        TaskRoutines.advance(&real, at: chosen.start, calendar: calendar)
        #expect(real.last?.id == monday.id && real.last?.plannedStart == time(26, 11))
    }

    @Test func repeatedReplaysExpireMissedExceptionsAndRejectStaleOrWrongSeries() throws {
        var first = PlanTask("Read", minutes: 5)
        first.repeated = .daily
        let friday = try #require(outlook([first])[1].projectedTasks.first)
        let key = try #require(friday.occurrence(in: calendar))
        first.setException(RoutineException(occurrence: key, start: time(23, 15)), for: key)
        var real = [first]
        real[0].done = true
        TaskRoutines.advance(&real, at: time(25, 12), calendar: calendar)
        #expect(real[1].id != key.id && real[1].plannedStart == nil && (real[1].routineExceptions ?? []).isEmpty)
        #expect(Planner.weekPlacements(for: key.id, at: time(25, 12), tasks: real, commitments: [], reports: [],
                                       dailyLimit: 45, calendar: calendar, sourceDay: time(23, 9)).isEmpty)
        var another = first.duplicate()
        another.setException(RoutineException(occurrence: key, start: time(23, 15)), for: key)
        #expect(another.routineExceptions == nil)
        var zone = calendar
        zone.timeZone = TimeZone(identifier: "America/New_York")!
        let localFriday = zone.date(from: DateComponents(year: 2026, month: 10, day: 23))!
        #expect(RoutineOccurrence(seriesID: key.seriesID, rule: key.rule, day: localFriday, calendar: zone) == key)
    }

    @Test func latePredecessorStillReleasesAnUpcomingMovedWeekendOccurrence() throws {
        var predecessor = PlanTask("Review", minutes: 5)
        predecessor.repeated = .weekdays
        predecessor.plannedStart = time(22, 11)
        let key = RoutineOccurrence(seriesID: predecessor.id, rule: .weekdays, day: time(23, 11), calendar: calendar)
        predecessor.setException(.init(occurrence: key, start: time(24, 14)), for: key)
        predecessor.done = true
        predecessor.completedAt = time(24, 10)
        var real = [predecessor]
        TaskRoutines.advance(&real, at: time(24, 10), calendar: calendar)
        #expect(real[1].id == key.id && real[1].plannedStart == time(24, 14))
        real = [predecessor]
        TaskRoutines.advance(&real, at: time(24, 16), calendar: calendar)
        #expect(real[1].id != key.id && real[1].plannedStart == time(26, 11))
    }

    @Test func weeklyOccurrenceCanComeForwardAfterPreviousWorkAndProtectOtherPins() throws {
        var past = PlanTask("Weekly review", minutes: 7)
        past.repeated = .weekly
        past.plannedStart = time(19, 11)
        var call = PlanTask("Call", minutes: 10)
        call.plannedStart = time(23, 9)
        let input = [past, call]
        let monday = try #require(outlook(input)[4].projectedTasks.first)
        let key = try #require(monday.occurrence(in: calendar))
        let slots = Planner.weekPlacements(for: monday.id, at: time(22, 9), tasks: input,
                                           commitments: [], reports: [], dailyLimit: 45, calendar: calendar, sourceDay: time(26, 11))
        #expect(slots.allSatisfy { $0.start >= time(23, 0) })
        let slot = try #require(slots.first { $0.start == time(23, 10) })
        past.setException(.init(occurrence: key, start: slot.start), for: key)
        let moved = outlook([past, call])
        #expect(moved[1].blocks.contains { $0.kind == .task(monday.id) && $0.start == slot.start })
        #expect(moved[1].blocks.contains { $0.kind == .task(call.id) && $0.start == call.plannedStart })
        #expect(!moved[4].blocks.contains { $0.kind == .task(monday.id) })
    }

    @Test func movingALaterProjectedPieceReplaysTheWholeOccurrence() throws {
        var first = PlanTask("Work through the notes", minutes: 20)
        first.repeated = .weekly
        first.plannedStart = time(19, 11)
        let now = time(22, 9)
        func preview(_ task: PlanTask) -> [OutlookDay] {
            let today = Planner.schedule(at: now, tasks: [task], commitments: [], reports: [], dailyLimit: 15, calendar: calendar)
            return WeekOutlook.project(at: now, today: today, tasks: [task], events: [], reports: [], limit: 15,
                                       breaks: true, preferences: .init(), calendar: calendar)
        }
        let days = preview(first)
        let secondPiece = try #require(days[5].projectedTasks.first)
        #expect(secondPiece.minutes == 5)
        let key = try #require(secondPiece.occurrence(in: calendar))
        let slots = Planner.weekPlacements(for: secondPiece.id, at: now, tasks: [first], commitments: [], reports: [],
                                           dailyLimit: 15, calendar: calendar, sourceDay: time(27, 9))
        let slot = try #require(slots.first { $0.start == time(24, 10) })
        #expect(slot.minutes == 15)
        first.setException(.init(occurrence: key, start: slot.start), for: key)
        let actual = preview(first).flatMap(\.blocks).filter { $0.kind == .task(key.id) }
        #expect(actual.first?.start == slot.start && actual.first?.minutes == slot.minutes)
        #expect(actual.map(\.minutes) == [15, 5])
    }
}
