import Foundation
import Testing
@testable import PulseEngine

@Suite struct EnergyTimelineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func hourEditsReplaceTheBucketButDoNotRewriteEarlierHours() throws {
        let date = time(19, 16)
        let checks = [CheckIn(date: time(19, 9), energy: 3, clarity: 4, interest: 4),
                      CheckIn(date: time(19, 9, 30), energy: 4, clarity: 5, interest: 4)]
        let model = EnergyTimeline(signals: [], checkIns: checks,
                                   corrections: [.init(date: time(19, 9, 45), score: 7)],
                                   now: date, calendar: calendar)
        #expect(model.estimate(at: time(19, 9, 40))?.score == 4)
        #expect(model.estimate(at: time(19, 9, 50))?.score == 7)
        #expect(model.estimate(at: time(19, 10))?.source == .estimated)
        #expect(model.daily(on: date)?.score == 7)
        #expect(model.estimate(at: time(19, 15)) == nil)
    }

    @Test func sensorObservationsBecomeAvailableOnlyAfterMeasurement() throws {
        let reports = (1...3).map { CheckIn(date: time($0, 12), energy: 6, clarity: 5, interest: 4) }
        let readings = (1...4).flatMap { day in
            [EnergySignal(date: time(day, 7), restingPulse: 58), EnergySignal(date: time(day, 10), variability: 42)]
        }
        let timeline = EnergyTimeline(signals: readings, checkIns: reports, corrections: [],
                                      now: time(5, 8), calendar: calendar)
        #expect(timeline.estimate(at: time(4, 9)) == nil)
        let point = try #require(timeline.estimate(at: time(4, 10)))
        #expect(point.score == 6 && point.source == .estimated && point.supportDays == 3)
        #expect(timeline.daily(on: time(5, 8)) == nil)
    }

    @Test func correctedBucketsFeedDailyHistoryCalibrationAndForecastExactlyOnce() {
        let checks = (1...3).flatMap { day in
            [CheckIn(date: time(day, 9), energy: 1, clarity: 5, interest: 5),
             CheckIn(date: time(day, 9, 20), energy: 2, clarity: 5, interest: 5),
             CheckIn(date: time(day, 16), energy: 4, clarity: 5, interest: 5)]
        }
        let edits = (1...3).flatMap { day in
            [EnergyCorrection(date: time(day, 9, 30), score: 3), EnergyCorrection(date: time(day, 9, 45), score: 8)]
        }
        let signals = (1...4).map { EnergySignal(date: time($0, 8), restingPulse: 60, variability: 35) }
            + [EnergySignal(date: time(5, 8), restingPulse: 60)]
        let model = EnergyTimeline(signals: signals, checkIns: checks, corrections: edits, now: time(5, 10), calendar: calendar)
        #expect(model.estimate(at: time(1, 9, 40))?.score == 3)
        #expect(model.daily(on: time(1, 15))?.score == 6)
        #expect(model.estimate(at: time(4, 9))?.score == 6)
        #expect(model.daily(on: time(6, 15))?.score == 6)
        #expect(model.estimate(at: time(6, 9))?.score == 8)
        #expect(model.estimate(at: time(5, 9)) == nil)
        #expect(model.daily(on: time(5, 10)) == nil)
    }

    @Test func displayedRecoverySourcesUseOnlyEarlierComparableDays() throws {
        let reports = (1...7).map { CheckIn(date: time($0, 13), energy: Double($0), clarity: 5, interest: 5) }
        let history = (1...7).map {
            EnergySignal(date: time($0, 8), restingPulse: Double(58 + $0), variability: $0 == 4 ? nil : 42)
        }
        let signals = history + [EnergySignal(date: time(8, 8), restingPulse: 64),
                                 EnergySignal(date: time(8, 10), variability: 42)]
        let model = EnergyTimeline(signals: signals, checkIns: reports, corrections: [], now: time(8, 13), calendar: calendar)
        #expect(model.modelBasis(at: time(8, 9), daily: false) == nil)
        let evidence = try #require(model.modelBasis(at: time(8, 12), daily: false))
        #expect(evidence.days.count == 5 && evidence.days.first?.date == time(6, 0))
        #expect(evidence.days.allSatisfy { $0.date < time(8, 0) && $0.date != time(4, 0) })
        #expect(evidence.score == model.estimate(at: time(8, 12))?.score)
        #expect(model.modelBasis(at: time(8, 0), daily: true)?.score == evidence.score)
        #expect(model.modelBasis(at: time(7, 13), daily: false) == nil)
    }

    @Test func lateReadingsDoNotCalibrateEarlierRatings() throws {
        let history = (1...3).map { CheckIn(date: time($0, 8), energy: 9, clarity: 5, interest: 5) }
        let observed = (1...4).map { EnergySignal(date: time($0, 17), restingPulse: 65, variability: 50) }
        let late = EnergyTimeline(signals: observed, checkIns: history, corrections: [], now: time(4, 19), calendar: calendar)
        #expect(late.estimate(at: time(4, 19)) == nil && late.comparableDays(at: time(4, 19)) == 0)
        let ratings = history + (1...3).map { CheckIn(date: time($0, 18), energy: 3, clarity: 5, interest: 5) }
        let paired = EnergyTimeline(signals: observed, checkIns: ratings, corrections: [], now: time(4, 19), calendar: calendar)
        let basis = try #require(paired.modelBasis(at: time(4, 19), daily: false))
        #expect(basis.days.count == 3 && basis.score == 3)
        #expect(paired.daily(on: time(3, 12))?.score == 6)
    }

    @Test func matchingProfilesGiveEachDayAndHourOneVote() throws {
        let early = (1...4).map { EnergySignal(date: time($0, 7), restingPulse: 60, variability: 45) }
        let later = (1...3).map { EnergySignal(date: time($0, 12), restingPulse: 80, variability: 20) }
        let entries = (1...3).flatMap { day in
            [CheckIn(date: time(day, 8), energy: 3, clarity: 5, interest: 5),
             CheckIn(date: time(day, 8, 30), energy: 5, clarity: 5, interest: 5),
             CheckIn(date: time(day, 10), energy: 8, clarity: 5, interest: 5),
             CheckIn(date: time(day, 13), energy: 2, clarity: 5, interest: 5)]
        }
        let model = EnergyTimeline(signals: early + later, checkIns: entries, corrections: [], now: time(4, 11), calendar: calendar)
        let result = try #require(model.modelBasis(at: time(4, 11), daily: false))
        #expect(result.score == 6 && result.days.count == 3)
        #expect(result.days.allSatisfy { $0.readings?.restingPulse == 60 && $0.rating == 6 })
    }

    @Test func forecastSourcesMatchWeekdayAndHourAndRespectAnExplicitOverride() throws {
        let reports = [1, 8, 15, 16, 17].flatMap { day in
            [CheckIn(date: time(day, 8), energy: day == 15 ? 8 : 2, clarity: 5, interest: 5),
             CheckIn(date: time(day, 16), energy: 6, clarity: 5, interest: 5)]
        }
        let model = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: time(19, 12), calendar: calendar)
        let target = time(22, 8)
        let early = try #require(model.modelBasis(at: target, daily: false))
        #expect(Set(early.days.map(\.date)) == Set([time(1, 0), time(8, 0), time(15, 0)]))
        #expect(early.score == 2 && early.score == model.estimate(at: target)?.score)
        let fullDay = try #require(model.modelBasis(at: target, daily: true))
        #expect(fullDay.score == 4 && fullDay.score == model.daily(on: target)?.score)
        let fallback = try #require(model.modelBasis(at: time(21, 8), daily: true))
        #expect(fallback.days.count == 5)
        let manual = try #require(EnergyExpectation(at: target, scope: .hour, score: 9, calendar: calendar))
        let adjusted = EnergyTimeline(signals: [], checkIns: reports, corrections: [], now: time(19, 12),
                                      calendar: calendar, expectations: [manual])
        #expect(adjusted.modelBasis(at: target, daily: false) == nil)
    }

    @Test func forecastsRequireDistinctObservedDaysAndRepresentRepeatedLocalHours() {
        let reports = (18...20).flatMap { day in
            [CheckIn(date: time(day, 2), energy: 3, clarity: 5, interest: 5),
             CheckIn(date: time(day, 14), energy: 8, clarity: 5, interest: 5)]
        }
        let timeline = EnergyTimeline(signals: [], checkIns: reports + [
            CheckIn(date: time(25, 15), energy: 0, clarity: 5, interest: 5)
        ], corrections: [], now: time(23, 16), calendar: calendar)
        let points = timeline.hours(on: time(25, 12))
        let repeated = points.filter { calendar.component(.hour, from: $0.date) == 2 }
        #expect(repeated.count == 2)
        #expect(repeated.allSatisfy { $0.score == 3 && $0.source == .forecast && $0.supportDays == 3 })
        #expect(timeline.estimate(at: time(25, 15))?.score == 8)
        #expect(timeline.estimate(at: time(25, 19)) == nil)
        #expect(timeline.daily(on: time(25, 12))?.score == 5.5)
        #expect(timeline.daily(on: time(29, 12))?.score == 5.5)
        #expect(timeline.daily(on: time(30, 12)) == nil)
        let sparse = EnergyTimeline(signals: [], checkIns: Array(repeating: reports[0], count: 12),
                                    corrections: [], now: time(23, 16), calendar: calendar)
        #expect(sparse.hours(on: time(24, 12)).isEmpty)
        #expect(sparse.daily(on: time(24, 12)) == nil)
    }
}
