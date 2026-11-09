import Foundation
import PulseEngine
import Testing

@testable import Pulse

struct RoutineExceptionJournalTests {
    @Test func savedOccurrenceSurvivesBackupAndOlderSyncRevisions() throws {
        let day = Date.now.addingTimeInterval(86_400 * 2)
        var owner = PlanTask("Write", minutes: 6)
        owner.repeated = .weekdays
        let key = RoutineOccurrence(seriesID: owner.id, rule: .weekdays, day: day, calendar: .current)
        let move = RoutineException(occurrence: key, start: Date(timeIntervalSince1970: floor(day.timeIntervalSince1970)))
        owner.setException(move, for: key)
        var journal = Journal()
        journal.tasks = [owner]
        let archive = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(archive.tasks.first?.routineExceptions == [move])
        let contents = try JSONDecoder().decode(SharedJournal.self, from: SharedJournal(journal).encoded())
        #expect(try contents.applying(to: Journal()).tasks.first?.routineExceptions == [move])
        var old = contents
        old.tasks[0].routineExceptions = nil
        #expect(try old.applying(to: journal).tasks.first?.routineExceptions == [move])
        old.tasks[0].routineExceptions = []
        #expect(try old.applying(to: journal).tasks.first?.routineExceptions == [])
        journal.tasks[0].routineExceptions = [move, move]
        #expect(throws: JournalArchive.Failure.invalid) { try JournalArchive.validate(journal) }
    }
}

