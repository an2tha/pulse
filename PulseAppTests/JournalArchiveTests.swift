import Foundation
import PulseEngine
import SwiftData
import Testing

@testable import Pulse

struct JournalArchiveTests {
    @Test func legacyAndVersionedFilesRestore() throws {
        var original = Journal()
        original.tasks = [PlanTask("Water plants", minutes: 12)]
        let legacy = JSONEncoder()
        legacy.dateEncodingStrategy = .iso8601
        let migrated = try JournalArchive.decodeBackup(legacy.encode(original))
        #expect(migrated.tasks.map(\.id) == original.tasks.map(\.id))
        #expect(try JournalArchive.readDatabase(JSONEncoder().encode(original)) == original)
        #expect(try JournalArchive.readDatabase(JournalArchive.database(original)) == original)
        original.active = ActiveSession(
            task: original.tasks[0], minutes: 10, now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(original))
        #expect(restored.active?.taskID == original.tasks[0].id)
        #expect(restored.active?.wallAnchor == nil)
        #expect(restored.active?.tickAnchor == nil)
        #expect(throws: JournalArchive.Failure.newerVersion) {
            try JournalArchive.decodeBackup(Data(#"{"format":"app.pulseplanner.journal","version":999}"#.utf8))
        }
    }

    @Test func malformedJournalsCannotReplaceLocalWork() throws {
        var journal = Journal()
        var task = PlanTask("Read", minutes: 10)
        task.dependency = task.id
        journal.tasks = [task]
        #expect(throws: JournalArchive.Failure.invalid) { try JournalArchive.validate(journal) }
        task.dependency = nil
        task.originalMinutes = Int.max
        journal.tasks = [task]
        #expect(throws: JournalArchive.Failure.invalid) { try JournalArchive.validate(journal) }
        journal.tasks = []
        var tuning = PlanTuning(date: .now)
        tuning.manualCapacity = .infinity
        journal.tuning = tuning
        #expect(throws: JournalArchive.Failure.invalid) { try JournalArchive.validate(journal) }
    }

    @Test func csvProtectsNotesAndSpreadsheetCells() {
        var journal = Journal()
        var report = CheckIn(energy: 3, clarity: 5, interest: 7, feltWorseAfterActivity: true)
        report.stress = 7
        report.fatigueNote = "=test, \"quoted\""
        journal.reports = [report]
        let ordinary = String(decoding: JournalArchive.csv(journal, includePrivateNotes: false), as: UTF8.self)
        #expect(!ordinary.contains("quoted"))
        #expect(!ordinary.contains("true"))
        let full = String(decoding: JournalArchive.csv(journal, includePrivateNotes: true), as: UTF8.self)
        #expect(full.contains(#""'=test, ""quoted""""#))
        #expect(full.contains("true"))
    }

    @MainActor @Test func repositoryRecoversPriorRevisionAndErasesItOnWipe() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: JournalEntry.self, configurations: config)
        let repo = LocalRepository(modelContainer: container)
        var journal = Journal()
        journal.tasks = [PlanTask("First revision", minutes: 5)]
        try await repo.save(journal, revision: 1)
        journal.tasks[0].title = "Second revision"
        try await repo.save(journal, revision: 2)
        let editor = ModelContext(container)
        let entry = try #require(editor.fetch(FetchDescriptor<JournalEntry>()).first { $0.key == "journal" })
        entry.bytes = Data("damaged".utf8)
        try editor.save()
        let recovery = LocalRepository(modelContainer: container)
        let snapshot = try await recovery.loadSnapshot()
        #expect(snapshot.recovered)
        #expect(snapshot.journal.tasks.first?.title == "First revision")
        entry.bytes = Data(#"{"format":"app.pulseplanner.journal","version":999}"#.utf8)
        try editor.save()
        let newer = LocalRepository(modelContainer: container)
        await #expect(throws: JournalArchive.Failure.newerVersion) { try await newer.loadSnapshot() }
        var erased = Journal()
        erased.starterAvailable = false
        try await recovery.save(erased, revision: 3)
        let rows = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        #expect(rows.map(\.key) == ["journal"])
        #expect(try JournalArchive.readDatabase(rows[0].bytes) == erased)
    }
}

extension JournalArchiveTests {
    @Test func olderSyncRevisionsPreserveTaskHoursAndSprintHistory() throws {
        let window = try #require(TaskAvailability(weekdays: [2, 3], startMinute: 540, endMinute: 720))
        var task = PlanTask("Call the workshop", minutes: 5)
        var record = SessionRecord(taskID: task.id, title: task.title, start: .now.addingTimeInterval(-600), seconds: 120)
        record.finishedAt = .now.addingTimeInterval(-480)
        task.capturedDuringSessionID = record.id
        task.availability = window
        var journal = Journal()
        journal.tasks = [task]
        journal.templates = [task]
        journal.sessions = [record]
        let backedUp = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(backedUp.tasks.first?.availability == window && backedUp.templates?.first?.availability == window)

        var changed = journal
        changed.tasks[0].availability = nil
        changed.tasks[0].capturedDuringSessionID = nil
        changed.templates?[0].availability = nil
        changed.sessions[0].finishedAt = nil
        let current = SharedJournal(changed)
        #expect(try current.applying(to: journal).tasks.first?.availability == nil)
        var oldPayload = try #require(JSONSerialization.jsonObject(with: current.encoded()) as? [String: Any])
        oldPayload.removeValue(forKey: "fieldVersion")
        let old = try JSONDecoder().decode(SharedJournal.self, from: JSONSerialization.data(withJSONObject: oldPayload))
        let merged = try old.applying(to: journal)
        #expect(merged.tasks[0].availability == window && merged.tasks[0].capturedDuringSessionID == record.id)
        #expect(merged.templates?.first?.availability == window && merged.sessions[0].finishedAt == record.finishedAt)
    }
}
