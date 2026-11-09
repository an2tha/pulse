import Foundation
import PulseEngine
import Testing

@testable import Pulse

@Suite @MainActor struct SmallStartTests {
    @Test func namingTheIntentionQueuesRealWorkWithoutInventingFocus() {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        var intention = Workspace.starter
        intention.steps?[0].done = true
        store.journal.tasks = [intention]
        #expect(store.canNameIntention)
        let next = PlanTask("Open the biology notes", minutes: 10)
        #expect(store.captureTask(next, namingIntention: true) == next.id)
        #expect(store.journal.tasks.first?.done == true && store.journal.nextTaskID == next.id)
        #expect(store.journal.sessions.isEmpty && store.journal.active == nil)
        store.journal.tasks = [intention]
        store.journal.tasks[0].steps?.append(TaskStep("My own follow-up"))
        #expect(!store.canNameIntention)
        _ = store.captureTask(PlanTask("Another task", minutes: 5), namingIntention: true)
        #expect(store.journal.tasks.first?.done == false)
    }

    @Test func sprintCapturesKeepTheirSessionThroughPauseFinishAndBackup() async throws {
        let store = try await planned()
        #expect(store.startSmall(at: morning))
        let source = try #require(store.journal.active)
        let first = PlanTask("Find a pencil", minutes: 3)
        #expect(store.captureTask(first, focusSession: source) == first.id)
        #expect(store.captureTask(first, focusSession: source) == first.id)
        let pausedAt = morning.addingTimeInterval(1)
        store.toggleTimer(at: pausedAt)
        let second = PlanTask("Email the office", minutes: 5)
        #expect(store.captureTask(second, focusSession: source) == second.id)
        store.finish(done: true)
        let record = try #require(store.journal.sessions.last)
        #expect(store.canNameIntention)
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        #expect(restored.tasks.filter { $0.capturedDuringSessionID == record.id }.map(\.id) == [first.id, second.id])
        #expect(restored.tasks.last?.duplicate().capturedDuringSessionID == nil)
        let unrelated = PlanTask("Mail the letter", minutes: 5)
        _ = store.captureTask(unrelated)
        #expect(store.journal.tasks.last?.capturedDuringSessionID == nil)
    }

    @Test func reopenedLegacySprintReceivesAStableIdentityOnCapture() async throws {
        let store = try await planned()
        #expect(store.startSmall(at: morning))
        store.journal.active?.sessionID = nil
        let legacy = try #require(store.journal.active)
        let captured = PlanTask("Buy tape", minutes: 3)
        _ = store.captureTask(captured, focusSession: legacy)
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        let id = try #require(restored.active?.sessionID)
        #expect(restored.tasks.last?.capturedDuringSessionID == id)
        store.finish(done: false)
        #expect(store.journal.sessions.last?.id == id)
    }

    private let calendar = Calendar(identifier: .gregorian)
    private var morning: Date {
        calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!
    }

    private func planned(_ task: PlanTask? = nil) async throws -> Workspace {
        let store = Workspace()
        store.isDemo = true
        store.journal.tasks = [task ?? Workspace.starter]
        store.ready = true
        store.now = morning
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while store.next == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try #require(store.next)
        return store
    }

    @Test func savedChecklistStartsInOneCall() async throws {
        let store = try await planned()
        #expect(store.journal.tasks.count == 1)
        #expect(store.startSmall(at: morning))
        let session = try #require(store.journal.active)
        let task = try #require(store.journal.tasks.first)
        #expect(session.target == 120 && session.stepID == task.steps?.first?.id)
        #expect(store.startSmall(at: morning) == false)
        store.finish(done: true)
        #expect(store.journal.tasks.first?.done == false)
        #expect(store.journal.tasks.first?.steps?.first?.done == true)
    }

