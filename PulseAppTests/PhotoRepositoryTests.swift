import Foundation
import ImageIO
import PulseEngine
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import Pulse

@Suite @MainActor struct PhotoRepositoryTests {
    private func jpeg(_ red: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: red, green: 0.4, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bytes = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try #require(context.makeImage())
        CGImageDestinationAddImage(output, image, nil)
        try #require(CGImageDestinationFinalize(output))
        return bytes as Data
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func existingPicturesMigrateOnceAndBackupsStaySelfContained() async throws {
        let container = try container()
        let task = PlanTask("Plant the basil", minutes: 5)
        var journal = Journal()
        journal.tasks = [task]
        journal.photos = [try JournalPhoto(taskID: task.id, title: task.title, completion: true, jpeg: jpeg(0.2))]
        let old = ModelContext(container)
        old.insert(JournalEntry(bytes: try JournalArchive.database(journal)))
        try old.save()
        let repository = LocalRepository(modelContainer: container)
        #expect(try await repository.load() == journal)
        journal.tasks[0].notes = "Kitchen window"
        try await repository.save(journal, revision: 1)
        let firstRows = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        let payload = try #require(firstRows.first { $0.key.hasPrefix("picture/") })
        #expect(firstRows.count == 3 && payload.bytes == journal.photos?.first?.jpeg)
        journal.tasks[0].notes = "Water on Friday"
        try await repository.save(journal, revision: 2)
        let keys = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.key)
        #expect(Set(keys) == ["journal", "previous", payload.key])
        let reload = LocalRepository(modelContainer: container)
        #expect(try await reload.load() == journal)
        let backup = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(backup.photos?.first?.jpeg == payload.bytes)
        var broken = journal
        broken.photos![0].jpeg = Data([1, 2, 3])
        await #expect(throws: JournalArchive.Failure.invalid) { try await repository.save(broken, revision: 3) }
        #expect(try await reload.load() == journal)
    }

