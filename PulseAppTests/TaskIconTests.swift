import Foundation
import PulseEngine
import Testing
@testable import Pulse

struct TaskIconTests {
    @Test func customIconsRoundTripAndCarryIntoTemplatesAndRoutines() throws {
        var task = PlanTask("Plant the bulbs", minutes: 10)
        let original = task
        task.icon = .character("👩🏽‍🌾")
        var journal = Journal()
        journal.tasks = [task]
        journal.templates = [task.duplicate()]
        let saved = try JournalArchive.readDatabase(JournalArchive.database(journal))
        #expect(saved.tasks.first?.icon == task.icon && saved.templates?.first?.icon == task.icon)
        #expect(task.applyingEdits(from: original, to: original, at: .now).icon == task.icon)
        #expect(original.applyingEdits(from: original, to: task, at: .now).icon == task.icon)
        var routine = task
        routine.repeated = .daily
        routine.done = true
        routine.completedAt = .now
        var tasks = [routine]
        TaskRoutines.advance(&tasks, at: .now)
        #expect(tasks.count == 2 && tasks.last?.icon == task.icon)

        #expect(TaskIcon.symbol("music.note").isValid)
        #expect(!TaskIcon.character("ab").isValid && !TaskIcon.character(" ").isValid)
    }
}
