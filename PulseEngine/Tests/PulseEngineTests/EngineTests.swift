import Foundation
import Testing

@testable import PulseEngine

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}()
private let morning = Date(timeIntervalSince1970: 1_767_607_200)  // Monday morning, UTC.
private func minutes(_ n: Int) -> Date { morning.addingTimeInterval(Double(n) * 60) }
private func check(_ energy: Double, offset: Int = 0) -> CheckIn {
    CheckIn(date: minutes(offset), energy: energy, clarity: energy, interest: energy)
}

@Suite struct MathematicalComponents {
    @Test func weightedCapacity() {
        let observed = CheckIn(energy: 8, clarity: 5, interest: 6, sleep: 4)
        #expect(abs(Capacity.score(observed) - 6.1) < 0.00001)
    }
    @Test func missingSleepIsNotZero() {
        #expect(abs(Capacity.score(check(7)) - 7) < 0.00001)
        #expect(Capacity.scale(-4) == 0)
        #expect(Capacity.scale(20) == 10)
    }
    @Test func baselineUsesPriorEstimate() {
        #expect(Capacity.baseline([]) == nil)
        #expect(abs(Capacity.baseline([4, 8, 6])! - 4.81) < 0.00001)
    }
    @Test func signedResidualsUseOnlyEarlierObservations() {
        #expect(Capacity.residual(observed: 2, predicted: 7) == -5)
        #expect(Capacity.errors([check(7, offset: 3), check(2)]) == [5])
    }
    @Test func rollingUncertaintyRequiresHistory() {
        #expect(Capacity.uncertainty([2, 4]) == nil)
        #expect(Capacity.uncertainty([99, 2, -2, 2], window: 3) == 2)
    }
    @Test func unexpectedChangesNeedPriorErrors() {
        #expect(Capacity.unusualResidual([4]) == nil)
        #expect(Capacity.unusualResidual([1, -1, 1, -4]) == -4)
        #expect(Capacity.unusualResidual([1, -1, 1, -1.5]) == nil)
    }
    @Test func empiricalRangeRequiresEnoughObservations() {
        #expect(Capacity.usualRange(baseline: 5, errors: [1, -1]) == nil)
        #expect(Capacity.usualRange(baseline: 9, errors: Array(repeating: 2, count: 10)) == 10...10)
    }
    @Test func sustainedLowEnergyKeepsConservativeBudget() {
        let history = [check(2, offset: -1440), check(1, offset: -50), check(8)]
        #expect(Capacity.workloadLimit(userLimit: 120, reports: history, at: morning, calendar: cal) == 3)
    }
    @Test func normalizedFriction() {
        #expect(Capacity.friction(effort: 10, overwhelm: 0, setup: 10) == 7)
        #expect(Capacity.friction(effort: 20, overwhelm: -2, setup: 10) == 7)
    }
    @Test func priorityIncludesDeadlineEffortAndMeaning() {
        var urgent = PlanTask("Send form", minutes: 10)
        var later = urgent
        urgent.due = morning
        urgent.importance = 9
        later.effort = 9
        #expect(
            Capacity.priority(urgent, capacity: 3, at: morning) > Capacity.priority(later, capacity: 3, at: morning))
    }
    @Test func durationHonorsAllLimits() {
        #expect(Capacity.block(minutes: 60, capacity: 2, limit: 20) == 6)
        #expect(Capacity.block(minutes: 5, capacity: 9, limit: 4) == 4)
        #expect(Capacity.block(minutes: 5, capacity: 0, limit: 20) == 0)
    }
    @Test func noEscalationOnAReportedLowDay() {
        let reports = [check(9, offset: -1440), check(1)]
        #expect(Capacity.estimate(at: morning, reports: reports, calendar: cal) <= 1)
        #expect(Capacity.workloadLimit(userLimit: 60, reports: reports, at: morning, calendar: cal) == 3)
    }
    @Test func reportedWorseningKeepsTheDayOpen() {
        var report = check(5)
        report.feltWorseAfterActivity = true
        #expect(Capacity.workloadLimit(userLimit: 60, reports: [report], at: morning, calendar: cal) == 0)
    }
    @Test func historyDoesNotUseFutureReports() {
        #expect(Capacity.estimate(at: morning, reports: [check(0, offset: 60)], calendar: cal) == 5)
    }
    @Test func firstActionNeedsPairedRecords() {
        let session = SessionRecord(taskID: UUID(), title: "Read", start: minutes(10), seconds: 180)
        #expect(Rhythms.firstActionDelays(reports: [check(5)], sessions: [session], calendar: cal).first?.1 == 10)
        #expect(Rhythms.firstActionDelays(reports: [], sessions: [session], calendar: cal).isEmpty)
        #expect(Rhythms.firstActionDelays(reports: [check(5, offset: 15)], sessions: [session], calendar: cal).isEmpty)
    }
}

