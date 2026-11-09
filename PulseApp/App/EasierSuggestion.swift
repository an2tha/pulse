import Foundation
import PulseEngine

struct EasierSuggestion: Equatable {
    let originalID: UUID
    let taskID: UUID
    let title: String
    let detail: String
    let minutes: Int
    var isStep: Bool { taskID == originalID }
}

extension Workspace {
    /// A suggestion is a preview. Only starting it creates or changes journal data.
    func easierSuggestion(for originalID: UUID) -> EasierSuggestion? {
        guard ready, !restoring, !isRestDay, journal.active == nil,
              let (original, block) = next, original.id == originalID, canStart(block) else { return nil }
        let energy = capacity
        let originalCost = original.energyCost(at: energy)
        // Test the small step as a possible fallback alongside full alternative tasks.
        var candidates = schedulingTasks
        guard let index = candidates.firstIndex(where: { $0.id == originalID }) else { return nil }
        let stepMinutes = min(2, block.minutes)
        candidates[index].minutes = stepMinutes
        let available = spareMoments(minutes: block.minutes, at: now, tasks: candidates)
        let tasks = Dictionary(uniqueKeysWithValues: offeredTasks.map { ($0.id, $0) })
        let alternatives = available.compactMap { option -> PlanTask? in
            guard case .task(let id) = option.kind, id != originalID, let task = tasks[id],
                  task.energyDemand <= energy, task.energyCost(at: energy) < originalCost else { return nil }
            return task
        }
        let best = alternatives.min { $0.energyDemand < $1.energyDemand }
        guard best != nil || available.contains(where: { $0.kind == .task(originalID) }) else { return nil }
        let task = best ?? original
        let small = task.nextSmallStep?.title ?? TaskBreakdown.suggestions(for: task).first ?? task.title
        let isStep = task.id == originalID
        return EasierSuggestion(originalID: originalID, taskID: task.id,
                                title: isStep ? small : task.title, detail: isStep ? task.title : small,
                                minutes: isStep ? stepMinutes : task.minutes)
    }

    func startEasierSuggestion(_ choice: EasierSuggestion, at date: Date = .now) -> Bool {
        now = date
        guard easierSuggestion(for: choice.originalID) == choice else { return false }
        if choice.isStep { return startSmall(taskID: choice.taskID, at: date) }
        return startSpareMoment(choice.taskID, minutes: choice.minutes, at: date)
    }
}
