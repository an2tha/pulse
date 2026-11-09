import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor struct AgendaReorderTests {
    @Test func droppingFirstTaskOnLastMovesItPastThatTaskAndRetainsHiddenPreferences() async throws {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        let first = PlanTask("First", minutes: 5, category: .personal)
        let last = PlanTask("Last", minutes: 5, category: .personal)
        let hidden = UUID()
        store.journal.tasks = [first, last]
        store.journal.taskOrder = [first.id, last.id, hidden]
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: .now))
        store.now = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow))
        for _ in 0..<100 where !store.planReadyForOpenSprint { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.blocks.compactMap { if case .task(let id) = $0.kind { id } else { nil } } == [first.id, last.id])
        store.reorder(first.id, toPositionOf: last.id)
        #expect(store.journal.taskOrder == [last.id, first.id, hidden])
    }
}
