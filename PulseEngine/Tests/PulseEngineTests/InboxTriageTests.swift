import Foundation
import Testing
@testable import PulseEngine

@Suite struct InboxTriageTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    @Test func heldProjectTaskStaysInInboxUntilExplicitlyScheduled() throws {
        let now = Date.now
        var thought = PlanTask("Find rehearsal notes", minutes: 4)
        thought.project = "Concert"
        thought.inboxOnly = true
        let planned = PlanTask("Review score", minutes: 10)
        var tasks = [planned, thought]
        let block = Block(kind: .task(planned.id), title: planned.title, start: now, end: now.addingTimeInterval(600))
        #expect(thought.belongsToInbox)
        #expect(InboxTriage.candidate(tasks: tasks, next: nil, active: nil, blocks: [block], now: now, inboxOnly: true)?.id == thought.id)
        var next: UUID?
        let change = try #require(InboxTriage.apply(.tomorrow, to: thought.id, tasks: &tasks, next: &next, active: nil, now: now))
        #expect(!tasks[1].belongsToInbox && tasks[1].project == "Concert")
        #expect(InboxTriage.undo(change, tasks: &tasks, next: &next, active: nil))
        #expect(tasks[1].belongsToInbox && tasks[1].isInboxOnly)
    }

    @Test func nextCandidateIsScheduledAndSkipsAlreadyReviewedItems() {
        let one = PlanTask("Read", minutes: 5)
        let two = PlanTask("File order", minutes: 2)
        var project = one.duplicate()
        project.project = "Garden"
        var later = one.duplicate()
        later.after = now.addingTimeInterval(86_400)
        let block = Block(kind: .task(two.id), title: two.title, start: now, end: now.addingTimeInterval(120))
        let list = [project, later, one, two]
        #expect(InboxTriage.candidate(tasks: list, next: nil, active: nil, blocks: [block], now: now, calendar: calendar)?.id == two.id)
        #expect(InboxTriage.candidate(tasks: list, next: two.id, active: one.id, blocks: [block], now: now, calendar: calendar) == nil)
    }

    @Test func undoRestoresPinAndReminderAfterRelaunchAndPreservesRenamedTask() throws {
        var task = PlanTask("Review", minutes: 8)
        task.plannedStart = now
        task.reminder = now
        task.repeated = .weekly
        var list = [task]
        var next: UUID?
        let receipt = try #require(InboxTriage.apply(.tomorrow, to: task.id, tasks: &list, next: &next, active: nil, now: now, calendar: calendar))
        #expect(list[0].after == calendar.dateInterval(of: .day, for: now)?.end)
        let restored = try JSONDecoder().decode(InboxTriage.Receipt.self, from: JSONEncoder().encode(receipt))
        list[0].title = "Edited elsewhere"
        #expect(InboxTriage.undo(restored, tasks: &list, next: &next, active: nil))
        task.title = list[0].title
        #expect(list == [task])
        #expect(!InboxTriage.undo(restored, tasks: &list, next: &next, active: nil))
    }

    @Test func undoDoesNotReplaceNewerSchedulingOrPreferenceChanges() throws {
        let first = PlanTask("First", minutes: 4)
        let second = PlanTask("Second", minutes: 3)
        var list = [first, second]
        var next: UUID? = second.id
        let preference = try #require(InboxTriage.apply(.prioritize, to: first.id, tasks: &list, next: &next, active: nil, now: now))
        #expect(next == first.id)
        #expect(InboxTriage.undo(preference, tasks: &list, next: &next, active: nil))
        #expect(next == second.id)
        next = nil
        #expect(!InboxTriage.undo(preference, tasks: &list, next: &next, active: nil))
        let archived = try #require(InboxTriage.apply(.archive, to: first.id, tasks: &list, next: &next, active: nil, now: now))
        #expect(list[0].archived == true)
        #expect(!InboxTriage.canUndo(archived, tasks: list, next: nil, active: first.id))
        list[0].plannedStart = now.addingTimeInterval(3600)
        #expect(!InboxTriage.undo(archived, tasks: &list, next: &next, active: nil))
    }
}
