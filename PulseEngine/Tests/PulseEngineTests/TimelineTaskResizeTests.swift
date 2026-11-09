import Foundation
import Testing
@testable import PulseEngine

@Suite struct TimelineTaskResizeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
    private var morning: Date { calendar.date(from: .init(year: 2026, month: 11, day: 9, hour: 9))! }

    private func week(_ tasks: [PlanTask]) -> [OutlookDay] {
        let today = Planner.schedule(at: morning, tasks: tasks, commitments: [], reports: [], dailyLimit: 90,
                                     breaks: false, calendar: calendar)
        return WeekOutlook.project(at: morning, today: today, tasks: tasks, events: [], reports: [], limit: 90,
                                   breaks: false, preferences: .init(), calendar: calendar)
    }

    private func resize(_ tasks: [PlanTask], id: UUID, block: Block, to minutes: Int) throws -> [PlanTask] {
        try TaskRoutines.resizing(id, start: block.start, end: block.end, to: minutes,
                                 tasks: tasks, days: week(tasks), now: morning, calendar: calendar)
    }

    @Test func explicitDurationSurvivesReloadAndDayMoveAndKeepsProgress() throws {
        var task = PlanTask("Draw", minutes: 14)
        task.recordFocus(seconds: 93, completed: false)
        let before = try #require(week([task])[0].blocks.first)
        var edited = try #require(resize([task], id: task.id, block: before, to: 31).first)
        edited = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(edited))
        #expect(edited.remainingSeconds == task.remainingSeconds + Double(31 - before.minutes) * 60)
        #expect(edited.focusedSeconds == 93)
        #expect(week([edited])[0].blocks.first?.minutes == 31)
        let destination = morning.addingTimeInterval(86400 + 17 * 60)
        edited.moveOccurrence(to: destination, originalDay: before.start, calendar: calendar)
        #expect(week([edited])[1].blocks.first?.start == destination)
        #expect(week([edited])[1].blocks.first?.minutes == 31)
    }

    @Test func resizingLaterSlicePreservesEarlierWork() throws {
        let task = PlanTask("Long task", minutes: 72)
        let before = week([task])
        let second = try #require(before[1].blocks.first)
        let edited = try resize([task], id: task.id, block: second, to: 7)
        let after = week(edited)
        #expect(after[0].blocks == before[0].blocks)
        #expect(after[1].blocks.first?.start == second.start)
        #expect(after[1].blocks.first?.minutes == 7)
        #expect(edited[0].minutes == task.minutes + 7 - second.minutes)
    }

    @Test func projectedRoutineResizesOneOccurrence() throws {
        var task = PlanTask("Practice", minutes: 8)
        task.repeated = .daily
        task.plannedStart = morning
        let before = week([task])
        let second = try #require(before[1].blocks.first)
        guard case .task(let id) = second.kind else { Issue.record("Expected projected task"); return }
        let edited = try resize([task], id: id, block: second, to: 23)
        let after = week(edited)
        #expect(after[0].blocks == before[0].blocks)
        #expect(after[1].blocks.first?.kind == .task(id))
        #expect(after[1].blocks.first?.minutes == 23)
        #expect(after[2].blocks == before[2].blocks)
    }
}
