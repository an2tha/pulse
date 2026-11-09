import Foundation

public enum InboxTriage {
    public enum Action: String, Codable, Sendable { case prioritize, tomorrow, archive }

    /// Only fields changed by triage are retained for undo. Titles, notes and pictures stay in the task.
    public struct Receipt: Codable, Equatable, Sendable {
        public let taskID: UUID
        public let action: Action
        fileprivate let before: Fields
        fileprivate let after: Fields
        fileprivate let previousNext: UUID?
        fileprivate let chosenNext: UUID?

        public var isValid: Bool {
            guard before.validDates && after.validDates && before.archived != true else { return false }
            switch action {
            case .prioritize:
                var expected = before
                expected.inboxOnly = nil
                return expected == after && chosenNext == taskID && previousNext != taskID
            case .archive:
                var expected = before
                expected.archived = true
                return after == expected && previousNext == chosenNext
            case .tomorrow:
                return before.archived == after.archived && after.earliest != nil && previousNext == chosenNext
            }
        }
    }

    fileprivate struct Fields: Codable, Equatable, Sendable {
        var earliest: Date?
        var pin: Date?
        var reminder: Date?
        var anchor: Date?
        var routineTimes: MovedRoutineTimes?
        var archived: Bool?
        var inboxOnly: Bool?

        var validDates: Bool {
            [earliest, pin, reminder, anchor, routineTimes?.pin?.original, routineTimes?.pin?.moved,
             routineTimes?.reminder?.original, routineTimes?.reminder?.moved].compactMap { $0 }.allSatisfy {
                $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) < 32_000_000_000
            }
        }

        init(_ task: PlanTask) {
            earliest = task.after
            pin = task.plannedStart
            reminder = task.reminder
            anchor = task.routineAnchor
            routineTimes = task.movedRoutineTimes
            archived = task.archived
            inboxOnly = task.inboxOnly
        }

        func assign(to task: inout PlanTask) {
            task.after = earliest
            task.plannedStart = pin
            task.reminder = reminder
            task.routineAnchor = anchor
            task.movedRoutineTimes = routineTimes
            task.archived = archived
            task.inboxOnly = inboxOnly
        }
    }

    public static func candidate(tasks: [PlanTask], next: UUID?, active: UUID?, blocks: [Block],
                                 now: Date, calendar: Calendar = .current, inboxOnly: Bool = false) -> PlanTask? {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return nil }
        let pending = tasks.filter { task in
            task.belongsToInbox && (!inboxOnly || task.isInboxOnly) &&
                task.id != active && task.id != next && task.earliest < day.end
        }
        let lookup = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        for block in blocks {
            if case .task(let id) = block.kind, let task = lookup[id] { return task }
        }
        return pending.first
    }

    @discardableResult public static func apply(_ action: Action, to id: UUID, tasks: inout [PlanTask],
                                                next: inout UUID?, active: UUID?, now: Date,
                                                calendar: Calendar = .current) -> Receipt? {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              candidate(tasks: [tasks[index]], next: next, active: active, blocks: [], now: now, calendar: calendar) != nil
        else { return nil }
        let before = Fields(tasks[index])
        let previousNext = next
        switch action {
        case .prioritize:
            tasks[index].inboxOnly = nil
            next = id
        case .archive: tasks[index].archived = true
        case .tomorrow:
            guard DayClose.move([id], in: &tasks, planned: [id], active: active, reviewedDay: now,
                                now: now, calendar: calendar) == 1 else { return nil }
            tasks[index].inboxOnly = nil
        }
        return Receipt(taskID: id, action: action, before: before, after: Fields(tasks[index]),
                       previousNext: previousNext, chosenNext: next)
    }

    public static func canUndo(_ receipt: Receipt, tasks: [PlanTask], next: UUID?, active: UUID?) -> Bool {
        guard receipt.isValid, active != receipt.taskID, let task = tasks.first(where: { $0.id == receipt.taskID && !$0.done }),
              Fields(task) == receipt.after else { return false }
        return receipt.action != .prioritize || next == receipt.chosenNext
    }

    @discardableResult public static func undo(_ receipt: Receipt, tasks: inout [PlanTask], next: inout UUID?,
                                               active: UUID?) -> Bool {
        guard canUndo(receipt, tasks: tasks, next: next, active: active),
              let i = tasks.firstIndex(where: { $0.id == receipt.taskID }) else { return false }
        if receipt.action == .prioritize {
            tasks[i].inboxOnly = receipt.before.inboxOnly
            next = receipt.previousNext.flatMap { old in tasks.contains { $0.id == old && !$0.done && $0.archived != true } ? old : nil }
        } else {
            receipt.before.assign(to: &tasks[i])
        }
        return true
    }
}
