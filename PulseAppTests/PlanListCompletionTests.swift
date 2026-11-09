import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor struct PlanListCompletionTests {
    private func workspace(_ tasks: [PlanTask]) -> Workspace {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.tasks = tasks
        return store
    }

    @Test func undoReopensOnlyCompletionFieldsAndCannotReplayAfterRestore() async throws {
        var task = PlanTask("Read", minutes: 5)
        var finishedStep = TaskStep("Choose book")
        finishedStep.done = true
        task.steps = [finishedStep, TaskStep("Read a page")]
        let store = workspace([task])
        #expect(store.completeFromPlan(task))
        #expect(store.taskCompletion?.taskID == task.id)
        let receipt = try #require(store.lastListCompletion)
        #expect(store.journal.tasks[0].steps?.allSatisfy(\.done) == true)
        store.change {
            $0.tasks[0].title = "Read a poem"
            $0.tasks[0].steps?[1].title = "Read one poem"
            $0.tasks[0].steps?.append(TaskStep("Reflect"))
        }
        #expect(store.undoListCompletion(receipt))
        #expect(store.taskCompletion == nil)
        #expect(!store.journal.tasks[0].done && store.journal.tasks[0].title == "Read a poem")
        #expect(store.journal.tasks[0].steps?.map(\.done) == [true, false, false])
        #expect(store.journal.tasks[0].steps?[1].title == "Read one poem")
        #expect(!store.undoListCompletion(receipt))
        #expect(!store.completeFromPlan(task))
        #expect(store.completeFromPlan(store.journal.tasks[0]))
        let stale = try #require(store.lastListCompletion)
        try await store.restoreJournal(store.journal)
        #expect(!store.undoListCompletion(stale))
        #expect(store.journal.tasks[0].done)
    }

    @Test func dependenciesAndFocusProtectLaterWork() throws {
        let prep = PlanTask("Prepare", minutes: 3)
        var review = PlanTask("Review", minutes: 5)
        review.dependency = prep.id
        let store = workspace([prep, review])
        #expect(!store.completeFromPlan(review))
        #expect(store.taskCompletion == nil)
        store.journal.active = ActiveSession(task: prep, minutes: 3, now: .now, tick: 1, boot: nil)
        #expect(!store.completeFromPlan(prep))
        store.journal.active = nil
        #expect(store.completeFromPlan(prep))
        let receipt = try #require(store.lastListCompletion)
        store.journal.active = ActiveSession(task: review, minutes: 5, now: .now, tick: 1, boot: nil)
        #expect(!store.undoListCompletion(receipt))
        #expect(store.journal.tasks[0].done)
        store.journal.active = nil
        #expect(store.completeFromPlan(review))
        #expect(!store.undoListCompletion(receipt))
    }

    @Test func routineRewiresAreReversibleUntilTheSuccessorAcquiresWork() throws {
        var source = PlanTask("Prepare notes", minutes: 5)
        source.repeated = .daily
        var dependent = PlanTask("Read notes", minutes: 5)
        dependent.dependency = source.id
        dependent.routineAnchor = Calendar.current.date(byAdding: .day, value: 1, to: .now)
        let store = workspace([source, dependent])
        #expect(store.completeFromPlan(source))
        let first = try #require(store.lastListCompletion)
        let next = try #require(store.journal.tasks.last)
        #expect(next.seriesID == source.id && store.journal.tasks[1].dependency == next.id)
        #expect(store.undoListCompletion(first))
        #expect(store.journal.tasks == [source, dependent])
        #expect(store.completeFromPlan(source))
        let again = try #require(store.lastListCompletion)
        #expect(store.journal.tasks.count == 3)
        store.change { $0.tasks[2].notes = "Keep this" }
        #expect(!store.undoListCompletion(again))
        #expect(store.notice == "The next occurrence has already changed.")
        #expect(store.journal.tasks[2].notes == "Keep this")
    }

    @Test func practiceUndoRemovesOnlyTheLogItCreated() throws {
        var practice = WeeklyPractice("Sketch")
        let task = try #require(practice.session(for: .now, tasks: []))
        let store = workspace([task])
        store.journal.practices = [practice]
        #expect(store.completeFromPlan(task))
        let receipt = try #require(store.lastListCompletion)
        #expect(store.journal.practices?[0].logs.first?.taskID == task.id)
        #expect(store.undoListCompletion(receipt))
        #expect(store.journal.practices?[0].logs.isEmpty == true)
        practice.log(at: .now)
        store.journal.practices = [practice]
        #expect(store.completeFromPlan(task))
        let direct = try #require(store.lastListCompletion)
        #expect(store.undoListCompletion(direct))
        #expect(store.journal.practices?[0].logs == practice.logs)
    }
}
