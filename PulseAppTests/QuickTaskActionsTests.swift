import Foundation
import PulseEngine
import Testing
@testable import Pulse

@Suite @MainActor struct QuickTaskActionsTests {
    private func workspace(_ tasks: [PlanTask]) -> Workspace {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.tasks = tasks
        store.journal.limit = 90
        return store
    }

    private var clock: Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date.now)!
    }
    @Test func startSelectedHeldTaskAndKeepPartialWorkInInbox() async {
        let other = PlanTask("Another task", minutes: 15)
        var selected = PlanTask("Selected thought", minutes: 25)
        selected.inboxOnly = true
        let store = workspace([other, selected])
        #expect(await store.quickStartTask(selected.id, at: clock))
        #expect(store.journal.active?.taskID == selected.id)
        #expect(store.journal.active?.title == selected.title)
        #expect(store.journal.tasks[1].isInboxOnly)
        #expect(store.journal.tasks[1].plannedStart == nil)
        #expect(await store.quickStartTask(selected.id, at: clock))
        #expect(await !store.quickStartTask(other.id, at: clock))
        store.finish(done: false)
        #expect(store.journal.tasks[1].isInboxOnly)
    }

    @Test func unavailableSelectedTaskDoesNotChangeTimingOrStartAnother() async {
        var held = PlanTask("Held thought", minutes: 10)
        held.inboxOnly = true
        var pinned = PlanTask("Reserved work", minutes: 10)
        pinned.plannedStart = clock
        let store = workspace([held, pinned])
        #expect(await !store.quickStartTask(held.id, at: clock))
        #expect(store.journal.active == nil && store.journal.tasks[0] == held)
        store.journal.tasks = [held]
        store.journal.timeBlocks = [WeeklyTimeBlock(kind: .protected,
            hours: TaskAvailability(weekdays: Set(1...7), startMinute: 590, endMinute: 630)!)]
        #expect(await !store.quickStartTask(held.id, at: clock))
        #expect(store.journal.active == nil && store.journal.tasks == [held])
        store.journal.timeBlocks = []
        held.dependency = pinned.id
        store.journal.tasks = [held, pinned]
        #expect(await !store.quickStartTask(held.id, at: clock))
        #expect(store.notice?.contains(pinned.title) == true)
    }

    @Test func deletionProtectsActiveTaskAndReleasesOnlyItsReferences() async {
        let first = PlanTask("Remove", minutes: 5)
        var second = PlanTask("Follow", minutes: 5)
        second.dependency = first.id
        let store = workspace([first, second])
        store.journal.nextTaskID = first.id
        store.journal.taskOrder = [second.id, first.id]
        let photo = JournalPhoto(taskID: first.id, title: first.title, completion: false, jpeg: Data([1]))
        store.journal.photos = [photo]
        #expect(!store.deleteTask(first, in: UUID()))
        #expect(await store.quickStartTask(first.id, at: clock))
        #expect(!store.deleteTask(first, in: store.journalEpoch))
        store.finish(done: false)
        let history = store.journal.sessions
        let current = store.journal.tasks[0]
        store.journal.nextTaskID = current.id
        #expect(store.deleteTask(current, in: store.journalEpoch))
        #expect(store.journal.tasks.map(\.id) == [second.id])
        #expect(store.journal.tasks[0].dependency == nil && store.journal.nextTaskID == nil)
        #expect(store.journal.taskOrder == [second.id])
        #expect(store.journal.photos == [photo] && store.journal.sessions == history)
    }
}
