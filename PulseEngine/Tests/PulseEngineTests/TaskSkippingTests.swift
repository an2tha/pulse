import Foundation
import Testing
@testable import PulseEngine

@Suite struct TaskSkippingTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }
    private func at(_ date: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 3, day: date, hour: hour))!
    }

    @Test func upcomingSlotTracksPlanUntilItsStartThenSurvivesAReplanAndRelaunch() throws {
        var task = PlanTask("Write", minutes: 20)
        func block(_ start: Date) -> Block {
            Block(kind: .task(task.id), title: task.title, start: start, end: start.addingTimeInterval(1200))
        }
        var starts = TaskSkipping.automaticStarts([:], tasks: [task], blocks: [block(at(29, 9))], at: at(29, 7))
        starts = TaskSkipping.automaticStarts(starts, tasks: [task], blocks: [block(at(29, 10))], at: at(29, 8))
        #expect(TaskSkipping.eligibleStart(for: task, automaticStart: starts[task.id], at: at(29, 9)) == nil)
        starts = TaskSkipping.automaticStarts(starts, tasks: [task], blocks: [block(at(29, 14))], at: at(29, 10))
        starts = try JSONDecoder().decode([UUID: Date].self, from: JSONEncoder().encode(starts))
        starts = TaskSkipping.automaticStarts(starts, tasks: [task], blocks: [], at: at(30, 8))
        #expect(TaskSkipping.eligibleStart(for: task, automaticStart: starts[task.id], at: at(30, 8)) == at(29, 10))
        task.plannedStart = at(31, 9)
        #expect(TaskSkipping.eligibleStart(for: task, automaticStart: starts[task.id], at: at(30, 8)) == nil)
        #expect(TaskSkipping.automaticStarts(starts, tasks: [task], blocks: [], at: at(30, 8)).isEmpty)
    }

    @Test func oneOffSkipDefersThroughLocalMidnightAndDoesNotCompleteOrDuplicate() {
        var task = PlanTask("Laundry", minutes: 8)
        task.plannedStart = at(29, 8)
        task.reminder = at(29, 10)
        task.due = at(31, 16)
        var tasks = [task]
        #expect(!TaskSkipping.skip(task.id, in: &tasks, scheduledStart: at(29, 8), at: at(29, 7), calendar: calendar))
        #expect(TaskSkipping.skip(task.id, in: &tasks, scheduledStart: at(29, 8), at: at(29, 8), calendar: calendar))
        #expect(tasks[0].after == at(30) && tasks[0].plannedStart == nil && tasks[0].reminder == nil)
        #expect(!tasks[0].done && tasks[0].due == task.due)
        #expect(!TaskSkipping.skip(task.id, in: &tasks, scheduledStart: at(29, 8), at: at(29, 14), calendar: calendar))
    }

    @Test func skippingAnOverdueRepeatKeepsItsCadenceAndNeverReportsItAsDone() throws {
        var task = PlanTask("Walk", minutes: 15)
        task.plannedStart = at(27, 9)
        task.reminder = at(27, 8)
        task.repeated = .daily
        var tasks = [task]
        #expect(TaskSkipping.skip(task.id, in: &tasks, scheduledStart: at(27, 9), at: at(29, 12), calendar: calendar))
        #expect(tasks[0].archived == true && !tasks[0].done && tasks[0].completedAt == nil)
        let next = try #require(tasks.last)
        #expect(next.id != task.id && next.plannedStart == at(30, 9) && next.reminder == at(30, 8))
        #expect(!TaskSkipping.skip(task.id, in: &tasks, scheduledStart: at(27, 9), at: at(29, 13), calendar: calendar))
    }

    @Test func surveyValidatesEvidenceAndRoundTrips() throws {
        func record(_ energy: Int, _ focus: Int?, _ notes: String) -> TaskSkipRecord {
            TaskSkipRecord(taskID: UUID(), title: "Draft", scheduledStart: at(29, 9), skippedAt: at(29, 9),
                           reason: .interrupted, energy: energy, focus: focus, notes: notes)
        }
        #expect(!record(-1, nil, "").isValid && !record(11, nil, "").isValid)
        #expect(!record(5, 11, "").isValid && !record(5, nil, String(repeating: "x", count: 501)).isValid)
        let other = TaskSkipRecord(taskID: UUID(), title: "Draft", scheduledStart: at(29, 9), skippedAt: at(29, 9),
                                   reason: .other, energy: 3, notes: "  ")
        #expect(!other.isValid)
        let valid = record(0, 10, "  Doorbell  ")
        #expect(valid.isValid && valid.notes == "Doorbell")
        let restored = try JSONDecoder().decode(TaskSkipRecord.self, from: JSONEncoder().encode(valid))
        #expect(restored == valid)
    }
}