@Suite struct Scheduling {
    @Test func protectFixedTimeAndRespectBudget() {
        let event = Commitment("Class", start: minutes(5), end: minutes(60))
        let tasks = [PlanTask("A", minutes: 20), PlanTask("B", minutes: 20)]
        let plan = Planner.schedule(
            at: morning, tasks: tasks, commitments: [event], reports: [], dailyLimit: 20, usedMinutes: 4, calendar: cal)
        let work = plan.filter { if case .task = $0.kind { true } else { false } }
        #expect(work.reduce(0) { $0 + $1.minutes } == 16)
        #expect(work.allSatisfy { $0.end <= event.start || $0.start >= event.end })
    }
    @Test func incompletePrerequisiteKeepsDependentOffSchedule() {
        let first = PlanTask("Research", minutes: 50)
        var second = PlanTask("Write", minutes: 5)
        second.dependency = first.id
        let plan = Planner.schedule(
            at: morning, tasks: [first, second], commitments: [], reports: [], dailyLimit: 60, calendar: cal)
        #expect(!plan.contains { $0.kind == .task(second.id) })
    }
    @Test func shortPrerequisiteComesFirst() {
        let first = PlanTask("Collect notes", minutes: 3)
        var second = PlanTask("Write", minutes: 5)
        second.dependency = first.id
        let p = Planner.schedule(
            at: morning, tasks: [second, first], commitments: [], reports: [], dailyLimit: 30, calendar: cal)
        #expect(p.map(\.kind) == [.task(first.id), .rest, .task(second.id)])
    }
    @Test func deferredAndUnfinishedTasksMoveForward() {
        var item = PlanTask("Call", minutes: 4)
        item.after = minutes(20)
        #expect(
            Planner.schedule(at: morning, tasks: [item], commitments: [], reports: [], dailyLimit: 10, calendar: cal)
                .first?.start == minutes(20))
        #expect(
            Planner.schedule(
                at: minutes(80), tasks: [item], commitments: [], reports: [], dailyLimit: 10, calendar: cal
            ).first?.start == minutes(80))
    }
    @Test func zeroDayKeepsAppointments() {
        let event = Commitment("Meet", start: minutes(2), end: minutes(10))
        let p = Planner.schedule(
            at: morning, tasks: [PlanTask("Read", minutes: 3)], commitments: [event], reports: [], dailyLimit: 0,
            calendar: cal)
        #expect(p.map(\.kind) == [.fixed(event.id)])
    }
    @Test func recurringOvernightBlocksBothEndsOfDay() {
        let day = cal.startOfDay(for: morning)
        let night = Commitment(
            "Night shift", start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3600), recurrence: .daily)
        let p = night.intervals(on: day, calendar: cal)
        #expect(p.count == 2)
        #expect(p.first?.end == day.addingTimeInterval(3600))
        #expect(p.last?.start == day.addingTimeInterval(23 * 3600))
    }
    @Test func parserHandlesTheBriefAndExplicitDurations() {
        let draft = LocalDayInput.parse(
            "I have school until 3, need to study chemistry, and want to work on my app.", at: morning, calendar: cal)
        #expect(draft.tasks.map(\.title) == ["Study chemistry", "Work on my app"])
        #expect(draft.commitments.count == 1)
        #expect(cal.component(.hour, from: draft.commitments[0].end) == 15)
        #expect(LocalDayInput.parse("Read for 8 minutes", at: morning).tasks.first?.minutes == 8)
        #expect(!LocalDayInput.parse("School until noonish", at: morning).unrecognized.isEmpty)
    }
}
@Suite struct TimerAccounting {
    @Test func pausesAndIgnoresClockChanges() {
        var s = ActiveSession(task: PlanTask("Read", minutes: 5), minutes: 5, now: morning, tick: 100, boot: "a")
        s.pause(now: minutes(-60), tick: 120, boot: "a")
        #expect(s.accumulated == 20)
        #expect(s.elapsed(now: minutes(20), tick: 1000, boot: "a") == 20)
        s.resume(now: minutes(30), tick: 1100, boot: "a")
        #expect(s.elapsed(now: morning, tick: 1110, boot: "a") == 30)
    }
    @Test func persistedRunningTimerRestoresAndCapsAfterReboot() throws {
        let s = ActiveSession(task: PlanTask("Read", minutes: 2), minutes: 2, now: morning, tick: 100, boot: "a")
        let restored = try JSONDecoder().decode(ActiveSession.self, from: JSONEncoder().encode(s))
        #expect(restored.elapsed(now: morning, tick: 131, boot: "a") == 31)
        #expect(restored.elapsed(now: minutes(1), tick: 4, boot: "b") == 60)
        #expect(restored.elapsed(now: minutes(8), tick: 4, boot: "b") == 120)
        #expect(restored.elapsed(now: minutes(-3), tick: 4, boot: "b") == 0)
    }
}

