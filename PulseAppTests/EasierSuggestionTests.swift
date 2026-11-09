import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor @Suite struct EasierSuggestionTests {
    private var morning: Date { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)! }

    private func fixture() async -> (Workspace, PlanTask, PlanTask) {
        var original = PlanTask("Draft proposal", minutes: 20)
        original.steps = [TaskStep("Open the proposal")]
        original.energyOverride = 8
        var light = PlanTask("Water the fern", minutes: 5)
        light.steps = [TaskStep("Fill the watering can")]
        light.energyOverride = 2
        let store = Workspace()
        store.isDemo = true
        store.journal.tasks = [original, light]
        store.journal.nextTaskID = original.id
        store.ready = true
        store.now = morning
        await store.waitForCurrentPlan()
        return (store, original, light)
    }

    @Test func previewIsReversibleAndStartUsesFullEligibleAlternative() async throws {
        let (store, original, light) = await fixture()
        let before = store.journal
        let choice = try #require(store.easierSuggestion(for: original.id))
        #expect(choice.taskID == light.id && choice.title == light.title && choice.detail == "Fill the watering can")
        #expect(store.journal == before && store.next?.0.id == original.id)
        #expect(store.startEasierSuggestion(choice, at: morning))
        #expect(store.journal.active?.taskID == light.id && store.journal.active?.target == 300)
        #expect(store.journal.tasks[0] == original && store.journal.nextTaskID == original.id)
        #expect(store.startEasierSuggestion(choice, at: morning) == false)
    }

    @Test func unavailableAlternativeOffersTheOriginalConcreteStep() async throws {
        let (store, original, light) = await fixture()
        let choice = try #require(store.easierSuggestion(for: original.id))
        store.journal.tasks[1].dependency = original.id
        #expect(store.startEasierSuggestion(choice, at: morning) == false)
        let step = try #require(store.easierSuggestion(for: original.id))
        #expect(step.taskID != light.id && step.isStep && step.title == "Open the proposal" && step.minutes == 2)
        store.journal.tasks[1].dependency = nil
        store.journal.tasks[1].plannedStart = morning.addingTimeInterval(3600)
        #expect(store.easierSuggestion(for: original.id) == step)
        store.journal.tasks[1].plannedStart = nil
        store.journal.tasks[1].energyOverride = 9
        #expect(store.easierSuggestion(for: original.id) == step)
        #expect(store.startEasierSuggestion(step, at: morning))
        #expect(store.journal.active?.stepID == original.steps?.first?.id)
    }

    @Test func restRecoveryCommitmentsAndExhaustedBudgetDontOfferOrStart() async throws {
        let (store, original, _) = await fixture()
        let choice = try #require(store.easierSuggestion(for: original.id))
        store.journal.restDate = morning
        #expect(store.easierSuggestion(for: original.id) == nil)
        #expect(!store.startEasierSuggestion(choice, at: morning))
        store.journal.restDate = nil
        store.journal.recovery = DateInterval(start: morning, duration: 300)
        #expect(store.easierSuggestion(for: original.id) == nil)
        store.journal.recovery = nil
        store.journal.events = [Commitment("Arrival", start: morning, end: morning.addingTimeInterval(600))]
        #expect(store.easierSuggestion(for: original.id) == nil)
        store.journal.events = []
        store.journal.limit = 0
        #expect(store.easierSuggestion(for: original.id) == nil)
    }
}
