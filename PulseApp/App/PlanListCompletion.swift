import Foundation
import PulseEngine

/// A local, one-action receipt. Only fields changed by checking the row are reversed.
struct PlanListCompletion: Identifiable {
    let id = UUID()
    let taskID: UUID
    let title: String
    let epoch: UUID
    private let before: PlanTask
    private let after: PlanTask
    private let successor: PlanTask?
    private let priorDependencies: [UUID: UUID]
    private let practiceLog: WeeklyPractice.Log?

    init?(task: PlanTask, previous: Journal, current: Journal, epoch: UUID) {
        guard let completed = current.tasks.first(where: { $0.id == task.id && $0.done }),
              completed.completedAt != nil else { return nil }
        taskID = task.id
        title = task.title
        self.epoch = epoch
        before = task
        after = completed
        let newOccurrence = completed.seriesID.flatMap { series in
            let previousIDs = Set(previous.tasks.map(\.id))
            return current.tasks.first { $0.seriesID == series && !previousIDs.contains($0.id) }
        }
        successor = newOccurrence
        if let newOccurrence {
            let changed = Set(current.tasks.filter { $0.dependency == newOccurrence.id }.map(\.id))
            priorDependencies = Dictionary(uniqueKeysWithValues: previous.tasks.compactMap { member in
                guard changed.contains(member.id), let old = member.dependency else { return nil }
                return (member.id, old)
            })
        } else {
            priorDependencies = [:]
        }
        let existingLogs = previous.practices?.first { $0.id == task.practiceID }?.logs ?? []
        practiceLog = current.practices?.first { $0.id == task.practiceID }?.logs.first {
            $0.taskID == task.id && !existingLogs.contains($0)
        }
    }

    func obstacle(in journal: Journal) -> String? {
        guard let task = journal.tasks.first(where: { $0.id == taskID }),
              task.done, task.completedAt == after.completedAt, task.archived != true,
              task.seriesID == after.seriesID, task.seriesAdvanced == after.seriesAdvanced,
              task.routineExceptions == after.routineExceptions, task.repeated == after.repeated,
              task.practiceID == after.practiceID else { return "This task changed after it was completed." }
        if journal.active?.taskID == taskID { return "Finish the active session first." }
        if let practice = task.practiceID, journal.tasks.contains(where: {
            $0.id != taskID && $0.practiceID == practice && !$0.done && $0.archived != true
        }) { return "A new session for this practice is already in your plan." }
        if let stamp = task.completedAt {
            let dependents = Set(journal.tasks.filter { candidate in
                candidate.dependency == taskID ||
                    (priorDependencies[candidate.id] != nil && candidate.dependency == successor?.id)
            }.map(\.id))
            if journal.active.map({ dependents.contains($0.taskID) }) == true ||
                journal.tasks.contains(where: { dependents.contains($0.id) && $0.done && ($0.completedAt ?? .distantPast) >= stamp }) ||
                journal.sessions.contains(where: { dependents.contains($0.taskID) && $0.start >= stamp }) {
                return "A dependent task has already started."
            }
        }
        if let successor {
            guard journal.tasks.first(where: { $0.id == successor.id }) == successor,
                  !hasWork(for: successor.id, in: journal) else { return "The next occurrence has already changed." }
            for linked in journal.tasks where linked.dependency == successor.id {
                guard let original = priorDependencies[linked.id], journal.tasks.contains(where: { $0.id == original }) else {
                    return "Another task now depends on the next occurrence."
                }
            }
        }
        return nil
    }

    private func hasWork(for id: UUID, in journal: Journal) -> Bool {
        journal.active?.taskID == id || journal.nextTaskID == id || journal.taskOrder?.contains(id) == true ||
            journal.inboxUndo?.taskID == id || journal.sessions.contains { $0.taskID == id } ||
            journal.photos?.contains { $0.taskID == id } == true ||
            journal.connections?.published.keys.contains { $0.hasPrefix(id.uuidString + "-") } == true
    }

    fileprivate func restore(in journal: inout Journal) {
        guard let index = journal.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        journal.tasks[index].done = false
        journal.tasks[index].completedAt = before.completedAt
        journal.tasks[index].seriesID = before.seriesID
        journal.tasks[index].seriesAdvanced = before.seriesAdvanced
        journal.tasks[index].routineExceptions = before.routineExceptions
        if let old = before.steps, var current = journal.tasks[index].steps {
            let reopened = Set(old.filter { !$0.done }.map(\.id))
            for i in current.indices where reopened.contains(current[i].id) { current[i].done = false }
            journal.tasks[index].steps = current
        }
        if let successor {
            for i in journal.tasks.indices where journal.tasks[i].dependency == successor.id {
                journal.tasks[i].dependency = priorDependencies[journal.tasks[i].id]
            }
            journal.tasks.removeAll { $0.id == successor.id }
        }
        if let practiceLog, let i = journal.practices?.firstIndex(where: { $0.id == before.practiceID }) {
            journal.practices?[i].removeLog(practiceLog)
        }
    }
}

extension Workspace {
    func completionObstacle(_ task: PlanTask) -> String? {
        if journal.active?.taskID == task.id { return "Finish the active session first." }
        if let required = task.dependency, !journal.tasks.contains(where: { $0.id == required && $0.done }) {
            let title = journal.tasks.first { $0.id == required }?.title ?? "the prerequisite"
            return "Complete \(title) first."
        }
        return nil
    }

    @discardableResult func completeFromPlan(_ displayed: PlanTask) -> Bool {
        guard ready, !restoring, !displayed.done, displayed.archived != true,
              offeredTasks.first(where: { $0.id == displayed.id }) == displayed else { return false }
        if let reason = completionObstacle(displayed) { notice = reason; return false }
        if requestProofIfNeeded(for: displayed) { return false }
        let previous = journal
        markDone(displayed)
        lastListCompletion = PlanListCompletion(task: displayed, previous: previous, current: journal, epoch: journalEpoch)
        return lastListCompletion != nil
    }

    @discardableResult func undoListCompletion(_ receipt: PlanListCompletion) -> Bool {
        guard ready, !restoring, receipt.epoch == journalEpoch, lastListCompletion?.id == receipt.id else { return false }
        if let reason = receipt.obstacle(in: journal) { notice = reason; return false }
        change { receipt.restore(in: &$0) }
        lastListCompletion = nil
        return true
    }
}
