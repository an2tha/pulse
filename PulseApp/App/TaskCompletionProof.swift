import Foundation
import PulseEngine

struct CompletionProofRequest: Identifiable, Equatable {
    let id = UUID()
    let taskID: UUID
    let epoch: UUID
    let sessionID: UUID?
    let sessionStart: Date?

    init(taskID: UUID, epoch: UUID, session: ActiveSession? = nil) {
        self.taskID = taskID
        self.epoch = epoch
        sessionID = session?.sessionID
        sessionStart = session?.started
    }
}

enum CompletionProofError: LocalizedError {
    case changed, invalidPhoto, full, blocked(String)
    var errorDescription: String? {
        switch self {
        case .changed: "This task or focus session changed. Open the task again."
        case .invalidPhoto: "Choose a readable photo."
        case .full: "Picture log is full. Remove an older photo first."
        case .blocked(let reason): reason
        }
    }
}

extension Journal {
    func needsCompletionPhoto(for task: PlanTask) -> Bool {
        guard photoProofEnabled != false, task.requiresPhotoProof == true else { return false }
        return !(photos ?? []).contains { $0.taskID == task.id && $0.completion && $0.isSafeImage }
    }
}

extension Workspace {
    func needsCompletionPhoto(for task: PlanTask) -> Bool { journal.needsCompletionPhoto(for: task) }

    func needsCompletionPhoto(for session: ActiveSession) -> Bool {
        guard !session.isOpenSprint,
              let task = journal.tasks.first(where: { $0.id == session.taskID && !$0.done }),
              needsCompletionPhoto(for: task) else { return false }
        guard let step = session.stepID else { return true }
        guard let steps = task.steps, steps.contains(where: { $0.id == step }) else { return false }
        return steps.allSatisfy { $0.id == step || $0.done }
    }

    @discardableResult func requestProofIfNeeded(for task: PlanTask) -> Bool {
        guard !task.done, needsCompletionPhoto(for: task) else { return false }
        pendingCompletionProof = CompletionProofRequest(taskID: task.id, epoch: journalEpoch)
        return true
    }

    func completeWithProof(_ request: CompletionProofRequest, jpeg: Data) throws {
        guard ready, !restoring, request.epoch == journalEpoch, pendingCompletionProof == request,
              let task = journal.tasks.first(where: { $0.id == request.taskID && !$0.done && $0.archived != true })
        else { throw CompletionProofError.changed }

        let photo = JournalPhoto(taskID: task.id, title: task.title, completion: true, jpeg: jpeg)
        guard photo.isSafeImage else { throw CompletionProofError.invalidPhoto }
        guard JournalPhoto.fits(jpeg, in: journal) else { throw CompletionProofError.full }
        if let start = request.sessionStart {
            guard let session = journal.active, session.taskID == task.id, session.started == start,
                  session.sessionID == request.sessionID,
                  session.stepID.map({ step in
                      task.steps?.contains(where: { $0.id == step }) == true &&
                          task.steps?.allSatisfy { $0.id == step || $0.done } == true
                  }) ?? true
            else { throw CompletionProofError.changed }
            finish(done: true, photo: photo)
        } else {
            if let obstacle = completionObstacle(task) { throw CompletionProofError.blocked(obstacle) }
            let before = journal
            change(celebrateCompletion: true) { journal in
                guard let index = journal.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                journal.photos = (journal.photos ?? []) + [photo]
                journal.tasks[index].done = true
            }
            lastListCompletion = PlanListCompletion(task: task, previous: before, current: journal, epoch: journalEpoch)
        }
        guard journal.tasks.contains(where: { $0.id == task.id && $0.done }) else { throw CompletionProofError.changed }
        pendingCompletionProof = nil
    }
}
