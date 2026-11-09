import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor struct SkipTimeOfferTests {
    @Test func healthOffersThePlanPickAndRevalidatesBeforeMoving() async throws {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let start = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow))
        var task = PlanTask("Write notes", minutes: 8)
        task.after = start
        task.plannedStart = start

        var journal = Journal()
        journal.tasks = [task]
        journal.taskSkips = try [2, 4].map { offset in
            let missed = try #require(calendar.date(byAdding: .day, value: -offset, to: start))
            return TaskSkipRecord(taskID: task.id, title: task.title, scheduledStart: missed,
                                  skippedAt: missed.addingTimeInterval(300), reason: .interrupted, energy: 3)
        }
        store.journal = journal
        let pattern = try #require(store.skipPatterns(through: today).first)
        let offer = try #require(try await store.skipTimeSuggestion(for: pattern))
        let options = await store.weekPlacements(for: task.id)
        #expect(offer.start == options.first(where: \.recommended)?.start)
        #expect(store.journal.tasks[0].plannedStart == start)
        try await store.applySkipTimeSuggestion(offer)
        #expect(store.journal.tasks[0].plannedStart == offer.start)
        let receipt = try #require(store.undoableTimeMove(for: task.id))
        #expect(store.undoTimeMove(receipt))
        #expect(store.journal.tasks[0].plannedStart == start)
        store.change { journal in
            journal.events.append(Commitment("Meeting", start: offer.start,
                                             end: offer.start.addingTimeInterval(1800)))
        }
        await #expect(throws: (any Error).self) { try await store.applySkipTimeSuggestion(offer) }
        #expect(store.journal.tasks[0].plannedStart == start)
    }
}
