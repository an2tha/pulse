import Foundation
import Testing
@testable import PulseEngine

struct RecurringDependencyPlacementTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Lord_Howe")!
        return calendar
    }

    private func time(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func week(_ tasks: [PlanTask], limit: Int) -> [OutlookDay] {
        let now = time(23, 9)
        let today = Planner.schedule(at: now, tasks: tasks, commitments: [], reports: [], dailyLimit: limit,
                                     breaks: false, calendar: calendar)
        return WeekOutlook.project(at: now, today: today, tasks: tasks, events: [], reports: [], limit: limit,
                                   breaks: false, preferences: .init(), calendar: calendar)
    }

    @Test func movingRoutineHonorsThatDaysGeneratedPrerequisite() throws {
        var prep = PlanTask("Gather notes", minutes: 10)
        prep.repeated = .daily
        prep.plannedStart = time(24, 12)
        var review = PlanTask("Daily review", minutes: 12)
        review.repeated = .daily
        review.plannedStart = time(27, 10)
        review.dependency = prep.id
        let tasks = [prep, review]
        let options = Planner.weekPlacements(for: review.id, at: time(23, 9), tasks: tasks, commitments: [],
                                             reports: [], dailyLimit: 45, breaks: false, calendar: calendar)
        let wednesday = options.filter { calendar.isDate($0.start, inSameDayAs: time(25, 9)) }
        #expect(!wednesday.isEmpty)
        #expect(wednesday.allSatisfy { $0.start >= time(25, 12).addingTimeInterval(600) })
        for slot in wednesday {
            var moved = tasks
            moved[1].moveOccurrence(to: slot.start, originalDay: slot.originalStart ?? slot.start, calendar: calendar)
            #expect(week(moved, limit: 45).flatMap(\.blocks).contains {
                $0.kind == .task(review.id) && $0.start == slot.start && $0.minutes == slot.minutes
            })
        }
    }

    @Test func unplacedRoutineUsesEachDestinationDayForItsPrerequisite() throws {
        var prep = PlanTask("Weekly preparation", minutes: 5)
        prep.repeated = .weekly
        prep.plannedStart = time(20, 12)
        var review = PlanTask("Daily review", minutes: 10)
        review.repeated = .daily
        review.dependency = prep.id
        review.importance = 0
        let backlog = (0..<12).map { index in
            var item = PlanTask("Inbox item \(index)", minutes: 15)
            item.importance = 10
            return item
        }
        let tasks = [prep] + backlog + [review]
        #expect(!week(tasks, limit: 15).flatMap(\.blocks).contains { $0.kind == .task(review.id) })
        let options = Planner.weekPlacements(for: review.id, at: time(23, 9), tasks: tasks, commitments: [],
                                             reports: [], dailyLimit: 15, breaks: false, calendar: calendar)
        #expect(options.allSatisfy { $0.originalStart == nil })
        // Tuesday can use the completed preparation. A Friday move must wait for Friday’s new one.
        #expect(options.contains { $0.start == time(24, 9) })
        #expect(!options.contains { calendar.isDate($0.start, inSameDayAs: time(27, 9)) && $0.start < time(27, 12).addingTimeInterval(300) })
        for slot in options.filter(\.recommendedForDay) {
            var moved = tasks
            moved[moved.count - 1].moveOccurrence(to: slot.start, originalDay: slot.start, calendar: calendar)
            #expect(week(moved, limit: 15).flatMap(\.blocks).contains {
                $0.kind == .task(review.id) && $0.start == slot.start && $0.minutes == slot.minutes
            })
        }
    }
}