@Suite struct FocusWorkflow {
    @Test func progressAccumulatesAcrossShortSessions() throws {
        var task = PlanTask("Read", minutes: 2)
        task.recordFocus(seconds: 35, completed: false)
        let saved = try JSONEncoder().encode(task)
        task = try JSONDecoder().decode(PlanTask.self, from: saved)
        task.recordFocus(seconds: 40, completed: false)
        #expect(task.minutes == 1)
        #expect(task.remainingSeconds == 45)
        let next = ActiveSession(task: task, minutes: 1, now: morning, tick: 0, boot: "a")
        #expect(next.target == 45)
        task.minutes = 3
        #expect(task.remainingSeconds == 180)
    }

    @Test func pausedTimeDoesNotUseTomorrowsBudget() {
        let midnight = cal.dateInterval(of: .day, for: morning)!.end
        let start = midnight.addingTimeInterval(-120)
        let today = cal.dateInterval(of: .day, for: start)!
        let tomorrow = cal.dateInterval(of: .day, for: midnight)!
        var active = ActiveSession(task: PlanTask("Study", minutes: 10), minutes: 10, now: start, tick: 100, boot: "a")
        active.pause(now: start.addingTimeInterval(60), tick: 160, boot: "a")
        active.resume(now: midnight.addingTimeInterval(1800), tick: 2020, boot: "a")
        let record = active.record(now: midnight.addingTimeInterval(1830), tick: 2050, boot: "a", completed: false)
        #expect(record.seconds == 90)
        #expect(record.seconds(in: today) == 60)
        #expect(record.seconds(in: tomorrow) == 30)
        #expect(record.completedTask == false)
    }

    @Test func ongoingWorkSplitsAtMidnightAndLegacyRecordsRemainReadable() throws {
        let midnight = cal.dateInterval(of: .day, for: morning)!.end
        let start = midnight.addingTimeInterval(-30)
        let active = ActiveSession(task: PlanTask("Read", minutes: 2), minutes: 2, now: start, tick: 10, boot: "a")
        let record = active.record(now: midnight.addingTimeInterval(20), tick: 60, boot: "a")
        let day = cal.dateInterval(of: .day, for: midnight)!
        #expect(record.seconds(in: day) == 20)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "periods")
        let legacy = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.seconds(in: day) == 0)
        #expect(legacy.seconds(in: cal.dateInterval(of: .day, for: start)!) == 50)
    }

    @Test func realBreakSurvivesReplanningAndStopsAtFixedCommitment() {
        let recovery = DateInterval(start: morning, duration: 300)
        let event = Commitment("Call", start: minutes(3), end: minutes(12))
        let task = PlanTask("Read", minutes: 3)
        let blocks = Planner.schedule(
            at: minutes(1), tasks: [task], commitments: [event], reports: [], dailyLimit: 15, recovery: recovery,
            calendar: cal)
        #expect(blocks.map(\.kind) == [.rest, .fixed(event.id), .task(task.id)])
        #expect(blocks.first?.end == minutes(3))
        #expect(blocks.last?.start == minutes(12))
        #expect(Planner.recoveryInterval(recovery, at: minutes(4), commitments: [event], calendar: cal) == nil)
        #expect(Planner.recoveryInterval(recovery, at: minutes(5), commitments: [], calendar: cal) == nil)
        #expect(
            Planner.schedule(
                at: morning, tasks: [task], commitments: [], reports: [], dailyLimit: 15, breaks: false,
                recovery: recovery, calendar: cal
            ).first?.kind == .task(task.id))
    }
}

