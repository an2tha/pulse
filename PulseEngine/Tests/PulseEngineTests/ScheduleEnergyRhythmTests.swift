import Foundation
import Testing
@testable import PulseEngine

struct ScheduleEnergyRhythmTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }
    private let schedule = PlannedSleepWindow(wake: 420, targetMinutes: 480)

    @Test(arguments: [(3, 29, 23), (10, 25, 25), (11, 10, 24)])
    func emptyTimelineCoversEveryLocalHour(example: (Int, Int, Int)) throws {
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: example.0, day: example.1)))
        let timeline = EnergyTimeline(signals: [], checkIns: [], corrections: [], now: day, calendar: calendar)
        let curve = timeline.projectedHours(on: day, sleepWindow: schedule)
        #expect(curve.count == example.2)
        #expect(Set(curve.map(\.date)).count == curve.count)
        #expect(curve.allSatisfy { $0.source == .rhythm && $0.supportDays == 0 && (0...10).contains($0.score) })
        #expect((curve.map(\.score).max() ?? 0) - (curve.map(\.score).min() ?? 0) > 2)
    }

    @Test func demoHistoryAndSparseCheckInsRefineTheFullCurve() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
        let prior = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let sparse = [CheckIn(date: prior, energy: 1, clarity: 5, interest: 5)]
        let demo = (0..<7).map { offset in
            CheckIn(date: now.addingTimeInterval(Double(-offset) * 86400), energy: 6, clarity: 6, interest: 7)
        }
        func curve(_ ratings: [CheckIn]) -> [EnergyPoint] {
            EnergyTimeline(signals: [], checkIns: ratings, corrections: [], now: now, calendar: calendar)
                .projectedHours(on: now, sleepWindow: schedule)
        }
        let baseline = curve([])
        let adapted = curve(sparse)
        #expect(adapted[12].score < baseline[12].score)
        #expect(adapted[12].score > 1)
        #expect(adapted[12].supportDays == 1)
        #expect(adapted[2] == baseline[2])
        let example = curve(demo)
        #expect(example.count == 24)
        #expect(example[12].score == 6)
        #expect(example[12].source == .reported)
    }

    @Test func learnedForecastStillRespondsToPreviewedSleep() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        let reports = (1...14).map { offset in
            CheckIn(date: now.addingTimeInterval(Double(-offset) * 86400), energy: 7, clarity: 6, interest: 6)
        }
        let timeline = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: now, calendar: calendar)
        let original = timeline.projectedHours(on: tomorrow, sleepWindow: schedule, referenceWindow: schedule)
        let shifted = timeline.projectedHours(on: tomorrow, sleepWindow: schedule.moving(.wake, to: 540), referenceWindow: schedule)
        #expect(original[12].score != shifted[12].score)
        #expect(original[12].supportDays == shifted[12].supportDays)
        #expect(original.allSatisfy { (0...10).contains($0.score) })
        #expect(EnergyTurningPoint.find(in: original).map(\.id) != EnergyTurningPoint.find(in: shifted).map(\.id))
        let shortened = schedule.moving(.bedtime, to: 0).moving(.wake, to: 420)
        let lessSleep = timeline.projectedHours(on: tomorrow, sleepWindow: shortened, referenceWindow: schedule)
        #expect(lessSleep.map(\.score).reduce(0, +) < original.map(\.score).reduce(0, +))
    }

    @Test func wakeTimeMovesRhythmAndCorrectionsWin() throws {
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10)))
        let timeline = EnergyTimeline(signals: [], checkIns: [], corrections: [.init(date: date, score: 2)],
                                      now: date, calendar: calendar)
        let curve = timeline.projectedHours(on: date, sleepWindow: schedule)
        let later = timeline.projectedHours(on: date, sleepWindow: schedule.moving(.wake, to: 540))
        #expect(curve[15].score == later[17].score)
        #expect(curve[10].source == .corrected)
        #expect(curve[10].score == 2)
        #expect(curve[9].source == .rhythm)
    }
}
