import Foundation
import PulseEngine

struct PreparationAttachment: Identifiable {
    let id = UUID()
    let taskID: UUID
    let link: TaskPreparation
    let priorHold: Bool?
    let epoch: UUID
}

extension Workspace {
    func preparationLink(for block: Block, at date: Date = .now) -> TaskPreparation? {
        guard case .fixed(let id) = block.kind,
              let commitment = planningEvents.first(where: { $0.id == id }) else { return nil }
        return TaskPreparation(block: block, commitment: commitment, after: date)
    }

    func preparationTask(for link: TaskPreparation) -> PlanTask? {
        journal.tasks.first { $0.archived != true && $0.preparation?.sameOccurrence(as: link) == true }
    }

    func preparationTasks(for link: TaskPreparation) -> [PlanTask] {
        journal.tasks.filter { $0.archived != true && $0.preparation?.sameOccurrence(as: link) == true }
    }

    func canAttachPreparation(_ task: PlanTask) -> Bool {
        !task.done && task.archived != true && task.preparation == nil && task.id != journal.active?.taskID
    }

    /// Reuse the chosen task, keeping its checklist, photos and independent timing.
    func attachPreparation(taskID: UUID, to link: TaskPreparation, at date: Date = .now) -> PreparationAttachment? {
        guard ready, !restoring, let start = link.resolvedStart(in: planningEvents), start > date,
              let index = journal.tasks.firstIndex(where: { $0.id == taskID }),
              canAttachPreparation(journal.tasks[index]) else { return nil }
        let current = link.refreshed(in: planningEvents)
        let receipt = PreparationAttachment(taskID: taskID, link: current, priorHold: journal.tasks[index].inboxOnly,
                                            epoch: journalEpoch)
        change {
            $0.tasks[index].preparation = current
            $0.tasks[index].inboxOnly = nil
        }
        latestPrepAttachmentID = receipt.id
        return receipt
    }

    @discardableResult
    func undoPreparationAttachment(_ receipt: PreparationAttachment) -> Bool {
        guard ready, !restoring, receipt.epoch == journalEpoch, latestPrepAttachmentID == receipt.id,
              journal.active?.taskID != receipt.taskID,
              let index = journal.tasks.firstIndex(where: { $0.id == receipt.taskID && !$0.done && $0.archived != true }),
              journal.tasks[index].preparation?.sameOccurrence(as: receipt.link) == true else { return false }
        change {
            $0.tasks[index].preparation = nil
            if !$0.tasks[index].hasSchedulingInstruction { $0.tasks[index].inboxOnly = receipt.priorHold }
        }
        latestPrepAttachmentID = nil
        return true
    }

    @discardableResult
    func addPreparation(for link: TaskPreparation, minutes: Int = 10, at date: Date = .now) -> PlanTask? {
        guard ready, !restoring, (1...1440).contains(minutes) else { return nil }
        if let existing = preparationTask(for: link) { return existing }
        let events = planningEvents
        guard let event = events.first(where: { $0.id == link.commitmentID }),
              let start = link.resolvedStart(in: events), date < start else { return nil }
        var prep = PlanTask("Prepare for " + event.title, minutes: minutes, category: .focus)
        prep.preparation = link.refreshed(in: events)
        change { journal in
            journal.tasks.append(prep)
            journal.starterAvailable = false
        }
        recentPrep = prep.id
        return prep
    }

    func canUndoAddedPreparation(_ snapshot: PlanTask) -> Bool {
        guard ready, !restoring, recentPrep == snapshot.id, snapshot.preparation != nil,
              !snapshot.done, journal.active?.taskID != snapshot.id, journal.nextTaskID != snapshot.id,
              journal.tasks.first(where: { $0.id == snapshot.id }) == snapshot else { return false }
        return !journal.tasks.contains { $0.dependency == snapshot.id }
            && !journal.sessions.contains { $0.taskID == snapshot.id }
            && journal.photos?.contains { $0.taskID == snapshot.id } != true
            && journal.taskOrder?.contains(snapshot.id) != true
    }

    @discardableResult
    func undoAddedPreparation(_ snapshot: PlanTask) -> Bool {
        guard canUndoAddedPreparation(snapshot) else { return false }
        change { journal in
            journal.tasks.removeAll { $0.id == snapshot.id }
        }
        recentPrep = nil
        return true
    }

    /// Remember a moved appointment even if its calendar later becomes unavailable.
    @discardableResult
    func refreshPreparationLinks() -> Bool {
        guard journal.tasks.contains(where: { !$0.done && $0.preparation != nil }) else { return false }
        let events = planningEvents
        var changed = false
        for index in journal.tasks.indices where !journal.tasks[index].done {
            guard let link = journal.tasks[index].preparation else { continue }
            let updated = link.refreshed(in: events)
            if updated != link {
                journal.tasks[index].preparation = updated
                changed = true
            }
        }
        return changed
    }
}
