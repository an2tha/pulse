import Foundation
import PulseEngine
import SwiftData
import Testing
@testable import Pulse

@Suite @MainActor struct CaptureDraftTests {
    @Test func sprintClockPreviewsMatchTheSavedPinAndOrdinaryQuickCaptureStaysLiteral() throws {
        let now = Date.now
        let text = "Call Sam tomorrow at 3pm"
        let task = try #require(InboxCaptureDraft(text, at: now, commitments: [], distraction: true))
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let pin = try #require(Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow))
        #expect(task.interpreted && task.task.plannedStart == pin && task.task.title == "Call Sam")
        #expect(task.details.contains("Scheduled") && !task.details.contains("Earliest"))
        #expect(task.literal.title == text && task.literal.plannedStart == nil)
        let ordinary = try #require(InboxCaptureDraft(text, at: now, commitments: []))
        #expect(!ordinary.interpreted && ordinary.unresolved && ordinary.task.title == text && ordinary.task.plannedStart == nil)
    }

    @Test func sprintRangePreviewAndSaveKeepTheTimedTaskWithItsSprint() throws {
        let input = "Practice cello tomorrow from 3pm to 3:30pm"
        let draft = try #require(InboxCaptureDraft(input, at: .now, commitments: [], distraction: true))
        #expect(draft.interpreted && !draft.unresolved && draft.details.contains("30 min") && draft.details.contains("Scheduled"))
        #expect(draft.literal.title == input && draft.literal.plannedStart == nil)
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        let active = PlanTask("Current sprint", minutes: 5)
        let session = ActiveSession(task: active, minutes: 2, now: .now, tick: 0, boot: nil)
        store.journal.tasks = [active]
        store.journal.active = session
        let id = try #require(store.captureTask(draft.task, focusSession: session, distraction: true))
        let saved = try #require(store.journal.tasks.first { $0.id == id })
        #expect(saved.minutes == 30 && saved.plannedStart == draft.task.plannedStart && !saved.isInboxOnly)
        #expect(saved.capturedDuringSessionID == session.sessionID && store.journal.events.isEmpty)
        let ambiguous = try #require(InboxCaptureDraft("Practice from 3 to 4", at: .now, commitments: [], distraction: true))
        #expect(!ambiguous.interpreted && ambiguous.unresolved && ambiguous.task.plannedStart == nil)
    }

