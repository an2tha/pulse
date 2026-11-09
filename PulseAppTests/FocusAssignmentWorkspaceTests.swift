import Foundation
import PulseEngine
import Testing
@testable import Pulse

@Suite @MainActor struct FocusAssignmentWorkspaceTests {
    @Test func atomicAssignmentReplaysAndUndoReturnsTaskToInbox() async throws {
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        var task = PlanTask("Water the ivy", minutes: 5, category: .personal)
        task.inboxOnly = true
        store.journal.tasks = [task]
        let calendar = Calendar.current
        let day = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)))
        let bounds = try #require(calendar.dateInterval(of: .day, for: day))
        var rule = WeeklyTimeBlock(kind: .focus, hours: TaskAvailability(weekdays: Set(1...7), startMinute: 577, endMinute: 592)!)
        rule.setSingleDate(day)
        let target = try #require(rule.blocks(on: bounds).first)
        store.journal.events = [.init("Busy", start: target.start, end: target.end)]
        do {
            _ = try await store.assignTask(task.id, to: rule, on: day, creating: true)
            Issue.record("An occupied focus interval should be rejected.")
        } catch is FocusAssignmentError {}
        #expect(store.journal.tasks == [task])
        #expect(store.journal.timeBlocks?.contains(rule) != true)
        store.change { $0.events = [] }
        let start = try await store.assignTask(task.id, to: rule, on: day, creating: true).start
        #expect(start == target.start && store.journal.tasks[0].assignedFocusBlockID == rule.id)
        let restored = try JournalArchive.readDatabase(JournalArchive.database(store.journal))
        #expect(restored.tasks.first?.assignedFocusBlockID == rule.id)
        let receipt = try #require(store.undoableTimeMove(for: task.id))
        #expect(store.undoTimeMove(receipt))
        #expect(store.journal.tasks.first?.assignedFocusBlockID == nil && store.journal.tasks.first?.isInboxOnly == true)
        #expect(store.journal.timeBlocks == [rule])
        _ = try await store.assignTask(task.id, to: rule, on: day)
        store.change { $0.timeBlocks = [] }
        #expect(store.journal.tasks[0].assignedFocusBlockID == nil)
        #expect(store.journal.tasks[0].plannedStart == start)
    }
}
