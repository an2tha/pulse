import Foundation
import PulseEngine
import Testing
@testable import Pulse

struct TaskEditingTests {
    @Test func savingNotesPreservesNewTimingProgressAndForeignFields() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var original = PlanTask("Old reminder", minutes: 20)
        original.inboxOnly = true
        var draft = original
        draft.notes = "Leave the parcel by the door"
        var fresh = original
        fresh.title = "Updated reminder"
        fresh.due = start.addingTimeInterval(7200)
        fresh.inboxOnly = nil
        fresh.moveOccurrence(to: start.addingTimeInterval(3600))
        fresh.recordFocus(seconds: 75, completed: false)
        fresh.setResumeNote("Take the parcel")
        let saved = draft.applyingEdits(from: original, to: fresh, at: start)
        var expected = fresh
        expected.notes = draft.notes
        #expect(saved == expected && saved.remainingSeconds == fresh.remainingSeconds)
    }

    @Test func independentStepEditsAndNewlyAddedFocusStepsSurvive() {
        var original = PlanTask("Prepare garden", minutes: 15)
        let soil = TaskStep("Buy soil"), pot = TaskStep("Clean pot"), extra = TaskStep("Get a trowel")
        original.steps = [soil, pot]
        var draft = original
        draft.steps?[0].title = "Buy potting soil"
        draft.steps?.removeLast()
        let label = TaskStep("Label the seeds")
        draft.steps?.append(label)
        var fresh = original
        fresh.steps?[0].done = true
        fresh.steps?.insert(extra, at: 0)
        let saved = draft.applyingEdits(from: original, to: fresh, at: .now)
        #expect(saved.steps?.map(\.id) == [extra.id, soil.id, label.id])
        #expect(saved.steps?[1].done == true && saved.steps?[1].title == "Buy potting soil")
    }

    @Test func newExplicitEstimateOverridesOnlyTheEditedFields() {
        var original = PlanTask("Find a room", minutes: 20)
        original.setResumeNote("Ask at the desk")
        var draft = original
        draft.minutes = 30
        draft.setResumeNote("")
        var current = original
        current.project = "Studio"
        current.recordFocus(seconds: 40, completed: false)
        let saved = draft.applyingEdits(from: original, to: current, at: .now)
        #expect(saved.remainingSeconds == 1800 && saved.originalMinutes == 30)
        #expect(saved.focusedSeconds == 40 && saved.project == "Studio" && saved.resumeNote == nil)
    }
}
