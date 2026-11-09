import Foundation
import PulseEngine

extension Workspace {
    /// A short start uses the current plan and the same boundary checks as a full session.
    @discardableResult
    func startSmall(taskID: UUID? = nil, at date: Date = .now) -> Bool {
        guard ready, !restoring, journal.active == nil else { return false }
        now = date
        guard !isRestDay, let (task, block) = next,
              taskID == nil || taskID == task.id, canStart(block) else {
            return taskID == nil && startOpenSprint(at: date)
        }

        let step = task.nextSmallStep ?? TaskStep(
            TaskBreakdown.suggestions(for: task).first ?? task.title)
        start(task, block: block, minutes: min(2, block.minutes), step: step, at: date)
        return journal.active?.stepID == step.id
    }
}
