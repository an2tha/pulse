import Foundation

extension TaskRoutines {
    /// A future preview is detached by nominal identity. A materialized routine hands its
    /// cadence to its successor before its current occurrence becomes an ordinary to-do.
    @discardableResult public static func returnToDrawer(_ id: UUID, in tasks: inout [PlanTask],
                                                         projected: PlanTask?, from day: Date,
                                                         at now: Date, calendar: Calendar = .current) -> Bool {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            let task = tasks[index]
            guard !task.done, task.archived != true, !task.isInboxOnly else { return false }
            if let rule = task.repeated, rule != .once {
                if task.routineAnchor == nil {
                    tasks[index].routineAnchor = task.plannedStart ?? task.after ?? calendar.startOfDay(for: day)
                }
                advance(&tasks, at: now, calendar: calendar, releasing: id)
            }
            tasks[index] = held(task)
        } else {
            guard let preview = projected, preview.id == id, let key = preview.occurrence(in: calendar),
                  let nominal = key.day(in: calendar),
                  let owner = tasks.firstIndex(where: { $0.owns(key) }) else { return false }
            let skip = RoutineException(occurrence: key, start: nominal, detached: true)
            tasks[owner].setException(skip, for: key, calendar: calendar)
            guard tasks[owner].routineExceptions?.contains(skip) == true else { return false }
            tasks.append(held(preview))
        }
        return true
    }

    private static func held(_ original: PlanTask) -> PlanTask {
        var task = original
        task.repeated = nil
        task.repeatDays = nil
        task.seriesID = nil
        task.seriesAdvanced = nil
        task.routineAnchor = nil
        task.routineExceptions = nil
        task.movedRoutineTimes = nil
        task.plannedStart = nil
        task.assignedFocusBlockID = nil
        task.timelineDurations = nil
        task.inboxOnly = true
        return task
    }
}
