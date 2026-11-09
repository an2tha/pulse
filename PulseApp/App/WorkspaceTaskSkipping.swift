import Foundation
import PulseEngine

struct TaskSkipCandidate: Identifiable, Equatable {
    let taskID: UUID
    let title: String
    let scheduledStart: Date
    let epoch: UUID
    let session: ActiveSession?
    var id: UUID { taskID }
}

enum TaskSkipError: LocalizedError {
    case changed, invalidSurvey, missingReason

    var errorDescription: String? {
        switch self {
        case .changed: "This task’s schedule has changed. Reopen the survey from its current schedule."
        case .missingReason: "Add a short note about why you skipped this task."
        case .invalidSurvey: "Choose an energy rating from 0 to 10 and keep your note within 500 characters."
        }
    }
}

extension Workspace {
    func skipCandidate(for taskID: UUID, at clock: Date = .now) -> TaskSkipCandidate? {
        guard ready, !restoring, let task = journal.tasks.first(where: { $0.id == taskID }) else { return nil }
        return skipCandidate(task, at: clock)
    }

    func skipCandidates(at clock: Date = .now) -> [TaskSkipCandidate] {
        guard ready, !restoring else { return [] }
        return journal.tasks.compactMap { skipCandidate($0, at: clock) }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }

    private func skipCandidate(_ task: PlanTask, at clock: Date) -> TaskSkipCandidate? {
        let session = journal.active.flatMap { $0.taskID == task.id && !$0.isOpenSprint ? $0 : nil }
        guard let start = TaskSkipping.eligibleStart(for: task, automaticStart: journal.automaticTaskStarts?[task.id],
                                                      activeStart: session?.started, at: clock) else { return nil }
        return TaskSkipCandidate(taskID: task.id, title: task.title, scheduledStart: start, epoch: journalEpoch, session: session)
    }

    func skipTask(_ candidate: TaskSkipCandidate, reason: TaskSkipReason, energy: Int, focus: Int? = nil,
                  notes: String = "", at clock: Date = .now) throws {
        guard ready, !restoring, let task = journal.tasks.first(where: { $0.id == candidate.taskID }),
              skipCandidate(task, at: clock) == candidate else { throw TaskSkipError.changed }
        let seriesID = task.seriesID ?? ((task.repeated ?? .once) != .once ? task.id : nil)
        let record = TaskSkipRecord(taskID: candidate.taskID, title: candidate.title, scheduledStart: candidate.scheduledStart,
                                    skippedAt: clock, reason: reason, energy: energy, focus: focus, notes: notes, seriesID: seriesID)
        if reason == .other && record.notes.isEmpty { throw TaskSkipError.missingReason }
        guard record.isValid else { throw TaskSkipError.invalidSurvey }
        var updated = journal
        if let session = candidate.session {
            updated.recordFinishedSession(session, done: false, at: clock)
        }
        guard TaskSkipping.skip(candidate.taskID, in: &updated.tasks, scheduledStart: candidate.scheduledStart,
                                at: clock, activeStart: candidate.session?.started) else { throw TaskSkipError.changed }
        change { journal in
            journal = updated
            journal.automaticTaskStarts?.removeValue(forKey: candidate.taskID)
            if journal.automaticTaskStarts?.isEmpty == true { journal.automaticTaskStarts = nil }
            if journal.nextTaskID == candidate.taskID { journal.nextTaskID = nil }
            journal.taskSkips = (journal.taskSkips ?? []) + [record]
        }
    }
}
