import Foundation
import Testing
@testable import PulseEngine

@Suite struct ResumeNoteTests {
    @Test func olderTasksAndDuplicatesHaveNoResumeNote() throws {
        var task = PlanTask("Review chapter", minutes: 12)
        let legacy = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(PlanTask.self, from: legacy).resumeNote == nil)
        task.setResumeNote("  Begin at page 12.\n")
        let saved = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(task))
        #expect(saved.resumeNote == "Begin at page 12.")
        #expect(saved.duplicate().resumeNote == nil)

        task.repeated = .daily
        task.done = true
        var tasks = [task]
        TaskRoutines.advance(&tasks, at: .now)
        try #require(tasks.count == 2)
        #expect(tasks[0].resumeNote == saved.resumeNote)
        #expect(tasks[1].resumeNote == nil)
    }

    @Test func clearingAndLimitingNotes() {
        var task = PlanTask("Read", minutes: 5)
        task.setResumeNote(String(repeating: "🌱", count: 250))
        #expect(task.resumeNote?.count == PlanTask.resumeNoteLimit)
        task.setResumeNote(" \n\t")
        #expect(task.resumeNote == nil)
    }

    @Test func pinnedStepSurvivesEditsAndStopsAtOccurrenceBoundary() throws {
        var task = PlanTask("Paint a landscape", minutes: 15)
        let sky = TaskStep("Paint the sky")
        let trees = TaskStep("Paint the trees")
        task.steps = [sky, trees]
        task.rememberStep(trees.id)
        task = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(task))
        #expect(task.nextSmallStep?.id == trees.id)
        task.steps?[1].title = "Paint the evergreens"
        #expect(task.resumeStep?.title == "Paint the evergreens")
        #expect(task.duplicate().resumeStep == nil)
        var routine = task
        routine.repeated = .daily
        routine.done = true
        var tasks = [routine]
        TaskRoutines.advance(&tasks, at: .now)
        #expect(tasks.last?.resumeStep == nil)
        task.steps?[1].done = true
        #expect(task.resumeStep == nil && task.nextSmallStep?.id == sky.id)
        task.steps?.removeLast()
        #expect(task.resumeStep == nil)
    }
}
