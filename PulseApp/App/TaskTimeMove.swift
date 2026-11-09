import Foundation
import PulseEngine

/// Restores only the scheduling fields touched by a move. Notes, photos and
/// other task edits made while a timing sheet was open keep their new values.
struct TaskTimeMove: Identifiable, Equatable {
    let id = UUID()
    let taskID: UUID
    let sourceDay: Date
    let start: Date
    let title: String
    let projected: Bool
    private let change: Change

    private enum Change: Equatable {
        case timing(before: Timing, after: Timing)
        case exception(before: RoutineException?, after: RoutineException)
    }

    private struct Timing: Equatable {
        let pin: Date?
        let assignedFocusBlockID: UUID?
        let inboxOnly: Bool?
        let anchor: Date?
        let seriesPin: MovedRoutineTime?
        let availability: MovedRoutineTime?
        let recurrence: Recurrence?
        let durations: [TimelineTaskDuration]?

        init(_ task: PlanTask) {
            durations = task.timelineDurations
            pin = task.plannedStart
            assignedFocusBlockID = task.assignedFocusBlockID
            inboxOnly = task.inboxOnly
            anchor = task.routineAnchor
            seriesPin = task.movedRoutineTimes?.pin
            availability = task.movedRoutineTimes?.availability
            recurrence = task.repeated
        }
    }

    init?(from previous: PlanTask, to moved: PlanTask, sourceDay: Date) {
        guard previous.id == moved.id, let pin = moved.plannedStart else { return nil }
        let before = Timing(previous)
        let after = Timing(moved)
        guard before != after else { return nil }
        projected = false
        title = moved.title
        change = .timing(before: before, after: after)
        taskID = moved.id
        self.sourceDay = sourceDay
        start = pin
    }

    init?(before: RoutineException?, after: RoutineException, title: String, sourceDay: Date) {
        guard before != after else { return nil }
        self.title = title
        projected = true
        change = .exception(before: before, after: after)
        taskID = after.occurrence.id
        self.sourceDay = sourceDay
        start = after.start
    }

    func matches(_ task: PlanTask) -> Bool {
        switch change {
        case .timing(_, let after):
            task.id == taskID && !task.done && task.archived != true && Timing(task) == after
        case .exception(_, let expected):
            task.owns(expected.occurrence) && task.routineExceptions?.contains(expected) == true
        }
    }

    func wasRestored(in tasks: [PlanTask]) -> Bool {
        switch change {
        case .timing(let before, _):
            return tasks.first { $0.id == taskID }.map(Timing.init) == before
        case .exception(let previous, let expected):
            guard let owner = tasks.first(where: { $0.owns(expected.occurrence) }) else { return false }
            return owner.routineExceptions?.first { $0.occurrence == expected.occurrence } == previous
        }
    }

    func undo(in task: inout PlanTask) {
        guard matches(task) else { return }
        switch change {
        case .timing(let before, _):
            task.timelineDurations = before.durations
            task.plannedStart = before.pin
            task.assignedFocusBlockID = before.assignedFocusBlockID
            task.inboxOnly = before.inboxOnly
            task.routineAnchor = before.anchor
            task.movedRoutineTimes?.pin = before.seriesPin
            task.movedRoutineTimes?.availability = before.availability
            if task.movedRoutineTimes?.pin == nil && task.movedRoutineTimes?.reminder == nil {
                task.movedRoutineTimes = nil
            }
        case .exception(let previous, let expected):
            task.setException(previous, for: expected.occurrence)
        }
    }

}

extension Workspace {
    func undoableTimeMove(for id: UUID?) -> TaskTimeMove? {
        guard let move = lastTimeMove, move.taskID == id, journal.active?.taskID != id,
              journal.tasks.contains(where: move.matches) else { return nil }
        return move
    }

    @discardableResult func undoTimeMove(_ move: TaskTimeMove) -> Bool {
        guard ready, !restoring, undoableTimeMove(for: move.taskID) == move,
              let index = journal.tasks.firstIndex(where: move.matches) else { return false }
        change { journal in
            move.undo(in: &journal.tasks[index])
            if let id = journal.tasks[index].assignedFocusBlockID,
               let pin = journal.tasks[index].plannedStart,
               journal.timeBlocks?.first(where: { $0.id == id })?.focusWindow(containing: pin) == nil {
                journal.tasks[index].assignedFocusBlockID = nil
            }
        }
        lastTimeMove = nil
        return true
    }
}

/// Identifies the saved pin shown by a timing sheet. Recheck it when the user taps.
struct TaskPinRelease: Equatable {
    enum Kind: Equatable {
        case individual
        case routine(Recurrence, MovedRoutineTime)
        case projected(RoutineException)
    }

    let taskID: UUID
    let ownerID: UUID
    let journalEpoch: UUID
    let start: Date
    let kind: Kind

    var title: String {
        switch kind {
        case .individual: "Unpin time"
        case .routine, .projected: "Use usual schedule"
        }
    }

    var confirmation: String {
        switch kind {
        case .individual: "Time unpinned."
        case .routine, .projected: "Usual schedule restored."
        }
    }
}

extension Workspace {
    func releasablePin(for id: UUID) -> TaskPinRelease? {
        guard ready, !restoring, journal.active?.taskID != id else { return nil }
        if let task = journal.tasks.first(where: { $0.id == id }) {
            guard task.canReleaseTimePin, let pin = task.plannedStart else { return nil }
            let kind: TaskPinRelease.Kind
            if let rule = task.repeated, rule != .once, let move = task.movedRoutineTimes?.pin {
                kind = .routine(rule, move)
            } else {
                kind = .individual
            }
            return TaskPinRelease(taskID: id, ownerID: id, journalEpoch: journalEpoch, start: pin, kind: kind)
        }

        for owner in journal.tasks where !owner.done && owner.archived != true {
            if let saved = owner.routineExceptions?.first(where: { $0.occurrence.id == id && owner.owns($0.occurrence) }) {
                return TaskPinRelease(taskID: id, ownerID: owner.id, journalEpoch: journalEpoch, start: saved.start, kind: .projected(saved))
            }
        }
        return nil
    }

    @discardableResult func releaseTimePin(_ pin: TaskPinRelease) -> Bool {
        guard releasablePin(for: pin.taskID) == pin,
              let index = journal.tasks.firstIndex(where: { $0.id == pin.ownerID }) else { return false }
        change { journal in
            switch pin.kind {
            case .individual, .routine: journal.tasks[index].releaseTimePin()
            case .projected(let saved): journal.tasks[index].setException(nil, for: saved.occurrence)
            }
        }
        if lastTimeMove?.taskID == pin.taskID { lastTimeMove = nil }
        return true
    }
}

extension Workspace {
    @discardableResult func returnToTaskDrawer(_ id: UUID, from day: Date) -> Bool {
        guard ready, !restoring, journal.active?.taskID != id, hasScheduledTask(id, on: day) else { return false }
        let preview = projectedRoutines[id]
        var tasks = journal.tasks
        guard TaskRoutines.returnToDrawer(id, in: &tasks, projected: preview, from: day, at: now) else { return false }
        change { journal in
            journal.tasks = tasks
            if journal.nextTaskID == id { journal.nextTaskID = nil }
        }
        lastTimeMove = nil
        return true
    }
}