    @Test func newAndLegacyEmptyJournalsNeverOfferAnInventedTask() async throws {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        #expect(store.offeredTasks.isEmpty)
        var legacy = Journal()
        legacy.starterAvailable = true
        try await store.restoreJournal(legacy)
        await store.waitForCurrentPlan()
        #expect(store.offeredTasks.isEmpty && store.schedulingTasks.isEmpty && store.next == nil)
        store.markDone(Workspace.starter)
        #expect(store.journal.tasks.isEmpty)
    }

    @Test func restoreRemovesOnlyUntouchedLegacyDefault() async throws {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        var previous = Journal()
        var starter = Workspace.starter
        starter.createdAt = morning
        starter.steps = starter.steps?.map { TaskStep($0.title) }
        let personal = PlanTask(starter.title, minutes: starter.minutes)
        previous.tasks = [starter, personal]
        try await store.restoreJournal(previous)
        #expect(store.journal.tasks == [personal])
        previous.tasks[0].project = "My afternoon"
        try await store.restoreJournal(previous)
        #expect(store.journal.tasks == previous.tasks)
        previous.tasks[0] = starter
        previous.tasks[1].dependency = starter.id
        try await store.restoreJournal(previous)
        #expect(store.journal.tasks == previous.tasks)
        previous.tasks = [starter]
        previous.active = ActiveSession(task: starter, minutes: 5, now: .now, tick: 0, boot: nil)
        try await store.restoreJournal(previous)
        #expect(store.journal.tasks == [starter])
    }

    @Test func startsFirstUnfinishedStepAndHonorsShorterBlock() async throws {
        var task = PlanTask("Read", minutes: 1, category: .study)
        var complete = TaskStep("Open the book")
        complete.done = true
        let next = TaskStep("Read the first paragraph")
        task.steps = [complete, next]
        let store = try await planned(task)
        #expect(store.startSmall(taskID: UUID(), at: morning) == false)
        #expect(store.startSmall(taskID: task.id, at: morning))
        #expect(store.journal.active?.target == 60 && store.journal.active?.stepID == next.id)
        store.finish(done: false)
        #expect(store.journal.tasks.first?.steps == task.steps)
    }

    @Test func staleAvailableBlockCannotBypassRecoveryOrBudget() async throws {
        let store = try await planned()
        store.journal.recovery = DateInterval(start: morning, duration: 300)
        #expect(store.startSmall(at: morning) == false)
        store.journal.recovery = nil
        store.journal.restDate = morning
        #expect(store.startSmall(at: morning) == false)
        store.journal.restDate = nil
        var tuning = PlanTuning(date: morning)
        tuning.manualCapacity = 0
        store.journal.tuning = tuning
        #expect(store.startSmall(at: morning) == false)
        store.journal.tuning = nil
        store.journal.limit = 0
        #expect(store.startSmall(at: morning) == false)
        #expect(store.journal.active == nil && store.journal.tasks.count == 1)
    }

    @Test func wrapUpRevalidatesStaleStartsAndPreservesActiveSession() async throws {
        let store = try await planned()
        let (task, block) = try #require(store.next)
        store.journal.wrapUpMinute = 9 * 60
        #expect(!store.canStart(block))
        #expect(!store.startSmall(at: morning))
        store.start(task, block: block, at: morning)
        #expect(store.journal.active == nil)

        store.journal.wrapUpMinute = 9 * 60 + 1
        store.start(task, block: block, at: morning.addingTimeInterval(30))
        let active = try #require(store.journal.active)
        #expect(active.target == 30)
        store.change { $0.wrapUpMinute = 8 * 60 }
        #expect(store.journal.active == active)
    }