    @Test func replacingAndDeletingAlsoProtectsRecoveryAndErasure() async throws {
        let container = try container()
        let repository = LocalRepository(modelContainer: container)
        let task = PlanTask("Study", minutes: 5)
        var journal = Journal()
        journal.tasks = [task]
        journal.photos = [try JournalPhoto(taskID: task.id, title: task.title, completion: false, jpeg: jpeg(0.2))]
        try await repository.save(journal, revision: 1)
        let priorPhoto = journal.photos
        journal.photos![0].jpeg = try jpeg(0.85)
        try await repository.save(journal, revision: 2)
        let editor = ModelContext(container)
        let rows = try editor.fetch(FetchDescriptor<JournalEntry>())
        #expect(rows.filter { $0.key.hasPrefix("picture/") }.count == 2)
        let current = try #require(rows.first { $0.key == "journal" })
        current.bytes = Data([0])
        try editor.save()
        let recovery = try await LocalRepository(modelContainer: container).loadSnapshot()
        #expect(recovery.recovered && recovery.journal.photos == priorPhoto)
        journal.photos = nil
        try await repository.save(journal, revision: 3)
        let cleaned = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        #expect(Set(cleaned.map(\.key)) == ["journal", "previous"])
        let previous = try #require(cleaned.first { $0.key == "previous" })
        #expect(try (JournalArchive.readDatabase(previous.bytes).photos ?? []).isEmpty)
        var empty = Journal()
        empty.starterAvailable = false
        try await repository.save(empty, revision: 4)
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.key) == ["journal"])
    }

    @Test func captionEditsReuseThePayloadAndSearchSurvivesTaskChanges() async throws {
        let container = try container()
        let repository = LocalRepository(modelContainer: container)
        var task = PlanTask("Basil seedlings", minutes: 5)
        var journal = Journal()
        journal.tasks = [task]
        let photo = try JournalPhoto(taskID: task.id, title: task.title, completion: false, jpeg: jpeg(0.3))
        journal.photos = [photo]
        try await repository.save(journal, revision: 1)
        let payload = try #require(ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first { $0.key.hasPrefix("picture/") }?.key)
        task.title = "Repot herbs"
        task.project = "Kitchen garden"
        journal.tasks = [task]
        let note = "First leaves by the café window"
        journal.photos?[0].caption = note
        try await repository.save(journal, revision: 2)
        let restored = try await LocalRepository(modelContainer: container).load()
        #expect(restored.photos?.first?.caption == note)
        let keys = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.key)
        #expect(keys.filter { $0.hasPrefix("picture/") } == [payload])
        for term in ["  cafe  ", "basil", "repot", "GARDEN"] {
            #expect(JournalPhoto.matching(restored.photos ?? [], query: term, tasks: restored.tasks).first?.id == photo.id)
        }
        #expect(JournalPhoto.matching(restored.photos ?? [], query: "leaves", tasks: []).first?.id == photo.id)
        #expect(JournalPhoto.matching(restored.photos ?? [], query: "missing", tasks: restored.tasks).isEmpty)
        #expect(try JournalArchive.decodeBackup(JournalArchive.backup(restored)).photos?.first?.caption == note)
        #expect(!String(decoding: try SharedJournal(restored).encoded(), as: UTF8.self).contains(note))
        #expect(!String(decoding: JournalArchive.csv(restored, includePrivateNotes: true), as: UTF8.self).contains(note))
        journal.photos?[0].caption = nil
        try await repository.save(journal, revision: 3)
        #expect(try await LocalRepository(modelContainer: container).load().photos?.first?.caption == nil)
    }

    @Test func completionNeedsProofForThisOccurrenceAndWritesItOnce() throws {
        var task = PlanTask("Water the plant", minutes: 5)
        task.requiresPhotoProof = true
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.tasks = [task]
        let image = try jpeg(0.3)
        store.journal.photos = [JournalPhoto(taskID: task.id, title: task.title, completion: false, jpeg: image),
                                JournalPhoto(taskID: UUID(), title: "Different task", completion: true, jpeg: image)]
        #expect(store.needsCompletionPhoto(for: task))
        store.change { journal in
            journal.tasks[0].done = true
            journal.limit = 0
        }
        #expect(!store.journal.tasks[0].done && store.journal.limit == 60)
        #expect(!store.completeFromPlan(task))
        let request = try #require(store.pendingCompletionProof)
        #expect(throws: CompletionProofError.self) { try store.completeWithProof(request, jpeg: Data()) }
        #expect(!store.journal.tasks[0].done && store.journal.photos?.count == 2)
        try store.completeWithProof(request, jpeg: image)
        #expect(store.journal.tasks[0].done && store.journal.photos?.count == 3)
        #expect(store.taskCompletion?.taskID == task.id && store.pendingCompletionProof == nil)
        #expect(throws: CompletionProofError.self) { try store.completeWithProof(request, jpeg: image) }
        #expect(store.undoListCompletion(try #require(store.lastListCompletion)))
        #expect(!store.journal.tasks[0].done && !store.needsCompletionPhoto(for: task))
        let next = task.duplicate()
        #expect(next.requiresPhotoProof == true && store.needsCompletionPhoto(for: next))
        store.change { $0.photoProofEnabled = false }
        #expect(!store.needsCompletionPhoto(for: next))
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        #expect(restored.tasks[0].requiresPhotoProof == true && restored.photoProofEnabled == false)
    }

    @Test func lastFocusStepWaitsForEvidenceAndStaleRequestsCannotFinishAnotherSession() throws {
        var task = PlanTask("Clean the bench", minutes: 10)
        task.requiresPhotoProof = true
        task.steps = [TaskStep("Wipe down"), TaskStep("Put tools away")]
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.tasks = [task]
        var session = ActiveSession(task: task, minutes: 5, now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
        session.stepID = task.steps?[0].id
        store.journal.active = session
        store.finish(done: true)
        #expect(store.journal.tasks[0].steps?[0].done == true && !store.journal.tasks[0].done)
        session.stepID = task.steps?[1].id
        store.journal.active = session
        store.finish(done: true)
        let stale = try #require(store.pendingCompletionProof)
        #expect(store.journal.active == session && store.journal.sessions.count == 1)
        session = ActiveSession(task: task, minutes: 5, now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
        store.journal.active = session
        let image = try jpeg(0.4)
        #expect(throws: CompletionProofError.self) { try store.completeWithProof(stale, jpeg: image) }
        #expect(store.journal.active == session && store.journal.photos == nil)
        store.finish(done: true)
        try store.completeWithProof(try #require(store.pendingCompletionProof), jpeg: image)
        #expect(store.journal.active == nil && store.journal.tasks[0].done)
        #expect(store.journal.sessions.last?.completedTask == true && store.journal.photos?.last?.taskID == task.id)
    }

    @Test func missingPictureLeavesCurrentTasksAvailable() async throws {
        let container = try container()
        let repository = LocalRepository(modelContainer: container)
        let task = PlanTask("Climb", minutes: 10)
        var journal = Journal()
        journal.tasks = [task]
        journal.photos = [try JournalPhoto(taskID: task.id, title: task.title, completion: false, jpeg: jpeg(0.5))]
        try await repository.save(journal, revision: 1)
        let editor = ModelContext(container)
        let rows = try editor.fetch(FetchDescriptor<JournalEntry>())
        editor.delete(try #require(rows.first { $0.key.hasPrefix("picture/") }))
        try editor.save()
        let opened = try await LocalRepository(modelContainer: container).loadSnapshot()
        #expect(opened.unavailablePhotos == 1 && opened.journal.tasks == [task] && opened.journal.photos?.isEmpty == true)
    }
}
