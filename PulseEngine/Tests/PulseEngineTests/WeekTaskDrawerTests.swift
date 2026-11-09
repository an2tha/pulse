import Foundation
import Testing
@testable import PulseEngine

@Suite struct WeekTaskDrawerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
    private func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func week(_ tasks: [PlanTask]) -> [OutlookDay] {
        let now = at(9, 9)
        let today = Planner.schedule(at: now, tasks: tasks, commitments: [], reports: [], dailyLimit: 90,
                                     breaks: false, calendar: calendar)
        return WeekOutlook.project(at: now, today: today, tasks: tasks, events: [], reports: [], limit: 90,
                                   breaks: false, preferences: .init(), calendar: calendar)
    }

    @Test func drawerTaskFitsExactMinuteBeforeDefaultPlanningStartAndAvoidsCollision() {
        var task = PlanTask("Book travel", minutes: 6)
        task.inboxOnly = true
        let events = [Commitment("Train", start: at(10, 7, 50), end: at(10, 8, 10))]
        func slots(_ exact: Date) -> [TaskPlacement] {
            Planner.weekPlacements(for: task.id, at: at(9, 9), tasks: [task], commitments: events,
                                   reports: [], dailyLimit: 90, calendar: calendar, exactStart: exact)
        }
        #expect(slots(at(10, 7, 31)).map(\.start) == [at(10, 7, 31)])
        #expect(slots(at(10, 7, 58)).isEmpty)
        #expect(slots(at(8, 11)).isEmpty)
        #expect(slots(at(16, 11)).isEmpty)
    }

    @Test func futureTimelineRetainsExactInstantsAcrossDaylightSavingChanges() throws {
        var local = calendar
        local.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var task = PlanTask("Read", minutes: 5)
        task.inboxOnly = true
        let formatter = ISO8601DateFormatter()
        let instants = [
            "2026-03-29T01:17:00Z", // 03:17 after the missing hour
            "2026-10-25T00:17:00Z", // 02:17 in summer time
            "2026-10-25T01:17:00Z"  // 02:17 in standard time
        ]
        for instant in instants {
            let exact = try #require(formatter.date(from: instant))
            let priorDay = try #require(local.date(byAdding: .day, value: -1, to: local.startOfDay(for: exact)))
            let placements = Planner.weekPlacements(for: task.id, at: priorDay, tasks: [task], commitments: [],
                                                     reports: [], dailyLimit: 90, calendar: local, exactStart: exact)
            #expect(placements.map(\.start) == [exact])
            var pinned = task
            pinned.moveOccurrence(to: exact, originalDay: exact, calendar: local)
            let projected = WeekOutlook.project(at: priorDay, today: [], tasks: [pinned], events: [],
                                               reports: [], limit: 90, breaks: false, preferences: .init(),
                                               calendar: local)
            #expect(projected[1].blocks.first { $0.kind == .task(task.id) }?.start == exact)
        }
    }

    @Test func returnedMaterializedRoutineKeepsAuthoredDetailsAndGeneratesNextSibling() throws {
        var routine = PlanTask("Read", minutes: 8)
        routine.repeated = .daily
        routine.plannedStart = at(9, 10)
        routine.notes = "Chapter four"
        routine.due = at(9, 14)
        var tasks = [routine]
        #expect(TaskRoutines.returnToDrawer(routine.id, in: &tasks, projected: nil, from: at(9), at: at(9, 9), calendar: calendar))
        let held = try #require(tasks.first { $0.id == routine.id })
        #expect(held.isInboxOnly && held.plannedStart == nil && held.notes == routine.notes && held.due == routine.due)
        #expect(!held.done && held.repeated == nil)
        let successor = try #require(tasks.first { $0.id != routine.id })
        #expect(successor.seriesID == routine.id && successor.plannedStart == at(10, 10) && !successor.isInboxOnly)
        #expect(week(tasks)[2].blocks.contains { $0.title == routine.title })
    }

    @Test func returnedProjectedOccurrenceSurvivesRoundTripAndDoesNotRegenerateAfterDeletingDrawerItem() throws {
        var routine = PlanTask("Morning pages", minutes: 7)
        routine.repeated = .daily
        routine.plannedStart = at(9, 9)
        var tasks = [routine]
        let preview = try #require(week(tasks)[2].projectedTasks.first)
        let exact = at(11, 12, 17)
        let placements = Planner.weekPlacements(for: preview.id, at: at(9, 9), tasks: tasks, commitments: [],
                                                 reports: [], dailyLimit: 90, calendar: calendar, sourceDay: at(11), exactStart: exact)
        #expect(placements.map(\.start) == [exact])
        #expect(placements.first?.projectedOccurrence == preview.occurrence(in: calendar))
        #expect(TaskRoutines.returnToDrawer(preview.id, in: &tasks, projected: preview, from: at(11), at: at(9, 9), calendar: calendar))
        tasks = try JSONDecoder().decode([PlanTask].self, from: JSONEncoder().encode(tasks))
        #expect(tasks.first { $0.id == preview.id }?.isInboxOnly == true)
        #expect(!TaskRoutines.returnToDrawer(preview.id, in: &tasks, projected: preview, from: at(11), at: at(9, 9), calendar: calendar))
        tasks.removeAll { $0.id == preview.id }
        let forecast = week(tasks)
        #expect(!forecast[1].projectedTasks.isEmpty)
        #expect(forecast[2].blocks.allSatisfy { $0.title != routine.title })
        #expect(!forecast[3].projectedTasks.isEmpty)
    }
}
