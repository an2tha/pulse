import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor struct TaskSkipFlowTests {
    @Test func runningTaskRequiresValidSurveyAndRecordsProgressExactlyOnce() throws {
        let now = Date.now
        var task = PlanTask("Draft", minutes: 10)
        task.plannedStart = now.addingTimeInterval(-180)
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.tasks = [task]
        store.journal.active = ActiveSession(task: task, minutes: 10, now: now.addingTimeInterval(-120), tick: 0, boot: nil)
        let candidate = try #require(store.skipCandidate(for: task.id, at: now))
        #expect(throws: TaskSkipError.self) { try store.skipTask(candidate, reason: .other, energy: 3, notes: " ", at: now) }
        #expect(store.journal.active != nil && store.journal.sessions.isEmpty && store.journal.taskSkips == nil)
        try store.skipTask(candidate, reason: .interrupted, energy: 3, focus: 4, at: now)
        #expect(store.journal.active == nil && store.journal.sessions.count == 1 && store.journal.taskSkips?.count == 1)
        #expect(store.journal.sessions[0].seconds == 120 && store.journal.sessions[0].completedTask == false)
        #expect(store.journal.tasks[0].minutes == 8 && !store.journal.tasks[0].done)
        #expect(throws: TaskSkipError.self) { try store.skipTask(candidate, reason: .lowEnergy, energy: 4, at: now) }
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        #expect(restored.taskSkips?.first?.focus == 4 && restored.taskSkips?.first?.taskID == task.id)
    }

    @Test func changedSessionInvalidatesSurveyAndPausedTaskCanThenBeSkipped() throws {
        let now = Date.now
        let task = PlanTask("Practice", minutes: 10)
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.tasks = [task]
        store.journal.active = ActiveSession(task: task, minutes: 10, now: now.addingTimeInterval(-90), tick: 0, boot: nil)
        let beforePause = try #require(store.skipCandidate(for: task.id, at: now))
        store.journal.active?.pause(now: now, tick: 90, boot: nil)
        #expect(throws: TaskSkipError.self) { try store.skipTask(beforePause, reason: .unwell, energy: 1, at: now) }
        #expect(store.journal.sessions.isEmpty && store.journal.taskSkips == nil)
        let paused = try #require(store.skipCandidate(for: task.id, at: now))
        try store.skipTask(paused, reason: .unwell, energy: 1, at: now.addingTimeInterval(60))
        #expect(store.journal.sessions[0].seconds == 90 && store.journal.tasks[0].remainingSeconds == 510)
        store.journal.active = ActiveSession(openSprintSeconds: 120, now: now, tick: 0, boot: nil)
        #expect(store.skipCandidate(for: store.journal.active!.taskID, at: now) == nil)
    }
}
