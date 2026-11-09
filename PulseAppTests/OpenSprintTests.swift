import Foundation
import PulseEngine
import Testing
@testable import Pulse

@Suite @MainActor struct OpenSprintTests {
    private var morning: Date { Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now)! }

    private func workspace(tasks: [PlanTask] = []) async -> Workspace {
        let store = Workspace()
        store.isDemo = true
        store.journal.starterAvailable = false
        store.journal.tasks = tasks
        store.ready = true
        store.now = morning
        await store.waitForCurrentPlan()
        return store
    }

    @Test func heldThoughtsStayHeldWhileTheSprintAndItsCapturesSurviveRestoration() async throws {
        var thought = PlanTask("An idea for later", minutes: 10)
        thought.inboxOnly = true
        let store = await workspace(tasks: [thought])
        #expect(store.openSprintSeconds(at: morning) == 120)
        #expect(store.startSmall(at: morning))
        let session = try #require(store.journal.active)
        #expect(session.isOpenSprint && session.target == 120 && session.sessionID == session.taskID)
        #expect(store.journal.tasks == [thought] && store.journal.nextTaskID == nil && !store.startOpenSprint(at: morning))
        let id = try #require(session.sessionID)
        store.captureDrafts.setText("Unfinished thought", for: .sprint(id))
        store.flushCaptureDrafts()
        let next = PlanTask("Remember the charger", minutes: 3)
        #expect(store.captureTask(next, focusSession: session, distraction: true) == next.id)
        var restored = try JournalArchive.readDatabase(JournalArchive.database(store.journal))
        #expect(restored.active?.sessionID == id && restored.active?.isOpenSprint == true)
        #expect(restored.captureDrafts?.text(for: .sprint(id)) == "Unfinished thought")
        let backup = try JournalArchive.decodeBackup(JournalArchive.backup(restored))
        #expect(backup.active?.isOpenSprint == true && backup.active?.wallAnchor == nil)
        #expect(backup.tasks.last?.isInboxOnly == true && backup.tasks.last?.capturedDuringSessionID == id)
        restored.active?.pause(now: morning.addingTimeInterval(30), tick: 0, boot: nil)
        store.journal = restored
        store.toggleTimer(at: morning.addingTimeInterval(31))
        #expect(store.journal.active?.wallAnchor != nil)
        store.finish(done: true)
        let record = try #require(store.journal.sessions.last)
        #expect(record.id == id && record.isOpenSprint && record.completedTask == nil)
        #expect(record.seconds >= 30 && store.journal.tasks.count == 2 && store.journal.tasks.allSatisfy { !$0.done })
        #expect(store.journal.nextTaskID == nil && store.journal.active == nil)
    }

    @Test func versionFivePrivateSyncRetainsHistoryWithoutCreatingTaskCompletions() throws {
        let active = ActiveSession(openSprintSeconds: 120, now: morning, tick: 0, boot: "test")
        let record = active.record(now: morning.addingTimeInterval(90), tick: 90, boot: "test", completed: true)
        let normalTask = PlanTask("Task with history", minutes: 2)
        let ordinary = SessionRecord(taskID: normalTask.id, title: normalTask.title, start: morning, seconds: 30)
        var local = Journal()
        local.tasks = [normalTask]
        local.sessions = [record, ordinary]
        var payload = try #require(JSONSerialization.jsonObject(with: SharedJournal(local).encoded()) as? [String: Any])
        #expect(payload["fieldVersion"] as? Int == 6)
        payload["fieldVersion"] = 5
        var sessions = try #require(payload["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "openSprint")
        payload["sessions"] = sessions
        let peer = try JSONDecoder().decode(SharedJournal.self, from: JSONSerialization.data(withJSONObject: payload))
        for destination in [local, Journal()] {
            let restored = try peer.applying(to: destination)
            #expect(restored.sessions == [record, ordinary])
            #expect(!restored.sessions[1].isOpenSprint)
            let day = try #require(Calendar.current.dateInterval(of: .day, for: morning))
            #expect(restored.sessions.reduce(0) { $0 + $1.seconds(in: day) } == 120)
            #expect(restored.tasks.allSatisfy { !$0.done } && restored.sessions.allSatisfy { $0.completedTask == nil })
            let output = try #require(JSONSerialization.jsonObject(with: SharedJournal(restored).encoded()) as? [String: Any])
            let records = try #require(output["sessions"] as? [[String: Any]])
            #expect(records[0]["openSprint"] as? Bool == true && records[1]["openSprint"] == nil)
        }
    }

    @Test func startRechecksCommitmentsRecoveryDailyRoomAndFuturePins() async {
        let store = await workspace()
        let event = Commitment("Meeting", start: morning.addingTimeInterval(155), end: morning.addingTimeInterval(3600))
        store.journal.events = [event]
        store.journal.bufferMinutes = 1
        #expect(store.startOpenSprint(at: morning))
        #expect(store.journal.active?.target == 60)
        store.journal.active = nil
        #expect(!store.startOpenSprint(at: morning.addingTimeInterval(50)))
        store.journal.events = []
        store.journal.restDate = morning
        #expect(!store.startOpenSprint(at: morning))
        store.journal.restDate = nil
        store.journal.recovery = DateInterval(start: morning, duration: 60)
        #expect(!store.startOpenSprint(at: morning))
        store.journal.recovery = nil
        store.journal.limit = 5
        let regular = PlanTask("A real task", minutes: 5)
        store.journal.tasks = [regular]
        #expect(!store.startOpenSprint(at: morning))
        var future = regular
        future.plannedStart = morning.addingTimeInterval(3600)
        store.journal.tasks = [future]
        #expect(!store.startOpenSprint(at: morning))
        store.journal.limit = 6
        #expect(store.startOpenSprint(at: morning))
        #expect(store.journal.active?.target == 60)
        store.journal.active = nil
        store.journal.tasks = []
        store.journal.wrapUpMinute = 10 * 60 + 1
        #expect(!store.startOpenSprint(at: morning.addingTimeInterval(1)))
    }

    @Test func blockedWorkDoesNotReserveTimeAndThePreviewWaitsForPlanEdits() async {
        var waiting = PlanTask("Waiting on a reply", minutes: 5)
        waiting.dependency = UUID()
        var closed = PlanTask("Call when open", minutes: 5)
        closed.plannedStart = morning
        let weekday = Calendar.current.component(.weekday, from: morning)
        closed.availability = TaskAvailability(weekdays: [weekday], startMinute: 720, endMinute: 780)
        #expect(closed.availability != nil)
        let store = await workspace(tasks: [waiting, closed])
        #expect(store.openSprintSeconds(at: morning) == 120)
        store.change { $0.tasks.append(PlanTask("Ready now", minutes: 4)) }
        #expect(store.openSprintSeconds(at: morning) == 0)
        #expect(!store.startOpenSprint(at: morning))
        var unfinished = waiting
        unfinished.dependency = nil
        store.journal.tasks = [unfinished]
        store.journal.tuning = PlanTuning(date: morning)
        store.journal.tuning?.manualCapacity = 0
        #expect(!store.startOpenSprint(at: morning))
    }

    @Test func weekHoldsTheRemainingTimeAndExtensionRechecksFreshWork() async throws {
        let store = await workspace()
        #expect(store.startOpenSprint(at: morning))
        var active = try #require(store.journal.active)
        let held = try #require(DayScheduleInputs(journal: store.journal, events: [], tasks: [], at: morning,
                                                   active: active.record(now: morning, tick: 0, boot: nil)))
        #expect(held.used == 2 && held.tasks.isEmpty && held.events.first?.id == active.sessionID)
        active.pause(now: morning.addingTimeInterval(120), tick: 0, boot: nil)
        let end = morning.addingTimeInterval(120)
        store.journal.active = active
        store.now = end
        await store.waitForCurrentPlan()
        #expect(store.sprintExtensionSeconds(at: end) == 120)
        store.journal.tasks = [PlanTask("Time to work", minutes: 10)]
        store.extendSprint(at: end)
        #expect(store.journal.active?.target == 120 && store.journal.active?.wallAnchor == nil)
        store.journal.tasks = []
        store.journal.limit = 3
        store.now = end
        await store.waitForCurrentPlan()
        store.extendSprint(at: end)
        #expect(store.journal.active?.target == 180 && store.journal.active?.wallAnchor != nil)
    }
}