    @Test func stoppingCanSaveAnotherStepWithoutCompletingEither() async throws {
        var task = PlanTask("Edit photos", minutes: 10)
        let first = TaskStep("Crop the image")
        let second = TaskStep("Adjust the exposure")
        task.steps = [first, second]
        let store = try await planned(task)
        #expect(store.startSmall(at: morning))
        store.finish(done: false, pickUpAt: second.id)
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        let saved = try #require(restored.tasks.first)
        #expect(saved.resumeStep == second && saved.steps == task.steps)
        #expect(restored.recovery == nil && !saved.done)
        let reopened = try await planned(saved)
        #expect(reopened.startSmall(at: morning))
        #expect(reopened.journal.active?.stepID == second.id)
        reopened.finish(done: true)
        let finished = try #require(reopened.journal.tasks.first)
        #expect(finished.resumeStep == nil && !finished.done && finished.nextSmallStep == first)
        #expect(finished.steps?.last?.done == true && reopened.journal.recovery != nil)
    }

    @Test func finishingAnEditedAwayStepLeavesTheTaskOpen() async throws {
        let store = try await planned()
        #expect(store.startSmall(at: morning))
        let other = TaskStep("Write it down")
        store.change { $0.tasks[0].steps = [other] }
        store.finish(done: true)
        #expect(store.journal.tasks.first?.steps == [other])
        #expect(store.journal.tasks.first?.done == false)
        #expect(store.journal.sessions.last?.completedTask == false)
    }
}

extension SmallStartTests {
    @Test func untimedAndDurationOnlyDistractionsStayOutOfThePlanThroughBackupAndUndo() async throws {
        let store = try await planned()
        #expect(store.startSmall(at: morning))
        let session = try #require(store.journal.active)
        let thought = try #require(InboxCaptureDraft("Buy stamps for 5 minutes", at: morning, commitments: []))
        let timed = try #require(InboxCaptureDraft("File notes in 20 minutes", at: morning, commitments: []))
        _ = store.captureTask(thought.task, focusSession: session)
        _ = store.captureTask(timed.task, focusSession: session)
        let snapshot = try JournalArchive.decodeBackup(JournalArchive.backup(store.journal))
        let held = try #require(snapshot.tasks.first { $0.id == thought.task.id })
        let scheduled = try #require(snapshot.tasks.first { $0.id == timed.task.id })
        #expect(held.isInboxOnly && held.minutes == 5 && !scheduled.isInboxOnly)
        #expect(scheduled.after == morning.addingTimeInterval(1200))
        let tasks = [held, scheduled]
        let blocks = Planner.schedule(at: morning, tasks: tasks, commitments: [], reports: [], dailyLimit: 45)
        #expect(!blocks.contains { $0.kind == .task(held.id) })
        #expect(blocks.contains { $0.kind == .task(scheduled.id) })
        let week = Planner.weekPlacements(for: held.id, at: morning, tasks: tasks, commitments: [],
                                          reports: [], dailyLimit: 45)
        let best = week.first(where: \.recommended)
        let choice = try #require(best)
        var moved = held
        moved.moveOccurrence(to: choice.start)
        #expect(!moved.isInboxOnly)
        let receipt = try #require(TaskTimeMove(from: held, to: moved, sourceDay: morning))
        receipt.undo(in: &moved)
        #expect(moved == held && moved.isInboxOnly)
    }

    @Test func ordinaryTasksAndLiteralDistractionsRespectTheirDistinctDestinations() throws {
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        let ordinary = PlanTask("Buy stamps", minutes: 5)
        let parsed = try #require(InboxCaptureDraft("Call back in 20 minutes", at: morning, commitments: []))
        _ = store.captureTask(ordinary)
        _ = store.captureTask(parsed.literal, distraction: true)
        #expect(!store.journal.tasks[0].isInboxOnly && store.journal.tasks[1].isInboxOnly)
        var tasks = store.journal.tasks
        var next: UUID?
        let receipt = try #require(InboxTriage.apply(.prioritize, to: parsed.literal.id, tasks: &tasks,
                                                     next: &next, active: nil, now: morning))
        #expect(receipt.isValid && !tasks[1].isInboxOnly && next == parsed.literal.id)
        let undone = InboxTriage.undo(receipt, tasks: &tasks, next: &next, active: nil)
        #expect(undone && tasks[1].isInboxOnly && next == nil)
    }
}
