import Foundation
import Testing

@testable import PulseEngine

@Suite struct RoadmapPlannerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func time(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func tasks(in blocks: [Block]) -> [Block] {
        blocks.filter { if case .task = $0.kind { true } else { false } }
    }

    @Test func editedTimeBlockRetainsBudgetAndWinsAtItsStart() throws {
        var pinned = PlanTask("Collect order", minutes: 10)
        pinned.plannedStart = time(12, 9, 20)
        var urgent = PlanTask("Write proposal", minutes: 45)
        urgent.due = time(12)
        urgent.importance = 10
        let choice = PlanTask("Finish message", minutes: 25)
        let options = PlannerPreferences(order: [urgent.id, choice.id])

        let plan = Planner.schedule(
            at: time(12, 9), tasks: [urgent, choice, pinned], commitments: [], reports: [],
            dailyLimit: 15, breaks: false, nextTaskID: choice.id, preferences: options, calendar: calendar
        )
        #expect(plan.map(\.kind) == [.task(choice.id), .task(pinned.id)])
        #expect(plan.map(\.minutes) == [5, 10])
        #expect(plan.last?.start == pinned.plannedStart)

        let tight = Planner.schedule(
            at: time(12, 9), tasks: [urgent, pinned], commitments: [], reports: [], dailyLimit: 5,
            preferences: options, calendar: calendar)
        #expect(tight.map(\.kind) == [.task(pinned.id)])
        #expect(tight.first?.start == time(12, 9, 20))
    }

    @Test func postponedPinDoesNotCreateAnEarlierPhantomBoundary() {
        var pin = PlanTask("Call", minutes: 2)
        pin.plannedStart = time(12, 9, 1)
        pin.after = time(13, 12)
        let flex = PlanTask("Read", minutes: 10)
        let plan = Planner.schedule(
            at: time(12, 9), tasks: [pin, flex], commitments: [], reports: [], dailyLimit: 10,
            calendar: calendar)
        #expect(plan.map(\.minutes) == [10])
    }

    @Test func pinnedConflictMovesPastAppointmentBuffer() {
        var pinned = PlanTask("Call", minutes: 8)
        pinned.plannedStart = time(12, 9, 5)
        let event = Commitment("Bus", start: time(12, 9, 5), end: time(12, 9, 12))
        let plan = Planner.schedule(
            at: time(12, 9), tasks: [pinned, PlanTask("Read", minutes: 10)], commitments: [event],
            reports: [], dailyLimit: 8, preferences: .init(bufferMinutes: 5), calendar: calendar)
        #expect(tasks(in: plan).map(\.start) == [time(12, 9, 17)])
        #expect(tasks(in: plan).first?.kind == .task(pinned.id))
    }

    @Test func workBuffersCrossMidnightAndCoalesceOverlaps() {
        let events = [
            Commitment("Evening shift", start: time(12, 22), end: time(12, 23, 58)),
            Commitment("Overnight call", start: time(14, 0, 2), end: time(14, 0, 10)),
            Commitment("Departure", start: time(13, 23, 50), end: time(13, 23, 55)),
        ]
        let occupied = Planner.workExclusions(
            at: time(13), commitments: events, bufferMinutes: 10, calendar: calendar)
        #expect(
            occupied == [
                DateInterval(start: time(13), end: time(13, 0, 8)),
                DateInterval(start: time(13, 23, 40), end: time(14)),
            ])
        let plan = Planner.schedule(
            at: time(13), tasks: [PlanTask("Read", minutes: 5)], commitments: events, reports: [],
            dailyLimit: 5, preferences: .init(bufferMinutes: 10), calendar: calendar)
        #expect(tasks(in: plan).first?.start == time(13, 0, 8))
    }

    @Test func weekdayRoutineRestoresTemplateAcrossDaylightSaving() throws {
        var task = PlanTask("Go for a walk", minutes: 20)
        task.repeated = .weekdays
        task.after = time(27, 8)
        task.plannedStart = time(27, 9)
        task.reminder = time(27, 8, 45)
        task.due = time(27, 12)
        task.project = "Outside"
        task.steps = [TaskStep("Shoes"), TaskStep("Head outside")]
        task.steps?[0].done = true
        task.recordFocus(seconds: 600, completed: false)
        task.done = true
        var items = [task]
        TaskRoutines.advance(&items, at: time(27, 10), calendar: calendar)
        TaskRoutines.advance(&items, at: time(27, 11), calendar: calendar)
        #expect(items.count == 2)
        let next = try #require(items.last)
        #expect(next.minutes == 20 && next.project == "Outside" && next.id != task.id)
        #expect(next.steps?.allSatisfy { !$0.done } == true)
        #expect(next.steps?.first?.id != task.steps?.first?.id)
        #expect(next.plannedStart == time(30, 9))
        #expect(next.reminder == time(30, 8, 45) && next.due == time(30, 12))
    }

    @Test func weeklyRoutineKeepsWeekdayAfterLongDeferral() {
        var task = PlanTask("Review", minutes: 12)
        task.repeated = .weekly
        task.after = time(3, 9)
        task.done = true
        var items = [task]
        TaskRoutines.advance(&items, at: time(5, 12), calendar: calendar)
        #expect(items.count == 2 && items.last?.after == time(10, 9))
        items[1].after = time(20, 15)
        items[1].done = true
        TaskRoutines.advance(&items, at: time(20, 16), calendar: calendar)
        #expect(items.count == 3 && items.last?.after == time(24, 9))
        #expect(items.filter { !$0.done }.count == 1)
    }

    @Test func repeatingDependencyAdvancesToMatchingOccurrence() throws {
        var first = PlanTask("Gather notes", minutes: 3)
        var second = PlanTask("Send minutes", minutes: 4)
        first.repeated = .daily
        second.repeated = .daily
        second.dependency = first.id
        first.done = true
        var items = [first, second]
        TaskRoutines.advance(&items, at: time(12, 9), calendar: calendar)
        items[1].done = true
        TaskRoutines.advance(&items, at: time(12, 10), calendar: calendar)
        let nextPrerequisite = try #require(items.first { !$0.done && $0.seriesID == first.id })
        #expect(items.first { !$0.done && $0.seriesID == second.id }?.dependency == nextPrerequisite.id)
    }

    @Test func routineLearnsOnlyFromCompletedTimedOccurrences() {
        var routine = PlanTask("Water plants", minutes: 12)
        routine.repeated = .daily
        var items = [routine]
        for day in 1...3 {
            items[day - 1].completedAt = time(day, 9)
            items[day - 1].recordFocus(seconds: 360, completed: true)
            TaskRoutines.advance(&items, at: time(day, 9), calendar: calendar)
        }
        #expect(items.last?.minutes == 9 && items.last?.originalMinutes == 12)
        var manual = [routine]
        for day in 1...4 {
            manual[day - 1].done = true
            TaskRoutines.advance(&manual, at: time(day, 9), calendar: calendar)
        }
        #expect(manual.last?.minutes == 12)
    }

    @Test func weeklyProjectionShowsEarlierAppointmentsAndAdvancesUnfinishedWork() {
        var early = PlanTask("Check in by phone", minutes: 3)
        early.plannedStart = time(13, 7)
        let event = Commitment("Train", start: time(13, 6), end: time(13, 6, 40))
        let flexible = PlanTask("Read", minutes: 25)
        let days = WeekOutlook.project(
            at: time(12, 23), today: [], tasks: [early, flexible], events: [event], reports: [],
            limit: 10, breaks: false, preferences: .init(), calendar: calendar)
        #expect(days.count == 7)
        #expect(days[1].blocks.map(\.kind) == [.fixed(event.id), .task(early.id), .task(flexible.id)])
        #expect(days[1].blocks.map(\.start) == [time(13, 6), time(13, 7), time(13, 9)])
        let flexibleBlocks = days.flatMap(\.blocks).filter { $0.kind == .task(flexible.id) }
        #expect(flexibleBlocks.map(\.minutes) == [7, 10, 8])
    }

    @Test func minimumModeAndFeedbackRespectTheirScope() {
        var mode = PlanTuning(date: time(13))
        mode.minimumDay = true
        mode.manualCapacity = 1
        let book = PlanTask("Read", minutes: 10, category: .study)
        let walk = PlanTask("Walk", minutes: 10, category: .personal)
        let prefs = PlannerPreferences(
            tuning: mode,
            votes: [
                SuggestionVote(.fits, category: .study, date: time(12)),
                SuggestionVote(.tooMuch, category: .personal, date: time(12)),
            ])
        let small = Planner.schedule(
            at: time(13, 9), tasks: [walk, book], commitments: [], reports: [], dailyLimit: 100,
            preferences: prefs, calendar: calendar)
        #expect(small.map(\.kind) == [.task(book.id)])
        #expect(small.map(\.minutes) == [3])
        let next = Planner.schedule(
            at: time(14, 9), tasks: [walk, book], commitments: [], reports: [], dailyLimit: 100,
            breaks: false, preferences: prefs, calendar: calendar)
        #expect(next.map(\.minutes) == [10, 10])
    }

    @Test func conflictResolutionUsesCalendarBoundaries() throws {
        let recurring = Commitment("Class", start: time(2, 9), end: time(2, 10), recurrence: .weekly)
        let appointment = Commitment("Library", start: time(16, 9, 33), end: time(16, 10))
        #expect(
            ScheduleConflicts.overlapping(appointment, in: [recurring, appointment], calendar: calendar)
                == [recurring])
        let free = try #require(
            ScheduleConflicts.nextFree(appointment, in: [recurring], calendar: calendar))
        #expect(free.start == time(16, 10) && free.end == time(16, 10, 27))
    }

    @Test func mixedScheduleSimulationHonorsBudgetTimingAndDependencies() {
        // A reproducible sequence covers dense, empty, minimum-day, and nearly exhausted days.
        var state = UInt64(713)
        func sample(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(count))
        }
        for _ in 0..<160 {
            let now = time(13, 8 + sample(15))
            func later(_ minutes: Int) -> Date { now.addingTimeInterval(Double(minutes) * 60) }
            let limit = sample(81)
            let used = sample(30)
            let buffer = sample(15)
            let events = (0..<sample(9)).map { i in
                let start = sample(160) - 15
                return Commitment("Event \(i)", start: later(start), end: later(start + 1 + sample(45)))
            }
            var items: [PlanTask] = []
            for i in 0..<12 {
                var task = PlanTask("Task \(i)", minutes: 1 + sample(30))
                if sample(3) == 0 { task.plannedStart = later(sample(180)) }
                if sample(4) == 0 { task.after = later(sample(200)) }
                if i > 0, sample(3) == 0 { task.dependency = items[sample(i)].id }
                task.archived = sample(12) == 0
                task.done = sample(11) == 0
                items.append(task)
            }
            var tuning = PlanTuning(date: now)
            tuning.minimumDay = sample(5) == 0
            let prefs = PlannerPreferences(
                tuning: tuning, order: items.reversed().map(\.id), bufferMinutes: buffer)
            let blocks = Planner.schedule(
                at: now, tasks: items, commitments: events, reports: [], dailyLimit: limit,
                usedMinutes: used,
                breaks: sample(2) == 0, preferences: prefs, calendar: calendar)
            let work = tasks(in: blocks)
            let occupied = Planner.workExclusions(
                at: now, commitments: events, bufferMinutes: buffer, calendar: calendar)
            #expect(
                work.reduce(0) { $0 + $1.minutes }
                    <= max(0, (tuning.minimumDay ? min(5, limit) : limit) - used))
            #expect(!tuning.minimumDay || work.count <= 1)
            var finished = Set(items.filter(\.done).map(\.id))
            for block in work {
                guard case .task(let id) = block.kind, let task = items.first(where: { $0.id == id }) else {
                    continue
                }
                #expect(!task.done && task.archived != true)
                #expect(block.start >= max(now, task.earliest) && block.end <= time(14))
                #expect(!occupied.contains { $0.start < block.end && block.start < $0.end })
                #expect(task.dependency.map(finished.contains) ?? true)
                if block.minutes == task.minutes { finished.insert(task.id) }
            }
            #expect(zip(work, work.dropFirst()).allSatisfy { $0.end <= $1.start })
        }
    }
}
