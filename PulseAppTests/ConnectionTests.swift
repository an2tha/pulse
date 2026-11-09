import Foundation
import PulseEngine
import Testing

@testable import Pulse

@MainActor
struct ConnectionTests {
    @Test func multiDayCalendarImportChecksLaterRecurringCommitments() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let tuesday = try #require(calendar.date(byAdding: .day, value: 1, to: monday))
        let existing = Commitment("Practice", start: tuesday, end: tuesday.addingTimeInterval(1800), recurrence: .weekly)
        let start = try #require(calendar.date(byAdding: .day, value: 7, to: monday))
        let end = try #require(calendar.date(byAdding: .day, value: 2, to: start))
        let event = CalendarCandidate(id: UUID(), title: "Trip", calendar: "Home", start: start, end: end)
        #expect(event.overlaps(existing, calendar: calendar))
        #expect(!event.overlaps(Commitment("After trip", start: end, end: end.addingTimeInterval(3600)), calendar: calendar))
    }

    @Test func connectedCalendarReconcilesChangedAndDeletedOccurrencesWithoutEditingTheJournal() {
        let originalTime = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "event|calendar|single|"
        var legacy = Commitment("Imported snapshot", start: originalTime, end: originalTime.addingTimeInterval(3600))
        legacy.id = CalendarBridge.stableID(key + String(originalTime.timeIntervalSince1970))
        let movedTime = originalTime.addingTimeInterval(7200)
        let moved = CalendarCandidate(id: CalendarBridge.stableID(key), title: "Moved", calendar: "Work",
                                      start: movedTime, end: movedTime.addingTimeInterval(3600), singleEventKey: key)
        let independent = Commitment("Independent", start: originalTime, end: originalTime.addingTimeInterval(900))
        let journal = [legacy, independent]
        #expect(moved.matchingCopy(in: journal) == legacy.id)
        let connected = LiveCalendarReader.merging([moved.commitment], with: journal, trackedCopies: [legacy.id])
        #expect(connected == [independent, moved.commitment])
        #expect(LiveCalendarReader.merging([], with: journal, trackedCopies: [legacy.id]) == [independent])
        #expect(LiveCalendarReader.merging([], with: journal, trackedCopies: []) == journal)
    }

    @Test func assistantRequiresReviewAndRevalidatesTargets() async throws {
        var journal = Journal()
        let date = Date.now
        let input = "School from 9am to 3pm every weekday, study chemistry for 20 minutes"
        let (proposal, _) = try await AssistantPlanner.propose(input, journal: journal, blocks: [], now: date)
        #expect(journal.tasks.isEmpty)
        try proposal.apply(to: &journal)
        try proposal.apply(to: &journal)
        #expect(journal.tasks.count == 1 && journal.events.count == 1)
        #expect(journal.events.first?.recurrence == .weekdays)
        let (move, _) = try await AssistantPlanner.propose(
            "Move chemistry to tomorrow", journal: journal, blocks: [], now: date)
        journal.tasks[0].title = "Revised chemistry task"
        #expect(throws: AssistantFailure.self) { try move.apply(to: &journal) }
        let (steps, _) = try await AssistantPlanner.propose(
            "Break down chemistry", journal: journal, blocks: [], now: date)
        try steps.apply(to: &journal)
        #expect(journal.tasks[0].steps?.count == 3)
    }

    @Test func ambiguousCommandsAskWhichTask() async throws {
        var journal = Journal()
        journal.tasks = [PlanTask("Study chemistry", minutes: 12), PlanTask("Study geology", minutes: 10)]
        let (reply, _) = try await AssistantPlanner.propose(
            "Move study to tomorrow", journal: journal, blocks: [], now: .now)
        guard case .choose(let choices, _) = reply else {
            Issue.record("Expected clarification")
            return
        }
        #expect(choices.count == 2)
        #expect(throws: AssistantFailure.self) { try reply.apply(to: &journal) }
    }

    @Test func encryptedCopiesRejectTamperingAndPreserveConflicts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try dir.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let key = Data(repeating: 19, count: 32)
        var j = Journal()
        j.tasks = [PlanTask("Private project notes", minutes: 5)]
        let original = SharedJournal(j)
        var a = VaultLink(bookmark: bookmark)
        guard
            case .linked(let first, let digest) = try VaultIO.exchange(
                link: a, key: key, local: original, choice: .create)
        else {
            Issue.record("Expected initial revision")
            return
        }
        a.revision = first
        a.digest = digest
        let root = dir.appendingPathComponent("Pulse Sync")
        let cipher = try Data(contentsOf: root.appendingPathComponent(first.uuidString + ".pulsevault"))
        #expect(cipher.range(of: Data("Private project notes".utf8)) == nil)
        #expect(throws: (any Error).self) {
            try VaultIO.exchange(link: a, key: Data(repeating: 12, count: 32), local: original, choice: .normal)
        }
        j.tasks[0].minutes = 7
        guard case .linked = try VaultIO.exchange(link: a, key: key, local: SharedJournal(j), choice: .normal) else {
            Issue.record("Expected update")
            return
        }
        guard case .pull(let newHead, _) = try VaultIO.exchange(link: a, key: key, local: original, choice: .normal)
        else {
            Issue.record("Expected clean pull")
            return
        }
        #expect(newHead.content.tasks[0].minutes == 7)
        j.tasks[0].minutes = 9
        guard
            case .conflict(let heads) = try VaultIO.exchange(
                link: a, key: key, local: SharedJournal(j), choice: .normal)
        else {
            Issue.record("Expected conflict")
            return
        }
        #expect(heads.first?.id == newHead.id)
        guard
            case .linked = try VaultIO.exchange(
                link: a, key: key, local: SharedJournal(j), choice: .keepLocal(Set(heads.map(\.id))))
        else {
            Issue.record("Expected reviewed resolution")
            return
        }
        #expect(throws: VaultError.self) {
            try VaultIO.exchange(link: a, key: key, local: original, choice: .take(newHead.id, [newHead.id]))
        }
        let manifest = root.appendingPathComponent(first.uuidString + ".pulselink")
        var damaged = try Data(contentsOf: manifest)
        damaged[0] ^= 1
        try damaged.write(to: manifest)
        #expect(throws: VaultError.self) { try VaultIO.exchange(link: a, key: key, local: original, choice: .normal) }
    }
}
