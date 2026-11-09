import Foundation
import PulseEngine
import Testing
@testable import Pulse

struct SharedCaptureTests {
    @Test func orderedTransfersCanBeRetriedAndCleared() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = SharedCaptureQueue(directory: folder)
        let first = try SharedCapture(text: "Read the draft\nOpen the final section", url: URL(string: "https://example.com/read?q=1"),
                                      created: Date(timeIntervalSince1970: 10))
        let second = try SharedCapture(text: "Send the reply", url: nil, created: Date(timeIntervalSince1970: 20))
        #expect(try await queue.pending().isEmpty)
        try await queue.add(second)
        try await queue.add(first)
        try await queue.add(first)
        let pending = try await queue.pending()
        #expect(pending.map(\.id) == [first.id, second.id])
        var journal = Journal()
        journal.importSharedCaptures(pending + pending)
        #expect(journal.tasks.map(\.id) == [first.id, second.id])
        #expect(journal.tasks.first?.sourceURL == first.url && journal.tasks.first?.notes == "Open the final section")
        #expect(!journal.starterAvailable)
        journal.tasks.removeFirst()
        var restarted = try JournalArchive.readDatabase(JournalArchive.database(journal))
        restarted.importSharedCaptures(pending)
        #expect(restarted.tasks.map(\.id) == [second.id])
        #expect(try JournalArchive.decodeBackup(JournalArchive.backup(journal)).importedShares == nil)
        try await queue.acknowledge([first.id])
        try await queue.acknowledge([first.id])
        #expect(try await queue.pending().map(\.id) == [second.id])
        try await queue.clear()
        #expect(try await queue.pending().isEmpty)
    }

    @Test func validatesContentsAndKeepsFullLongText() async throws {
        #expect(throws: CaptureError.self) { try SharedCapture(text: "  ", url: nil) }
        #expect(throws: CaptureError.self) { try SharedCapture(text: "File", url: URL(string: "file:///private/a")) }
        #expect(throws: CaptureError.self) { try SharedCapture(text: String(repeating: "a", count: 32_001), url: nil) }
        let title = String(repeating: "🌱", count: 141)
        let entry = try SharedCapture(text: title, url: nil)
        var journal = Journal()
        journal.importSharedCaptures([entry])
        #expect(journal.tasks.first?.title.count == 140 && journal.tasks.first?.notes == title)
    }
}

extension SharedCaptureTests {
    @Test func distractionsInterpretOnlyTheSeparateTimingCaptionAtTheOriginalLocation() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let save = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 0, minute: 5)))
        let source = "Concert tomorrow at 7pm\nA quote says “Call tonight at 9pm”."
        let link = try #require(URL(string: "https://example.com/events"))
        let held = try SharedCapture(text: source, url: link, created: save, distraction: true)
        let timed = try SharedCapture(text: source, url: link, created: save, distraction: true,
                                      timingCaption: "tomorrow from 3pm to 3:30pm", timeZoneID: calendar.timeZone.identifier)
        let unclear = try SharedCapture(text: source, url: link, created: save, distraction: true, timingCaption: "at 25:30")
        let legacy = try SharedCapture(text: source, url: link, created: save)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SharedCaptureQueue(directory: directory)
        for item in [held, timed, unclear, legacy] { try await queue.add(item) }
        let batch = try await queue.pending()
        var journal = Journal()
        journal.importSharedCaptures(batch + batch)
        let tasks = Dictionary(uniqueKeysWithValues: journal.tasks.map { ($0.id, $0) })
        #expect(tasks.count == 4 && journal.events.isEmpty && tasks.values.allSatisfy { $0.sourceURL == link })
        #expect(tasks[held.id]?.isInboxOnly == true && tasks[held.id]?.plannedStart == nil)
        #expect(tasks[legacy.id]?.isInboxOnly == false && tasks[legacy.id]?.plannedStart == nil)
        #expect(tasks[unclear.id]?.isInboxOnly == true && tasks[unclear.id]?.notes?.contains("at 25:30") == true)
        #expect(tasks[timed.id]?.isInboxOnly == false && tasks[timed.id]?.minutes == 30)
        #expect(tasks[timed.id]?.title == "Concert tomorrow at 7pm" && tasks[timed.id]?.notes?.contains("9pm") == true)
        let pin = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15)))
        #expect(tasks[timed.id]?.plannedStart == pin)
    }

    @Test func laterImportLinksOnlyToAnUnambiguousSprintOnThisDevice() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = try SharedCapture(text: "Read tomorrow", url: nil, created: start.addingTimeInterval(20), distraction: true)
        var journal = Journal()
        let first = ActiveSession(openSprintSeconds: 120, now: start, tick: 0, boot: "local")
        journal.beginLocalSession(first)
        var active = journal
        active.importSharedCaptures([saved])
        #expect(active.tasks.first?.capturedDuringSessionID == first.sessionID)
        var record = first.record(now: start.addingTimeInterval(60), tick: 60, boot: "local")
        record.finishedAt = start.addingTimeInterval(60)
        journal.sessions = [record]
        let later = ActiveSession(openSprintSeconds: 120, now: start.addingTimeInterval(80), tick: 80, boot: "local")
        journal.beginLocalSession(later)
        var loaded = try JournalArchive.readDatabase(JournalArchive.database(journal))
        loaded.importSharedCaptures([saved])
        #expect(loaded.tasks.first?.capturedDuringSessionID == first.sessionID)
        var remote = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        remote.importSharedCaptures([saved])
        #expect(remote.localSprintStarts == nil && remote.tasks.first?.capturedDuringSessionID == nil)
        remote.observeLocalSession(at: start.addingTimeInterval(200))
        let beforeRestore = try SharedCapture(text: "Before restore", url: nil, created: start.addingTimeInterval(100), distraction: true)
        let afterRestore = try SharedCapture(text: "After restore", url: nil, created: start.addingTimeInterval(250), distraction: true)
        remote.importSharedCaptures([beforeRestore, afterRestore])
        #expect(remote.tasks.first { $0.id == beforeRestore.id }?.capturedDuringSessionID == nil)
        #expect(remote.tasks.first { $0.id == afterRestore.id }?.capturedDuringSessionID == later.sessionID)
        #expect(!String(decoding: try SharedJournal(journal).encoded(), as: UTF8.self).contains("localSprintStarts"))
        journal.beginLocalSession(ActiveSession(openSprintSeconds: 120, now: start, tick: 0, boot: "local"))
        journal.importSharedCaptures([saved])
        #expect(journal.tasks.first?.capturedDuringSessionID == nil)
    }
}