    @Test func selectedCadencePreviewListsLocalWeekdaysAndKeepsLiteralWords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let text = "Practice guitar every Monday, Wednesday and Friday for 10 minutes"
        let draft = try #require(InboxCaptureDraft(text, at: .now, commitments: []))
        #expect(draft.task.captureRecurrence(in: calendar, locale: Locale(identifier: "en_GB")) == "Every Mon, Wed, Fri")
        #expect(draft.details.contains("Every ") && !draft.details.contains("Daily"))
        var weekend = draft.task
        weekend.repeatDays = [1,2,7]
        var german = calendar
        german.locale = Locale(identifier: "de_DE")
        let symbols = german.shortWeekdaySymbols
        #expect(weekend.captureRecurrence(in: calendar, locale: german.locale!) == "Every " + [symbols[1], symbols[6], symbols[0]].joined(separator: ", "))
        #expect(draft.literal.title == text && draft.literal.repeatDays == nil)
    }

    @Test func explicitTaskHoursPreviewTheSameRuleThatWillBeSaved() async throws {
        let text = "Call the repair shop only on weekdays from 9am to 5pm for 10 minutes"
        let quick = try #require(InboxCaptureDraft(text, at: .now, commitments: []))
        let rule = try #require(quick.task.availability)
        #expect(quick.interpreted && !quick.unresolved && quick.task.title == "Call the repair shop")
        #expect(quick.details.contains(rule.formattedHours()) && quick.task.minutes == 10)
        #expect(quick.literal.title == text && quick.literal.availability == nil)
        var journal = Journal()
        var settings = ConnectionState()
        settings.onDeviceAssistant = true
        journal.connections = settings
        let (proposal, _) = try await AssistantPlanner.propose(text, journal: journal, blocks: [], now: .now)
        try proposal.apply(to: &journal)
        #expect(journal.tasks.count == 1 && journal.events.isEmpty && journal.tasks[0].availability == rule)
    }

    @Test func sprintDraftsReopenFromDiskWithoutCrossingSessionsOrQuickCapture() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: location) }
        let url = location.appendingPathComponent("Journal.store")
        func repository() throws -> LocalRepository {
            let container = try ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(url: url))
            return LocalRepository(modelContainer: container)
        }
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        let task = PlanTask("Finish the notes", minutes: 12)
        store.journal.tasks = [task]
        let now = Date.now
        store.journal.active = ActiveSession(task: task, minutes: 2, now: now, tick: 0, boot: nil)
        let first = try #require(store.journal.active?.sessionID)
        store.captureDrafts.setText("Outside Focus", for: .quick)
        store.captureDrafts.setText("Remember the first thought", for: .sprint(first))
        store.captureDrafts.toggleLiteral(for: .sprint(first))
        store.finish(done: false)
        store.journal.active = ActiveSession(task: task, minutes: 2, now: now.addingTimeInterval(5), tick: 0, boot: nil)
        let second = try #require(store.journal.active?.sessionID)
        #expect(first != second && store.captureDrafts.text(for: .sprint(second)).isEmpty)
        store.captureDrafts.setText("Remember another thought", for: .sprint(second))
        store.flushCaptureDrafts()
        try await repository().save(store.journal, revision: 1)
        let restarted = try await repository().load()
        let recovered = try #require(restarted.captureDrafts)
        #expect(recovered.text(for: .quick) == "Outside Focus")
        #expect(recovered.text(for: .sprint(first)) == "Remember the first thought" && recovered.literal(for: .sprint(first)))
        #expect(recovered.text(for: .sprint(second)) == "Remember another thought" && !recovered.literal(for: .sprint(second)))
        #expect(restarted.tasks.allSatisfy { $0.capturedDuringSessionID == nil })
        #expect(restarted.sessions.last?.id == first && restarted.active?.sessionID == second)
        let exported = try JournalArchive.decodeBackup(JournalArchive.backup(restarted))
        #expect(exported.captureDrafts == nil)
        #expect(!String(decoding: try SharedJournal(restarted).encoded(), as: UTF8.self).contains("Remember the first thought"))
        store.journal = restarted
        store.captureDrafts = recovered
        let saved = PlanTask(recovered.text(for: .sprint(first)), minutes: 3)
        #expect(store.captureTask(saved, completing: .sprint(first)) == saved.id)
        #expect(store.journal.tasks.last?.capturedDuringSessionID == first)
        #expect(store.journal.captureDrafts?.text(for: .sprint(first)) == "")
        #expect(store.journal.captureDrafts?.text(for: .sprint(second)) == "Remember another thought")
        store.captureDrafts.clear(.sprint(second))
        store.flushCaptureDrafts()
        #expect(store.journal.captureDrafts?.sprints == nil)
        #expect(store.captureDrafts.quick == "Outside Focus")
    }

    @Test func recoveredDraftsUseTheLastEditAcrossMidnightAndTravel() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let edited = CaptureReference(at: try Date("2026-11-09T22:55:00Z", strategy: .iso8601), timeZone: berlin)
        let reopened = CaptureReference(at: try Date("2026-11-10T08:00:00Z", strategy: .iso8601), timeZone: tokyo)
        let id = UUID()
        let sprint = CaptureDraftSlot.sprint(id)
        var drafts = CaptureDrafts()
        drafts.setText("Call Sam tomorrow at 3pm", for: sprint, reference: edited)
        drafts.setText("Check files in 20 minutes", for: .quick, reference: edited)
        drafts.setDump("Check files in 20 minutes\nPack tomorrow", reference: edited)
        drafts = try JSONDecoder().decode(CaptureDrafts.self, from: JSONEncoder().encode(drafts))
        drafts.recoverReference(for: .quick, fallback: reopened)
        drafts.recoverReference(for: sprint, fallback: reopened)
        drafts.recoverDumpReference(fallback: reopened)
        drafts.setDump(drafts.dump, reference: reopened)
        drafts.setText(drafts.quick, for: .quick, reference: reopened)
        drafts.toggleLiteral(for: sprint)
        drafts.toggleLiteral(for: sprint)
        for slot in [sprint, .quick] {
            #expect(drafts.reference(for: slot) == edited)
        }
        let sessionRef = try #require(drafts.reference(for: sprint))
        let task = try #require(InboxCaptureDraft(drafts.text(for: sprint), at: sessionRef.date,
                                                 calendar: sessionRef.calendar, commitments: [], distraction: true))
        let expectedPin = try Date("2026-11-10T14:00:00Z", strategy: .iso8601)
        #expect(task.task.plannedStart == expectedPin)
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.captureDrafts = drafts
        #expect(store.captureTask(task.task, completing: sprint) == task.task.id)
        #expect(store.journal.tasks.last?.plannedStart == expectedPin)
        #expect(store.captureDrafts.reference(for: sprint) == nil)
        let quick = try #require(InboxCaptureDraft(drafts.quick, at: edited.date, calendar: edited.calendar, commitments: []))
        #expect(quick.task.after == edited.date.addingTimeInterval(1200))
        let dumpRef = try #require(drafts.dumpReference)
        let list = TodoDump.tasks(from: drafts.dump, at: dumpRef.date, calendar: dumpRef.calendar)
        #expect(list.first?.after == quick.task.after)
        #expect(list.last?.after == (try Date("2026-11-09T23:00:00Z", strategy: .iso8601)))
        drafts.setText("Check prints in 20 minutes", for: .quick, reference: reopened)
        drafts.setDump("Pack tomorrow for 15 minutes", reference: reopened)
        #expect(drafts.reference(for: .quick) == reopened && drafts.dumpReference == reopened)
        let revised = TodoDump.tasks(from: drafts.dump, at: reopened.date, calendar: reopened.calendar)
        #expect(revised.first?.after == (try Date("2026-11-10T15:00:00Z", strategy: .iso8601)))
        drafts.clear(.quick)
        drafts.setDump("")
        #expect(drafts.quickReference == nil && drafts.dumpReference == nil)
    }

    @Test func dumpLinesKeepTheirOwnClocksThroughTravelEditsAndReordering() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let first = CaptureReference(at: try Date("2026-11-09T14:58:00Z", strategy: .iso8601), timeZone: tokyo)
        let later = CaptureReference(at: try Date("2026-11-10T13:00:00Z", strategy: .iso8601), timeZone: la)
        let latest = CaptureReference(at: later.date.addingTimeInterval(3600), timeZone: la)
        let pack = "Pack tomorrow"
        let water = "Water plants in 20 minutes"
        var draft = CaptureDrafts(dump: pack, dumpReference: first)
        draft.setDump([pack, water, pack].joined(separator: "\n"), reference: later)
        draft.setDump([water, pack, "-", pack].joined(separator: "\n"), reference: latest)
        let review = draft.reviewDump(commitments: [])
        draft.reviewed = review.tasks
        draft.reviewedLineIndices = review.indices
        draft = try JSONDecoder().decode(CaptureDrafts.self, from: JSONEncoder().encode(draft))
        let packs = draft.reviewed.filter { $0.title == "Pack" }
        #expect(packs.count == 2)
        #expect(packs.map { draft.reviewedReference(for: $0.id) } == [first, later])
        #expect(packs.map(\.after) == [try Date("2026-11-09T15:00:00Z", strategy: .iso8601),
                                     try Date("2026-11-11T08:00:00Z", strategy: .iso8601)])
        let moved = try #require(draft.reviewed.first { $0.title == "Water plants" })
        #expect(moved.after == later.date.addingTimeInterval(1200))
        draft.setDump([water, "Pack boots tomorrow", pack].joined(separator: "\n"), reference: latest)
        let edited = draft.reviewDump(commitments: [])
        #expect(edited.tasks.last?.after == packs.last?.after)
        #expect(edited.tasks.first?.after == moved.after)
        #expect(edited.tasks[1].title == "Pack boots" && edited.tasks[1].after == packs.last?.after)
        #expect(draft.reviewed.isEmpty && draft.reviewedLineIndices == nil)
        draft.setDump("")
        #expect(draft.dumpReference == nil && draft.dumpLineReferences == nil)
    }

    @Test func olderTextAcquiresOneStableReferenceDuringRecovery() throws {
        let id = UUID()
        let editDate = Date(timeIntervalSinceReferenceDate: 150)
        var old = CaptureDrafts(sprints: [id: .init(text: "Call tomorrow", literal: false, updatedAt: editDate)],
                                quick: "Ordinary tomorrow", dump: "Another tomorrow")
        let first = CaptureReference(at: Date(timeIntervalSinceReferenceDate: 58000), timeZone: .gmt)
        let later = CaptureReference(at: Date(timeIntervalSinceReferenceDate: 200000))
        for clock in [first, later] {
            old.recoverReference(for: .quick, fallback: clock)
            old.recoverReference(for: .sprint(id), fallback: clock)
            old.recoverDumpReference(fallback: clock)
        }
        #expect(old.quickReference == first && old.dumpReference == first)
        #expect(old.reference(for: .sprint(id)) == CaptureReference(at: editDate, timeZone: first.timeZone))
    }

    @Test func fullDraftCollectionRejectsNewInputWithoutDeletingExistingText() throws {
        var drafts = CaptureDrafts()
        let sessionIDs = (0..<CaptureDrafts.sprintLimit).map { _ in UUID() }
        for id in sessionIDs { drafts.setText("My thought", for: .sprint(id)) }
        let extra = UUID()
        let overflow = drafts.setText("Another", for: .sprint(extra))
        #expect(!overflow)
        let first = try #require(sessionIDs.first)
        let oversized = drafts.setText(String(repeating: "🌱", count: CaptureDrafts.sprintByteLimit / 4 + 1), for: .sprint(first))
        #expect(!oversized)
        #expect(drafts.text(for: .sprint(first)) == "My thought")
        let edited = drafts.setText("Edited", for: .sprint(first))
        #expect(edited)
        drafts.clear(.sprint(first))
        let added = drafts.setText("Another", for: .sprint(extra))
        #expect(added)
        let legacy = Data(#"{"quick":"Old draft","quickLiteral":true,"dump":"","reviewed":[]}"#.utf8)
        let old = try JSONDecoder().decode(CaptureDrafts.self, from: legacy)
        #expect(old.sprints == nil && old.quick == "Old draft" && old.quickLiteral)
    }

    @Test func editClocksAndUnfinishedTextAreDeviceLocalAcrossBackupAndSync() throws {
        let clock = CaptureReference(at: Date(timeIntervalSinceReferenceDate: 509293),
                                     timeZone: try #require(TimeZone(identifier: "Pacific/Marquesas")))
        var local = Journal()
        var drafts = CaptureDrafts()
        drafts.setText("Private first thought", for: .quick, reference: clock)
        drafts.setText("Private session thought", for: .sprint(UUID()), reference: clock)
        drafts.setDump("Private dump thought", reference: clock)
        drafts.setDump("Private dump thought\nPrivate tomorrow", reference: .init(at: clock.date.addingTimeInterval(3600)))
        let reviewed = drafts.reviewDump(commitments: [])
        drafts.reviewed = reviewed.tasks
        drafts.reviewedLineIndices = reviewed.indices
        local.captureDrafts = drafts
        #expect(try JournalArchive.readDatabase(JournalArchive.database(local)).captureDrafts == drafts)
        let backup = try JournalArchive.backup(local)
        let sync = try SharedJournal(local).encoded()
        for payload in [backup, sync] {
            let text = String(decoding: payload, as: UTF8.self)
            for privateWord in ["captureDrafts", "quickReference", "dumpReference", "dumpLineReferences", "reviewedLineIndices", "updatedAt", "Marquesas", "Private"] {
                #expect(!text.contains(privateWord))
            }
        }
        // An incoming file cannot introduce private edit history into this device.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try JournalArchive.decodeBackup(encoder.encode(local)).captureDrafts == nil)
        var peer = Journal()
        peer.tasks = [PlanTask("Public task", minutes: 5)]
        let incoming = try SharedJournal(peer).applying(to: local)
        #expect(incoming.tasks == peer.tasks && incoming.captureDrafts == drafts)
    }

    @Test func unfinishedInputStaysLocalAndDiscardClearsTheRecoveryCopy() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: JournalEntry.self, configurations: config)
        let repo = LocalRepository(modelContainer: container)
        var journal = Journal()
        journal.tasks = [PlanTask("Work already saved", minutes: 10)]
        try await repo.save(journal, revision: 1)
        let review = PlanTask("Return the book", minutes: 5)
        journal.captureDrafts = CaptureDrafts(quick: "An unfinished thought", quickLiteral: true, dump: "Return the book", reviewed: [review])
        try await repo.save(journal, revision: 2)
        let restarted = try await LocalRepository(modelContainer: container).load()
        #expect(restarted.captureDrafts == journal.captureDrafts)
        let exported = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(exported.captureDrafts == nil)
        #expect(exported.tasks.map(\.id) == journal.tasks.map(\.id))
        #expect(exported.tasks.map(\.title) == journal.tasks.map(\.title))
        #expect(!String(decoding: try SharedJournal(journal).encoded(), as: UTF8.self).contains("unfinished thought"))
        journal.captureDrafts = nil
        try await repo.save(journal, revision: 3)
        let records = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        for record in records {
            #expect(try JournalArchive.readDatabase(record.bytes).captureDrafts == nil)
        }
    }
}

