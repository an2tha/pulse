import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor struct CommitmentPreparationTests {
    private func workspace(event: Commitment) -> Workspace {
        let store = Workspace()
        store.isDemo = true
        store.journal.events = [event]
        store.journal.starterAvailable = true
        store.ready = true
        return store
    }

    @Test func oneTapAddsOnlyOnePrepTaskAndUndoRestoresTheEmptyJournal() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now))
        let event = Commitment("Studio", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800))
        let store = workspace(event: event)
        let plan = Planner.schedule(at: now, tasks: [], commitments: [event], reports: [], dailyLimit: 30)
        let block = try #require(plan.first)
        let link = try #require(store.preparationLink(for: block, at: now))
        let prep = try #require(store.addPreparation(for: link, at: now))
        let same = store.addPreparation(for: link, at: now)
        #expect(same?.id == prep.id && store.journal.tasks.count == 1 && !store.journal.starterAvailable)
        #expect(prep.minutes == 10 && !prep.isInboxOnly && prep.due == nil)
        store.journal.tasks[0].notes = "Bring the sample"
        #expect(!store.undoAddedPreparation(prep))
        store.journal.tasks[0].notes = nil
        #expect(store.undoAddedPreparation(prep))
        #expect(store.journal.tasks.isEmpty && store.offeredTasks.isEmpty)
    }

    @Test func attachingAnInboxThoughtKeepsItsIdentityAndUndoRestoresItsHold() throws {
        let date = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now))
        let event = Commitment("Workshop visit", start: date.addingTimeInterval(3600), end: date.addingTimeInterval(7200))
        let store = workspace(event: event)
        let blocks = Planner.schedule(at: date, tasks: [], commitments: [event], reports: [], dailyLimit: 60)
        let block = try #require(blocks.first)
        let link = try #require(store.preparationLink(for: block, at: date))
        let generated = try #require(store.addPreparation(for: link, at: date))
        var thought = PlanTask("Bring the samples", minutes: 4)
        thought.inboxOnly = true
        thought.capturedDuringSessionID = UUID()
        thought.steps = [TaskStep("Find the blue sample")]
        store.journal.tasks.append(thought)
        let receipt = try #require(store.attachPreparation(taskID: thought.id, to: link, at: date))
        #expect(store.preparationTasks(for: link).map(\.id) == [generated.id, thought.id])
        #expect(store.attachPreparation(taskID: thought.id, to: link, at: date) == nil)
        #expect(store.journal.tasks[1].capturedDuringSessionID == thought.capturedDuringSessionID && !store.journal.tasks[1].isInboxOnly)
        store.journal.tasks[1].notes = "Bottom drawer"
        #expect(store.undoPreparationAttachment(receipt))
        #expect(store.journal.tasks[1].isInboxOnly && store.journal.tasks[1].preparation == nil)
        #expect(store.journal.tasks[1].notes == "Bottom drawer" && store.journal.tasks[1].steps == thought.steps)
        #expect(!store.undoPreparationAttachment(receipt))
    }

    @Test func aMovedAppointmentShortensRunningPrepWithoutRemovingEarnedTime() throws {
        let clock = try #require(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now))
        var event = Commitment("Studio", start: clock.addingTimeInterval(3600), end: clock.addingTimeInterval(7200))
        let store = workspace(event: event)
        let plan = Planner.schedule(at: clock, tasks: [], commitments: [event], reports: [], dailyLimit: 60)
        let block = try #require(plan.first)
        let link = try #require(store.preparationLink(for: block, at: clock))
        let prep = try #require(store.addPreparation(for: link, minutes: 20, at: clock))
        store.journal.active = ActiveSession(task: prep, minutes: 20, now: clock, tick: 1, boot: "fixture")
        store.journal.bufferMinutes = 2
        event.start = clock.addingTimeInterval(300)
        store.journal.events[0] = event
        let changed = store.shortenFocusForCommitments(at: clock.addingTimeInterval(80), tick: 81, boot: "fixture")
        #expect(changed && store.journal.active?.target == 180)
        event.start = clock.addingTimeInterval(3600)
        store.journal.events[0] = event
        #expect(!store.shortenFocusForCommitments(at: clock.addingTimeInterval(90), tick: 91, boot: "fixture"))
        event.start = clock.addingTimeInterval(30)
        store.journal.events[0] = event
        let stopped = store.shortenFocusForCommitments(at: clock.addingTimeInterval(100), tick: 101, boot: "fixture")
        #expect(stopped && store.journal.active?.target == 100)
        #expect(store.journal.active?.elapsed(now: clock.addingTimeInterval(600), tick: 601, boot: "fixture") == 100)
    }

    @Test func movedLocalCommitmentPersistsAndOlderSyncCannotEraseTheLink() throws {
        let day = Calendar.current.startOfDay(for: .now)
        let start = day.addingTimeInterval(36000)
        let clock = start.addingTimeInterval(-120)
        let appointment = Commitment("Studio", start: start, end: start.addingTimeInterval(1800))
        let store = workspace(event: appointment)
        let plan = Planner.schedule(at: clock, tasks: [], commitments: [appointment], reports: [], dailyLimit: 30)
        let block = try #require(plan.first)
        let link = try #require(store.preparationLink(for: block, at: clock))
        let created = try #require(store.addPreparation(for: link, at: clock))
        var moved = appointment
        moved.start = start.addingTimeInterval(3600)
        moved.end = moved.start.addingTimeInterval(1800)
        store.change { $0.events[0] = moved }
        #expect(store.preparationTask(for: link)?.preparation?.lastKnownStart == moved.start)
        store.change { $0.events.removeAll() }
        let backup = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        let stored = try #require(backup.tasks[0].preparation)
        #expect(stored.resolvedStart(in: []) == nil && stored.lastKnownStart == moved.start)
        var unlinked = backup
        unlinked.tasks[0].preparation = nil
        let explicit = SharedJournal(unlinked)
        #expect(try explicit.applying(to: backup).tasks[0].preparation == nil)
        var oldPayload = try #require(JSONSerialization.jsonObject(with: explicit.encoded()) as? [String: Any])
        oldPayload["fieldVersion"] = 3
        let legacy = try JSONDecoder().decode(SharedJournal.self, from: JSONSerialization.data(withJSONObject: oldPayload))
        let merged = try legacy.applying(to: backup)
        #expect(merged.tasks[0].id == created.id && merged.tasks[0].preparation == stored)
    }
}