extension RoutineExceptionJournalTests {
    @MainActor private func reopened(_ tasks: [PlanTask]) throws -> Workspace {
        var journal = Journal()
        journal.tasks = tasks
        let store = Workspace()
        store.isDemo = true
        store.journal = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(journal))
        store.ready = true
        return store
    }

    @Test @MainActor func releaseAfterReopeningKeepsTaskEditsAndUnrelatedUndo() throws {
        let start = Date.now.addingTimeInterval(3600)
        var task = PlanTask("Send drawings", minutes: 35)
        task.after = start.addingTimeInterval(-50)
        task.reminder = start.addingTimeInterval(-40)
        task.due = start.addingTimeInterval(400)
        task.plannedStart = start
        var other = PlanTask("Read", minutes: 5)
        let prior = other
        other.moveOccurrence(to: start)
        let store = try reopened([task, other])
        let receipt = try #require(TaskTimeMove(from: prior, to: other, sourceDay: start))
        store.lastTimeMove = receipt
        let pin = try #require(store.releasablePin(for: task.id))
        store.journal.tasks[0].plannedStart = start.addingTimeInterval(60)
        #expect(!store.releaseTimePin(pin))
        store.journal.tasks[0].plannedStart = start
        store.journal.active = ActiveSession(task: task, minutes: 1, now: start, tick: 1, boot: "test")
        #expect(store.releasablePin(for: task.id) == nil && !store.releaseTimePin(pin))
        store.journal.active = nil
        store.journal.tasks[0].notes = "Use the revised scan"
        #expect(store.releaseTimePin(pin))
        task.notes = "Use the revised scan"
        task.plannedStart = nil
        #expect(store.journal.tasks[0] == task)
        #expect(store.lastTimeMove == receipt && !store.releaseTimePin(pin))
        let otherPin = try #require(store.releasablePin(for: other.id))
        #expect(store.releaseTimePin(otherPin) && store.lastTimeMove == nil)
    }

    @Test @MainActor func releasedRoutineRegainsItsTimeAndKeepsIndependentReminder() throws {
        let now = Date.now
        var task = PlanTask("Take a walk", minutes: 10)
        task.repeated = .weekly
        task.plannedStart = now
        task.reminder = now.addingTimeInterval(-600)
        let store = try reopened([task])
        #expect(store.releasablePin(for: task.id) == nil)
        store.journal.tasks[0].moveOccurrence(to: now.addingTimeInterval(3600))
        let pin = try #require(store.releasablePin(for: task.id))
        store.journal.tasks[0].plannedStart = now.addingTimeInterval(7200)
        #expect(store.releasablePin(for: task.id) == nil && !store.releaseTimePin(pin))
        store.journal.tasks[0].plannedStart = pin.start
        #expect(store.releaseTimePin(pin))
        #expect(store.journal.tasks[0].plannedStart == now && store.journal.tasks[0].reminder == task.reminder)
        #expect(store.journal.tasks[0].routineAnchor == now && store.releasablePin(for: task.id) == nil)
    }

    @Test @MainActor func releaseProjectedPinWithoutCachedProjectionOnlyRemovesOneException() throws {
        let calendar = Calendar.current
        let now = Date.now
        var owner = PlanTask("Weekly review", minutes: 10)
        owner.repeated = .weekly
        owner.plannedStart = now
        let one = try #require(calendar.date(byAdding: .day, value: 7, to: now))
        let two = try #require(calendar.date(byAdding: .day, value: 14, to: now))
        let a = RoutineOccurrence(seriesID: owner.id, rule: .weekly, day: one, calendar: calendar)
        let b = RoutineOccurrence(seriesID: owner.id, rule: .weekly, day: two, calendar: calendar)
        let second = RoutineException(occurrence: b, start: two.addingTimeInterval(1800))
        owner.setException(.init(occurrence: a, start: one.addingTimeInterval(3600)), for: a)
        owner.setException(second, for: b)
        let store = try reopened([owner])
        let pin = try #require(store.releasablePin(for: a.id))
        #expect(store.releaseTimePin(pin))
        #expect(store.journal.tasks[0].routineExceptions == [second])
        #expect(store.journal.tasks[0].plannedStart == now && store.releasablePin(for: a.id) == nil)
        let remainingPin = try #require(store.releasablePin(for: b.id))
        #expect(store.releaseTimePin(remainingPin) && store.journal.tasks[0].routineExceptions == [])
    }

    @Test @MainActor func releasingMaterializedExceptionRestoresOnlyItsOwnAvailabilityChange() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date.now))
        var owner = PlanTask("Weekly review", minutes: 10)
        owner.repeated = .weekly
        owner.plannedStart = now
        owner.after = now.addingTimeInterval(-900)
        let nominal = try #require(calendar.date(byAdding: .day, value: 7, to: now))
        let early = try #require(calendar.date(byAdding: .day, value: 5, to: now))
        let key = RoutineOccurrence(seriesID: owner.id, rule: .weekly, day: nominal, calendar: calendar)
        owner.setException(.init(occurrence: key, start: early), for: key)
        owner.done = true
        owner.completedAt = now
        var tasks = [owner]
        TaskRoutines.advance(&tasks, at: now, calendar: calendar)
        let store = try reopened(tasks)
        let pin = try #require(store.releasablePin(for: key.id))
        #expect(store.releaseTimePin(pin))
        let restored = try #require(store.journal.tasks.first { $0.id == key.id })
        #expect(restored.after == nominal && restored.plannedStart == nominal && restored.routineAnchor == nominal)

        let edited = try reopened(tasks)
        let index = try #require(edited.journal.tasks.firstIndex { $0.id == key.id })
        edited.journal.tasks[index].after = nominal.addingTimeInterval(90)
        #expect(!edited.releaseTimePin(pin))
        let editedPin = try #require(edited.releasablePin(for: key.id))
        #expect(edited.releaseTimePin(editedPin))
        #expect(edited.journal.tasks[index].after == nominal.addingTimeInterval(90))
    }
}

extension RoutineExceptionJournalTests {
    @Test func customRepeatDaysSurviveBackupAndOlderPeerEdits() throws {
        var task = PlanTask("Practice guitar", minutes: 10)
        task.repeated = .daily
        task.repeatDays = [2, 4, 6]
        var journal = Journal()
        journal.tasks = [task]
        journal.templates = [task]
        let backup = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(backup.tasks.first?.repeatDays == [2, 4, 6])
        #expect(backup.templates?.first?.repeatDays == [2, 4, 6])

        var daily = journal
        daily.tasks[0].repeatDays = nil
        daily.templates?[0].repeatDays = nil
        let current = SharedJournal(daily)
        #expect(try current.applying(to: journal).tasks[0].repeatDays == nil)
        var olderJSON = try #require(JSONSerialization.jsonObject(with: current.encoded()) as? [String: Any])
        olderJSON["fieldVersion"] = 4
        let old = try JSONDecoder().decode(SharedJournal.self, from: JSONSerialization.data(withJSONObject: olderJSON))
        let merged = try old.applying(to: journal)
        #expect(merged.tasks[0].repeatDays == [2, 4, 6])
        #expect(merged.templates?.first?.repeatDays == [2, 4, 6])

        daily.tasks[0].repeated = .weekly
        daily.tasks[0].repeatDays = [4]
        #expect(throws: JournalArchive.Failure.invalid) { try JournalArchive.validate(daily) }
    }
}