@Suite @MainActor struct DraftRepositoryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func rows(_ container: ModelContainer) throws -> [String: Data] {
        let entries = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.bytes) })
    }

    @Test func migratingInlineDraftsPreservesBothTaskRevisionsAndClearsTheirPrivateText() async throws {
        let database = try container()
        var first = Journal()
        first.tasks = [PlanTask("First task title", minutes: 10)]
        first.captureDrafts = CaptureDrafts(quick: "Prior private thought")
        var second = first
        second.tasks[0].title = "Updated title"
        var draft = CaptureDrafts()
        draft.setText("Pending sprint thought", for: .sprint(UUID()))
        draft.setText("Ordinary words", for: .quick)
        draft.setDump("To-do list")
        second.captureDrafts = draft
        let seed = ModelContext(database)
        seed.insert(JournalEntry(bytes: try JournalArchive.database(second)))
        seed.insert(JournalEntry(bytes: try JSONEncoder().encode(first), key: "previous"))
        try seed.save()
        let repository = LocalRepository(modelContainer: database)
        #expect(try await repository.load().captureDrafts == draft)
        draft.setDump("Revised to-do list")
        try await repository.saveDrafts(draft, revision: 1)
        let migrated = try rows(database)
        let current = try JournalArchive.readDatabase(#require(migrated["journal"]))
        let previous = try JournalArchive.readDatabase(#require(migrated["previous"]))
        #expect(current.tasks == second.tasks && previous.tasks == first.tasks)
        #expect(current.captureDrafts == nil && previous.captureDrafts == nil)
        #expect(try await LocalRepository(modelContainer: database).load().captureDrafts == draft)
        try await repository.saveDrafts(nil, revision: 2)
        let cleared = try rows(database)
        #expect(cleared["journal"] == migrated["journal"] && cleared["previous"] == migrated["previous"])
        #expect(cleared["capture-drafts"] == nil)
        let corrupt = ModelContext(database)
        let live = try #require(corrupt.fetch(FetchDescriptor<JournalEntry>()).first { $0.key == "journal" })
        live.bytes = Data([1, 2, 3])
        try corrupt.save()
        let recovered = try await LocalRepository(modelContainer: database).loadSnapshot()
        #expect(recovered.recovered && recovered.journal.tasks == first.tasks && recovered.journal.captureDrafts == nil)
    }

    @Test func standaloneDraftsColdStartAndOutOfOrderWritesKeepNewTasksAndNewestDraft() async throws {
        let database = try container()
        let repository = LocalRepository(modelContainer: database)
        let early = CaptureDrafts(quick: "Old draft")
        let late = CaptureDrafts(quick: "Latest draft")
        try await repository.saveDrafts(late, revision: 3)
        #expect(try await LocalRepository(modelContainer: database).load().captureDrafts == late)
        var older = Journal(captureDrafts: early)
        older.tasks = [PlanTask("A task arriving late", minutes: 5)]
        try await repository.save(older, revision: 2)
        let merged = try await LocalRepository(modelContainer: database).load()
        #expect(merged.tasks == older.tasks && merged.captureDrafts == late)
        older.tasks[0].title = "Changed task title"
        older.captureDrafts = nil
        try await repository.save(older, revision: 5)
        try await repository.saveDrafts(early, revision: 4)
        #expect(try await LocalRepository(modelContainer: database).load() == older)
    }

    @Test func cancelledAndFailedWritesCanRetryWithoutConsumingTheGoodRevision() async throws {
        let database = try container()
        let repository = LocalRepository(modelContainer: database)
        let original = CaptureDrafts(quick: "Draft before a failed save")
        var journal = Journal(captureDrafts: original)
        journal.tasks = [PlanTask("Existing task", minutes: 15)]
        try await repository.save(journal, revision: 1)
        let baseline = try rows(database)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await repository.saveDrafts(nil, revision: 2)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        var invalid = original
        invalid.quickReference = CaptureReference(at: Date(timeIntervalSinceReferenceDate: .infinity))
        await #expect(throws: (any Error).self) { try await repository.saveDrafts(invalid, revision: 2) }
        #expect(try rows(database) == baseline)
        let waiting = CaptureDrafts(quick: "Retried draft")
        try await repository.saveDrafts(waiting, revision: 2)
        journal.captureDrafts = nil
        journal.tasks.append(PlanTask("Captured task", minutes: 10))
        var invalidCapture = journal
        invalidCapture.tasks[1].effort = .nan
        await #expect(throws: (any Error).self) { try await repository.save(invalidCapture, revision: 3) }
        let failed = try await LocalRepository(modelContainer: database).load()
        #expect(failed.tasks.count == 1 && failed.captureDrafts == waiting)
        try await repository.save(journal, revision: 3)
        #expect(try await LocalRepository(modelContainer: database).load() == journal)
        #expect(try rows(database)["capture-drafts"] == nil)
    }
}
