import Foundation

extension PlanTask {
    /// A task's demand stays stable as today's available energy changes.
    public var energyDemand: Double {
        if let energyOverride { return Capacity.scale(energyOverride) }
        let duration = min(10, Double(originalMinutes ?? minutes) / 5)
        return Capacity.scale(0.52 * effort + 0.24 * duration + 0.12 * setup + 0.12 * overwhelm
            + (category == .recovery ? -2 : 0))
    }

    public func energyCost(at capacity: Double) -> Int {
        Int(Capacity.scale(energyDemand + (5 - Capacity.scale(capacity)) * 0.45).rounded())
    }
}

public enum TodoDump {
    public static func tasks(from text: String, at date: Date = .now, calendar: Calendar = .current, commitments: [Commitment] = []) -> [PlanTask] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(?:[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let draft = LocalDayInput.parse(line, at: date, calendar: calendar, commitments: commitments)
            let parsed = draft.tasks.count == 1 && draft.commitments.isEmpty && draft.unrecognized.isEmpty
            var task = parsed ? draft.tasks[0] : PlanTask(line, minutes: 10, category: .personal)
            let words = Set(task.title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            if !words.isDisjoint(with: ["research", "design", "analyze", "debug", "study", "draft"]) { task.effort = 8 }
            else if !words.isDisjoint(with: ["water", "pack", "file", "rinse", "print", "stretch"]) { task.effort = 2 }
            return task
        }
    }
}
