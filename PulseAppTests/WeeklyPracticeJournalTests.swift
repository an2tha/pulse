import Foundation
import PulseEngine
import Testing

@testable import Pulse

struct WeeklyPracticeJournalTests {
    @Test func archiveAndSharedCopiesPreserveTheWeeklyLog() throws {
        let date = Date(timeIntervalSince1970: 1_799_000_000)
        var practice = WeeklyPractice("Draw")
        let task = try #require(practice.session(for: date, tasks: []))
        practice.log(at: date, taskID: task.id)
        var journal = Journal()
        journal.practices = [practice]
        journal.tasks = [task]
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(restored.practices == [practice])
        #expect(restored.tasks.first?.practiceID == practice.id)
        let shared = try JSONDecoder().decode(SharedJournal.self, from: SharedJournal(journal).encoded())
        #expect(try shared.applying(to: Journal()).practices == [practice])
        var oldPeer = shared
        oldPeer.practices = nil
        oldPeer.tasks[0].practiceID = nil
        let merged = try oldPeer.applying(to: journal)
        #expect(merged.practices == [practice])
        #expect(merged.tasks[0].practiceID == practice.id)
        var pending = journal
        pending.practices?[0].removeLog(on: date)
        oldPeer.tasks[0].done = true
        oldPeer.tasks[0].completedAt = date
        let completed = try oldPeer.applying(to: pending)
        #expect(completed.practices?[0].logged(on: date)?.taskID == task.id)
        var unlogged = completed
        unlogged.practices?[0].removeLog(on: date)
        #expect(try oldPeer.applying(to: unlogged).practices?[0].logs.isEmpty == true)
        oldPeer.practices = []
        let deleted = try oldPeer.applying(to: journal)
        #expect(deleted.practices == [])
        #expect(deleted.tasks[0].practiceID == nil)
        practice.targetDays = 8
        journal.practices = [practice]
        #expect(throws: JournalArchive.Failure.invalid) { try JournalArchive.validate(journal) }
    }
}