@Suite struct TimedDayInput {
    @Test func recurringSchoolAndDeadline() throws {
        let draft = LocalDayInput.parse(
            "School from 9am to 3pm every weekday, study chemistry for 20 minutes by tomorrow", at: morning,
            calendar: cal)
        let school = try #require(draft.commitments.first)
        #expect(school.recurrence == .weekdays)
        #expect(cal.component(.hour, from: school.start) == 9)
        #expect(cal.component(.hour, from: school.end) == 15)
        let task = try #require(draft.tasks.first)
        #expect(task.minutes == 20 && task.title == "Study chemistry")
        #expect(cal.isDate(task.due!, inSameDayAs: minutes(1440)))
        #expect(draft.unrecognized.isEmpty)
    }
    @Test func timedEveningAndOvernightEvents() throws {
        let draft = LocalDayInput.parse(
            "Dinner tomorrow at 6:30pm for 1 hour, Night shift from 23:00 to 07:00 daily", at: morning, calendar: cal)
        #expect(draft.commitments.count == 2)
        let dinner = try #require(draft.commitments.first)
        #expect(dinner.title == "Dinner")
        #expect(cal.isDate(dinner.start, inSameDayAs: minutes(1440)))
        #expect(dinner.end.timeIntervalSince(dinner.start) == 3600)
        #expect(draft.commitments.last?.recurrence == .daily)
        #expect(draft.commitments.last!.end.timeIntervalSince(draft.commitments.last!.start) == 8 * 3600)
    }
    @Test func ordinaryTaskNamesKeepTheirWords() {
        let draft = LocalDayInput.parse("Write daily notes, walk from home to school", at: morning, calendar: cal)
        #expect(draft.tasks.map(\.title) == ["Write daily notes", "Walk from home to school"])
        #expect(draft.unrecognized.isEmpty)
    }
    @Test func badTimesAndDurationsStayInReview() {
        let draft = LocalDayInput.parse(
            "School from 14pm to 18pm, Read for 0 minutes, Call at 27:00", at: morning, calendar: cal)
        #expect(draft.unrecognized.count == 3)
        #expect(draft.tasks.isEmpty && draft.commitments.isEmpty)
    }
}

@Suite struct ManualOrder {
    @Test func choiceOnlyWinsWhenEligible() {
        var chosen = PlanTask("Draw", minutes: 5)
        var urgent = PlanTask("Send form", minutes: 5)
        urgent.importance = 10
        urgent.due = morning
        func plan(_ task: PlanTask, limit: Int = 30) -> [Block.Kind] {
            Planner.schedule(
                at: morning, tasks: [urgent, task], commitments: [], reports: [], dailyLimit: limit,
                breaks: false, nextTaskID: task.id, calendar: cal
            ).map(\.kind)
        }
        #expect(plan(chosen).first == .task(chosen.id))
        chosen.dependency = urgent.id
        #expect(plan(chosen) == [.task(urgent.id), .task(chosen.id)])
        chosen.dependency = nil
        chosen.after = minutes(1440)
        #expect(plan(chosen) == [.task(urgent.id)])
        #expect(plan(chosen, limit: 0).isEmpty)
    }
}

struct TaskBreakdownTests {
    @Test func aNounPairStaysInsideTheFirstAction() {
        let bag = PlanTask("Pack a notebook and pencil and then call the studio", minutes: 20)
        #expect(TaskBreakdown.suggestions(for: bag) == ["Pack a notebook and pencil", "call the studio"])
        let groceries = PlanTask("Buy bread and milk", minutes: 8)
        #expect(!TaskBreakdown.suggestions(for: groceries).contains("milk"))
    }

    @Test func aShortStartMatchesTheAction() {
        #expect(TaskBreakdown.suggestions(for: PlanTask("Outline the first paragraph", minutes: 10)).first == "Write one bullet point")
        #expect(TaskBreakdown.suggestions(for: PlanTask("Write a function", minutes: 15)).first == "Write down one example input")
        #expect(TaskBreakdown.suggestions(for: PlanTask("Edit the photos", minutes: 10)).first == "Open the item you want to change")
    }
}
