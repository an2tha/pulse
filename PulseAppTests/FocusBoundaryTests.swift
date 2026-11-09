import Foundation
import PulseEngine
import Testing
import UserNotifications

@testable import Pulse

@Suite @MainActor struct FocusBoundaryTests {
    @Test(arguments: [false, true])
    func aChangedFixedEventLimitsOnlyRemainingWork(openSprint: Bool) throws {
        let clock = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now))
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        let task = PlanTask("Study", minutes: 12)
        store.journal.tasks = openSprint ? [] : [task]
        let session = openSprint
            ? ActiveSession(openSprintSeconds: 120, now: clock, tick: 0, boot: "test")
            : ActiveSession(task: task, minutes: 5, now: clock, tick: 0, boot: "test")
        store.journal.active = session
        store.journal.bufferMinutes = 1
        let energy = try #require(EnergyExpectation(at: clock, scope: .hour, score: 0))
        store.journal.energyExpectations = [energy]
        #expect(!store.shortenFocusForCommitments(at: clock.addingTimeInterval(10), tick: 10, boot: "test"))

        // A fixed event 100 seconds after the start protects its 60-second approach.
        store.journal.events = [Commitment("Meet", start: clock.addingTimeInterval(100), end: clock.addingTimeInterval(500))]
        #expect(store.shortenFocusForCommitments(at: clock.addingTimeInterval(15), tick: 15, boot: "test"))
        let shortened = try #require(store.journal.active)
        #expect(shortened.target == 40 && shortened.sessionID == session.sessionID && shortened.wallAnchor == session.wallAnchor)
        store.journal.events = []
        #expect(!store.shortenFocusForCommitments(at: clock.addingTimeInterval(20), tick: 20, boot: "test"))
        #expect(store.journal.active == shortened)

        store.journal.events = [Commitment("Now busy", start: clock.addingTimeInterval(55), end: clock.addingTimeInterval(600))]
        #expect(store.shortenFocusForCommitments(at: clock.addingTimeInterval(25), tick: 25, boot: "test"))
        let ended = try #require(store.journal.active)
        #expect(ended.target == 25 && ended.sessionID == session.sessionID && store.journal.sessions.isEmpty)
        #expect(ended.record(now: clock.addingTimeInterval(2000), tick: 2000, boot: "test").seconds == 25)
    }

    @Test func editingALocalAppointmentImmediatelyUpdatesARunningSprint() throws {
        let now = Date.now
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        let active = ActiveSession(openSprintSeconds: 120, now: now.addingTimeInterval(-10),
                                   tick: SessionClock.tick - 10, boot: SessionClock.boot)
        store.journal.active = active
        store.change { $0.events = [Commitment("Call", start: now.addingTimeInterval(30), end: now.addingTimeInterval(210))] }
        let updated = try #require(store.journal.active)
        #expect(abs(updated.target - 40) < 0.25 && updated.sessionID == active.sessionID)
        store.change { $0.events.removeAll() }
        #expect(store.journal.active == updated)
    }

    @Test func aPausedOpenSprintRechecksBusyTimeBeforeResuming() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now))
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.starterAvailable = false
        var active = ActiveSession(openSprintSeconds: 120, now: now, tick: 0, boot: "test")
        active.pause(now: now.addingTimeInterval(14), tick: 14, boot: "test")
        store.journal.active = active
        store.journal.events = [Commitment("Call", start: now.addingTimeInterval(70), end: now.addingTimeInterval(300))]
        #expect(!store.shortenFocusForCommitments(at: now.addingTimeInterval(20), tick: 20, boot: "test"))
        store.toggleTimer(at: now.addingTimeInterval(80))
        #expect(store.journal.active == active)
        store.toggleTimer(at: now.addingTimeInterval(40))
        #expect(store.journal.active?.sessionID == active.sessionID && store.journal.active?.target == 44)
    }

    @Test func reconnectingTheSameCalendarDoesNotReactivateItsOldSnapshot() throws {
        let suite = "pulse.boundary-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = LiveCalendarSelection(defaults: defaults)
        let store = Workspace(liveCalendar: selection)
        let now = Date.now
        selection.source = "route"
        let old = Commitment("Old", start: now, end: now.addingTimeInterval(600))
        store.replaceCalendarEvents([old], source: "route")
        #expect(store.hasCurrentCalendarSnapshot)
        selection.source = nil
        selection.source = "route"
        #expect(!store.hasCurrentCalendarSnapshot && store.planningEvents.isEmpty)
        store.replaceCalendarEvents([], source: "route")
        let active = ActiveSession(openSprintSeconds: 120, now: now, tick: SessionClock.tick, boot: SessionClock.boot)
        store.journal.active = active
        store.ready = true
        store.replaceCalendarEvents([old], source: "discarded")
        #expect(store.hasCurrentCalendarSnapshot && store.calendarEvents.isEmpty && store.journal.active == active)
    }

    @Test func aShortenedFocusDoesNotKeepItsOriginalFutureNotification() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var prefs = ReminderPreferences()
        prefs.quietHours = false
        let timer = SurfaceTimer(task: UUID(), started: now.addingTimeInterval(-20), title: "Focus",
                                 secondsLeft: 0, deadline: nil)
        let content = UNMutableNotificationContent()
        content.userInfo = ["task": timer.task.uuidString, "started": timer.started.timeIntervalSince1970]
        let due = PlanningNotifications.oneTime(FocusReminder.id, content, at: now)
        let old = PlanningNotifications.oneTime(FocusReminder.id, content, at: now.addingTimeInterval(100))
        #expect(PlanningNotifications.isDueFocusAlert(due, timer: timer, now: now, preferences: prefs))
        #expect(!PlanningNotifications.isDueFocusAlert(old, timer: timer, now: now, preferences: prefs))
    }

    @Test func extendingAnExpiredSprintExcludesDecisionTimeAndProtectsTheNextPin() throws {
        let start = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now))
        let choice = start.addingTimeInterval(420)
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        let task = PlanTask("Draw", minutes: 20)
        var next = PlanTask("Read", minutes: 10)
        next.plannedStart = choice.addingTimeInterval(45)
        store.journal.tasks = [task, next]
        var session = ActiveSession(task: task, minutes: 2, now: start, tick: 0, boot: "fixture")
        session.stepID = UUID()
        store.journal.active = session
        store.extendSprint(at: choice)
        let extended = try #require(store.journal.active)
        #expect(extended.target == 165 && extended.accumulated == 120)
        #expect(extended.wallAnchor == choice && extended.stepID == session.stepID)
        let record = extended.record(now: choice.addingTimeInterval(45), tick: 0, boot: "fixture")
        #expect(record.seconds == 165 && record.periods?.count == 2)
        store.extendSprint(at: choice)
        #expect(store.journal.active == extended)
    }

    @Test func resumeClipsToTheNewCommitmentAndWrapUp() throws {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        let task = PlanTask("Read", minutes: 15)
        store.journal.tasks = [task]
        var paused = ActiveSession(task: task, minutes: 10, now: date, tick: 1, boot: "test")
        paused.pause(now: date.addingTimeInterval(30), tick: 31, boot: "test")
        let next = date.addingTimeInterval(120)
        store.journal.active = paused
        store.journal.events = [Commitment("Call", start: next, end: next.addingTimeInterval(100))]
        store.toggleTimer(at: next)
        #expect(store.journal.active == paused)
        store.toggleTimer(at: next.addingTimeInterval(-12))
        #expect(store.journal.active?.target == 42 && store.journal.active?.wallAnchor != nil)

        store.journal.active = paused
        store.journal.events = []
        store.journal.wrapUpMinute = 12 * 60 + 2
        store.toggleTimer(at: next.addingTimeInterval(-8))
        #expect(store.journal.active?.target == 38)
    }

    @Test func resumingProtectsActionablePinsAndIgnoresAMissedReservation() throws {
        let at = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now))
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        let task = PlanTask("Draw", minutes: 20)
        var reserved = PlanTask("Review notes", minutes: 120)
        reserved.plannedStart = at.addingTimeInterval(40)
        var missed = PlanTask("Morning reading", minutes: 120)
        missed.plannedStart = at.addingTimeInterval(-3600)
        store.journal.tasks = [task, reserved, missed]
        var active = ActiveSession(task: task, minutes: 5, now: at.addingTimeInterval(-30), tick: 0, boot: "fixture")
        active.pause(now: at, tick: 30, boot: "fixture")
        store.journal.active = active
        store.toggleTimer(at: at)
        #expect(store.journal.active?.target == 70)
        store.journal.active = active
        store.toggleTimer(at: at.addingTimeInterval(40))
        #expect(store.journal.active == active)
        store.journal.tasks[1].dependency = task.id
        store.toggleTimer(at: at.addingTimeInterval(40))
        #expect(store.journal.active?.target == 300 && store.journal.active?.wallAnchor != nil)
    }

    @Test func aSprintCanResumeOnlyWithinItsTasksAvailableHours() throws {
        let calendar = Calendar.current
        let opens = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now))
        var task = PlanTask("Call the shop", minutes: 15)
        let hours = try #require(TaskAvailability(weekdays: [calendar.component(.weekday, from: opens)],
                                                  startMinute: 720, endMinute: 721))
        task.availability = hours
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        store.journal.tasks = [task]
        var paused = ActiveSession(task: task, minutes: 5, now: opens.addingTimeInterval(-3600), tick: 0, boot: "fixture")
        paused.pause(now: opens.addingTimeInterval(-3570), tick: 30, boot: "fixture")
        store.journal.active = paused
        store.toggleTimer(at: opens.addingTimeInterval(-1))
        #expect(store.journal.active == paused)
        store.toggleTimer(at: opens.addingTimeInterval(45))
        #expect(store.journal.active?.target == 45)
        store.journal.active = paused
        store.toggleTimer(at: opens.addingTimeInterval(60))
        #expect(store.journal.active == paused)
    }

    @Test func midnightResumeCountsOnlyTodaysFocusPeriods() throws {
        let midnight = Calendar.current.startOfDay(for: .now)
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        store.journal.limit = 1
        let task = PlanTask("Read", minutes: 5)
        store.journal.tasks = [task]
        var paused = ActiveSession(task: task, minutes: 4, now: midnight.addingTimeInterval(-20), tick: 1, boot: "test")
        paused.pause(now: midnight.addingTimeInterval(10), tick: 31, boot: "test")
        store.journal.active = paused
        store.toggleTimer(at: midnight.addingTimeInterval(60))
        #expect(store.journal.active?.target == 80)
        store.journal.active = paused
        store.journal.sessions = [SessionRecord(taskID: task.id, title: task.title, start: midnight, seconds: 51)]
        store.toggleTimer(at: midnight.addingTimeInterval(60))
        #expect(store.journal.active == paused)
    }

    @Test func originalQuietTimeIsDeferredEvenWithoutAPreviousRequest() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let night = cal.date(byAdding: .day, value: -1, to: today)!
        let original = cal.date(bySettingHour: 22, minute: 0, second: 0, of: night)!
        let sunrise = cal.date(bySettingHour: 8, minute: 0, second: 0, of: today)!
        let early = cal.date(bySettingHour: 6, minute: 0, second: 0, of: today)!
        let alert = TaskAlert(id: UUID(), title: "Task", date: original, explicit: true)
        var preferences = ReminderPreferences()
        #expect(alert.nextDate(after: early, heldUntil: nil, preferences: preferences) == sunrise)
        preferences.quietEnd = 7 * 60
        #expect(alert.nextDate(after: early, heldUntil: sunrise, preferences: preferences) == sunrise.addingTimeInterval(-3600))
        #expect(alert.nextDate(after: sunrise, heldUntil: nil, preferences: preferences) == nil)
    }

    @Test func fallBackReminderCanSelectEitherOccurrence() throws {
        let formatter = ISO8601DateFormatter()
        let first = try #require(formatter.date(from: "2027-10-31T02:15:00+02:00"))
        let second = first.addingTimeInterval(3600)
        for date in [first, second] {
            let request = PlanningNotifications.oneTime("test", UNMutableNotificationContent(), at: date)
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            let components = trigger.dateComponents
            #expect(components.date == date)
            #expect(components.timeZone?.secondsFromGMT(for: date) == 0)
        }
    }

    @Test func staleOrDisabledReminderCannotChangeATask() throws {
        let store = Workspace()
        store.ready = true
        let time = Date.now.addingTimeInterval(-60)
        var item = PlanTask("Read", minutes: 8)
        item.due = time
        var prefs = ReminderPreferences()
        prefs.enabled = true
        prefs.taskAlerts = true
        store.journal.reminderPreferences = prefs
        store.journal.tasks = [item]
        #expect(store.taskForReminder(item.id, original: time.timeIntervalSince1970) == item)
        store.journal.tasks[0].after = time.addingTimeInterval(30)
        store.snoozeSystemReminder(item.id, original: time.timeIntervalSince1970)
        #expect(store.journal.tasks[0].reminder == nil)
        store.journal.tasks[0].after = nil
        store.journal.reminderPreferences?.enabled = false
        store.snoozeSystemReminder(item.id, original: time.timeIntervalSince1970)
        #expect(store.journal.tasks[0].reminder == nil)
        store.journal.reminderPreferences?.enabled = true
        store.journal.tasks[0].done = true
        #expect(store.taskForReminder(item.id, original: time.timeIntervalSince1970) == nil)
    }
}
