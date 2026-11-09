import Foundation
import PulseEngine

extension Journal {
    /// Old versions could persist the suggested intention, including by saving its editor unchanged.
    /// Match the original content and preserve any task that acquired work or references.
    @discardableResult mutating func retireLegacyStarter(_ original: PlanTask) -> Bool {
        let wasAvailable = starterAvailable
        starterAvailable = false
        let id = original.id
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return wasAvailable }
        let candidate = tasks[index]
        guard let steps = candidate.steps, steps.map(\.title) == original.steps?.map(\.title),
              steps.allSatisfy({ !$0.done }) else { return wasAvailable }

        // Step IDs and creation dates were generated afresh on each launch.
        var expected = original
        expected.createdAt = candidate.createdAt
        expected.steps = steps
        guard candidate == expected,
              active?.taskID != id, nextTaskID != id, taskOrder?.contains(id) != true,
              !tasks.contains(where: { $0.dependency == id || $0.seriesID == id }),
              !sessions.contains(where: { $0.taskID == id }),
              photos?.contains(where: { $0.taskID == id }) != true,
              planHistory?.contains(where: { $0.tasks.contains(id) }) != true,
              practices?.contains(where: { $0.logs.contains { $0.taskID == id } }) != true,
              templates?.contains(where: { $0.id == id || $0.dependency == id }) != true,
              captureDrafts?.reviewed.contains(where: { $0.id == id || $0.dependency == id }) != true,
              inboxUndo == nil, reminderImports?[id] == nil,
              connections?.published.keys.contains(where: { $0.hasPrefix(id.uuidString) }) != true
        else { return wasAvailable }
        tasks.remove(at: index)
        return true
    }
}
