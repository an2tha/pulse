import Foundation
import PulseEngine
import Testing
@testable import Pulse

@Suite @MainActor struct TimeBlockWorkspaceTests {
    private var reference: Date { Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: .now)! }
    private func rule(_ kind: WeeklyTimeBlock.Kind, start: Int, end: Int) -> WeeklyTimeBlock {
        WeeklyTimeBlock(kind: kind, title: "Test window", hours: TaskAvailability(weekdays: Set(1...7), startMinute: start, endMinute: end)!)
    }

    @Test func protectedTimeStopsOpenSprintAndResumeAcrossPersistence() throws {
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        store.journal.starterAvailable = false
        store.journal.timeBlocks = [rule(.protected, start: 660, end: 720)]
        #expect(!store.startOpenSprint(at: reference))
        #expect(store.startOpenSprint(at: reference.addingTimeInterval(-100)))
        #expect(store.journal.active?.target == 60)
        store.journal.active?.pause(now: reference.addingTimeInterval(-90), tick: 0, boot: nil)
        let restored = try JournalArchive.readDatabase(JournalArchive.database(store.journal))
        #expect(restored.timeBlocks == store.journal.timeBlocks)
        store.journal = restored
        store.toggleTimer(at: reference)
        #expect(store.journal.active?.wallAnchor == nil)
        #expect(try JournalArchive.decodeBackup(JournalArchive.backup(restored)).timeBlocks == restored.timeBlocks)
    }

    @Test func editsClampOnlyRemainingTimeAndAnOpenSprintCanUseDedicatedFocus() {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.starterAvailable = false
        store.journal.timeBlocks = [rule(.focus, start: 660, end: 720)]
        #expect(store.startOpenSprint(at: reference))
        var session = ActiveSession(openSprintSeconds: 120, now: reference, tick: 0, boot: "test")
        store.journal.active = session
        store.journal.timeBlocks = [rule(.protected, start: 661, end: 720)]
        #expect(store.shortenFocusForCommitments(at: reference.addingTimeInterval(10), tick: 10, boot: "test"))
        #expect(store.journal.active?.target == 60 && store.journal.active?.sessionID == session.sessionID)
        let errand = PlanTask("Buy paper", minutes: 5, category: .personal)
        store.journal.tasks = [errand]
        session = ActiveSession(task: errand, minutes: 5, now: reference, tick: 0, boot: "test")
        store.journal.active = session
        store.journal.timeBlocks = [rule(.focus, start: 661, end: 720)]
        #expect(store.shortenFocusForCommitments(at: reference.addingTimeInterval(20), tick: 20, boot: "test"))
        #expect(store.journal.active?.target == 60)
    }
}
