import Foundation
import Testing
@testable import PulseEngine

@Suite struct SkipTimingRecommendationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func skip(_ task: PlanTask, _ reason: TaskSkipReason, day: Int, hour: Int, energy: Int) -> TaskSkipRecord {
        let start = time(day, hour)
        return TaskSkipRecord(taskID: task.id, title: task.title, scheduledStart: start,
                              skippedAt: start.addingTimeInterval(1800), reason: reason, energy: energy)
    }

    @Test func repeatedTimingSkipsChangePickButDoNotDisplaceAppointmentsOrManualChoices() throws {
        let task = PlanTask("Practice", minutes: 8)
        let records = [3, 7].map { skip(task, .interrupted, day: $0, hour: 9, energy: 7) }
        let events = [Commitment("Review", start: time(10, 11), end: time(10, 12))]
        func slots(_ history: [TaskSkipRecord], exact: Date? = nil) -> [TaskPlacement] {
            Planner.placements(for: task.id, at: time(10, 9), tasks: [task], commitments: events, reports: [],
                               dailyLimit: 30, breaks: false, calendar: calendar, exactStart: exact, skipRecords: history)
        }
        let normal = try #require(slots([]).first { $0.recommended })
        #expect(normal.start == time(10, 9))
        let options = slots(records)
        let suggestion = try #require(SkipTimingRecommendation.find(in: options, for: task))
        #expect(suggestion.placement.start == time(10, 12))
        #expect(suggestion.reason.contains("2 days"))
        #expect(slots(records, exact: time(10, 9, 17)).first?.start == time(10, 9, 17))
        #expect(slots(records, exact: time(10, 11)).isEmpty)
        #expect(SkipTimingRecommendation.find(in: slots([records[0]]), for: task) == nil)
    }

    @Test func twoEnergyReportsFavorAFeasibleHigherEstimateEvenAtDifferentSkipHours() throws {
        var task = PlanTask("Read", minutes: 8)
        task.energyOverride = 4
        let records = [skip(task, .lowEnergy, day: 2, hour: 8, energy: 4),
                       skip(task, .lowEnergy, day: 6, hour: 16, energy: 4)]
        var prefs = PlannerPreferences()
        prefs.expectations = [
            try #require(EnergyExpectation(at: time(10, 9), scope: .day, score: 4, calendar: calendar)),
            try #require(EnergyExpectation(at: time(10, 15), scope: .hour, score: 5, calendar: calendar))
        ]
        func choices(_ item: PlanTask, _ survey: [TaskSkipRecord]) -> [TaskPlacement] {
            Planner.weekPlacements(for: item.id, at: time(10, 9), tasks: [item], commitments: [], reports: [],
                                   dailyLimit: 30, preferences: prefs, calendar: calendar, skipRecords: survey)
        }
        let normal = choices(task, [])
        #expect(normal.first(where: \.recommended)?.start == time(10, 9))
        let learned = choices(task, records)
        let suggestion = try #require(SkipTimingRecommendation.find(in: learned, for: task))
        #expect(suggestion.placement.start == time(10, 15))
        #expect(suggestion.reason.contains("median") && suggestion.reason.contains("4/10"))
        #expect(SkipTimingRecommendation.find(in: learned, current: suggestion.placement, for: task) == nil)

        task.due = time(10, 12)
        let constrained = choices(task, records)
        let timely = try #require(constrained.first { $0.recommended })
        #expect(timely.start < time(10, 12))
        #expect(SkipTimingRecommendation.find(in: constrained, for: task) == nil)
    }

    @Test func noTimingClaimForUnrelatedReasonsOrEqualAndMissingForecasts() {
        var task = PlanTask("Grocery list", minutes: 8)
        task.inboxOnly = true
        let now = time(10, 9)
        for reasons: [TaskSkipRecord] in [
            [1, 2].map { skip(task, .blocked, day: $0, hour: 9, energy: 2) },
            [skip(task, .lowEnergy, day: 3, hour: 9, energy: 3), skip(task, .lowEnergy, day: 4, hour: 16, energy: 3)]
        ] {
            let slots = Planner.weekPlacements(for: task.id, at: now, tasks: [task], commitments: [], reports: [],
                                               dailyLimit: 30, calendar: calendar, skipRecords: reasons)
            #expect(SkipTimingRecommendation.find(in: slots, for: task) == nil)
        }
    }
}
