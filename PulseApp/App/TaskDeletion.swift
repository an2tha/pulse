import Foundation
import PulseEngine

extension Workspace {
    /// Remove the task from scheduling. Session and photo records keep their own task IDs and titles.
    @discardableResult
    func deleteTask(_ displayed: PlanTask, in epoch: UUID) -> Bool {
        guard ready, !restoring, journalEpoch == epoch,
              let current = journal.tasks.first(where: { $0.id == displayed.id }),
              current == displayed else {
            notice = "This task changed. Open it again to delete it."
            return false
        }
        guard journal.active?.taskID != current.id else {
            notice = "Finish the active session before deleting its task."
            return false
        }
        change { journal in
            journal.tasks.removeAll { $0.id == current.id }
            if journal.nextTaskID == current.id { journal.nextTaskID = nil }
            journal.taskOrder?.removeAll { $0 == current.id }
            if journal.inboxUndo?.taskID == current.id { journal.inboxUndo = nil }
            for index in journal.tasks.indices where journal.tasks[index].dependency == current.id {
                journal.tasks[index].dependency = nil
            }
        }
        if lastListCompletion?.taskID == current.id { lastListCompletion = nil }
        if lastTimeMove?.taskID == current.id { lastTimeMove = nil }
        return true
    }

    func deletionDetail(for task: PlanTask) -> String {
        var details: [String] = []
        if !task.done, let recurrence = task.repeated, recurrence != .once {
            details.append("This also ends future repeats.")
        }
        let dependents = journal.tasks.filter { $0.dependency == task.id && !$0.done && $0.archived != true }
        if let first = dependents.first {
            details.append(dependents.count == 1
                ? "“" + first.title + "” will no longer depend on it."
                : "\(dependents.count) tasks will no longer depend on it.")
        }
        return details.joined(separator: " ")
    }
}
