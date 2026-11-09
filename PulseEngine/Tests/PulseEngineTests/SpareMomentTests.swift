import Foundation
import Testing

@testable import PulseEngine

@Suite struct SpareMomentTests {
    private let now = Date(timeIntervalSince1970: 1_788_782_400)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func choicesFitInFullAndKeepExistingTaskState() {
        let quick = PlanTask("Write a note", minutes: 4)
        let exact = PlanTask("Water the plants", minutes: 5)
        var later = quick.duplicate()
        later.after = now.addingTimeInterval(30)
        var dependency = quick.duplicate()
        dependency.dependency = exact.id
        var archived = quick.duplicate()
        archived.archived = true
        let blocked = PlanTask("Make dinner", minutes: 20)
        let tasks = [quick, blocked, dependency, archived, exact, later]
        let matches = Planner.spareMoments(
            at: now, minutes: 5, tasks: tasks, commitments: [], reports: [], dailyLimit: 60,
            preferences: .init(order: [exact.id, quick.id]), calendar: calendar)
        #expect(matches.map(\.kind) == [.task(exact.id), .task(quick.id)])
        #expect(matches.map(\.minutes) == [5, 4])
        #expect(matches.allSatisfy { $0.start == now })
    }

    @Test func preservesBufferAndPinnedBudget() {
        let five = PlanTask("Read", minutes: 5)
        let six = PlanTask("Write", minutes: 6)
        var pin = PlanTask("Call", minutes: 10)
        pin.plannedStart = now.addingTimeInterval(3600)
        let event = Commitment("Train", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200))
        let matches = Planner.spareMoments(
            at: now, minutes: 15, tasks: [five, six, pin], commitments: [event], reports: [], dailyLimit: 30,
            preferences: .init(bufferMinutes: 5), calendar: calendar)
        #expect(matches.map(\.kind) == [.task(five.id)])
        let reserved = Planner.spareMoments(at: now, minutes: 15, tasks: [five, six, pin], commitments: [],
                                            reports: [], dailyLimit: 16, usedMinutes: 2, calendar: calendar)
        #expect(reserved.isEmpty)
        pin.plannedStart = now
        #expect(Planner.spareMoments(at: now, minutes: 5, tasks: [five, pin], commitments: [], reports: [],
                                     dailyLimit: 30, calendar: calendar).isEmpty)
    }

    @Test func respectsCapacityRecoveryAndMidnight() {
        let work = PlanTask("Read", minutes: 5)
        let recovery = DateInterval(start: now.addingTimeInterval(-20), end: now.addingTimeInterval(240))
        #expect(Planner.spareMoments(at: now, minutes: 15, tasks: [work], commitments: [], reports: [],
                                     dailyLimit: 60, recovery: recovery, calendar: calendar).isEmpty)
        var tuning = PlanTuning(date: now)
        tuning.manualCapacity = 1
        #expect(Planner.spareMoments(at: now, minutes: 15, tasks: [work], commitments: [], reports: [],
                                     dailyLimit: 60, preferences: .init(tuning: tuning), calendar: calendar).isEmpty)
        let end = calendar.dateInterval(of: .day, for: now)!.end
        #expect(Planner.spareMoments(at: end.addingTimeInterval(-270), minutes: 10, tasks: [work], commitments: [],
                                     reports: [], dailyLimit: 60, calendar: calendar).isEmpty)
    }
}
