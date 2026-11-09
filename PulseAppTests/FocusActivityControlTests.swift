import Foundation
import PulseEngine
import Testing

@testable import Pulse

@Suite @MainActor struct FocusActivityControlTests {
    @Test func onlyTheCurrentControlCanChangeTheClock() throws {
        let start = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now))
        let store = Workspace()
        store.ready = true
        var prefs = ReminderPreferences()
        prefs.liveTimer = true
        store.journal.reminderPreferences = prefs
        let task = PlanTask("Private title", minutes: 20)
        store.journal.tasks = [task]
        let active = ActiveSession(task: task, minutes: 4, now: start, tick: 0, boot: "test")
        store.journal.active = active
        let id = SurfaceData.focusID(task: task.id, started: start)
        let running = try #require(active.timerRevision)
        let pause = start.addingTimeInterval(30)
        #expect(store.applyFocusControl(session: id, revision: running, resuming: false, at: pause))
        let paused = try #require(store.journal.active?.timerRevision)
        #expect(!store.applyFocusControl(session: id, revision: running, resuming: false, at: pause))
        #expect(!store.applyFocusControl(session: "different", revision: paused, resuming: true, at: pause))
        let resume = start.addingTimeInterval(40)
        store.journal.events = [Commitment("Busy", start: pause, end: resume)]
        #expect(!store.applyFocusControl(session: id, revision: paused, resuming: true, at: pause))
        #expect(store.applyFocusControl(session: id, revision: paused, resuming: true, at: resume))
        #expect(!store.applyFocusControl(session: id, revision: running, resuming: false, at: resume))
        let resumed = try #require(store.journal.active?.timerRevision)
        #expect(store.applyFocusControl(session: id, revision: resumed, resuming: false, at: resume))
        #expect(!store.applyFocusControl(session: id, revision: paused, resuming: true, at: resume))
        let latest = try #require(store.journal.active?.timerRevision)
        prefs.liveTimer = false
        store.journal.reminderPreferences = prefs
        #expect(!store.applyFocusControl(session: id, revision: latest, resuming: true, at: resume))
        #expect(store.journal.active?.sessionID == active.sessionID)
    }

    @Test func expiredAndReplacedActivitiesCannotPauseAnotherSprint() throws {
        let start = Date.now.addingTimeInterval(-300)
        let store = Workspace()
        store.ready = true
        var prefs = ReminderPreferences()
        prefs.liveTimer = true
        store.journal.reminderPreferences = prefs
        let expired = ActiveSession(openSprintSeconds: 120, now: start, tick: 0, boot: "test")
        let stale = SurfaceData.focusID(task: expired.taskID, started: start)
        let revision = try #require(expired.timerRevision)
        store.journal.active = expired
        #expect(!store.applyFocusControl(session: stale, revision: revision, resuming: false))
        let fresh = ActiveSession(openSprintSeconds: 120, now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
        store.journal.active = fresh
        #expect(!store.applyFocusControl(session: stale, revision: revision, resuming: false))
        #expect(store.journal.active == fresh)
    }
}
