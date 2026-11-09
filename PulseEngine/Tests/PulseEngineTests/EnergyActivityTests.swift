import Foundation
import Testing
@testable import PulseEngine

@Suite struct EnergyActivityTests {
    private let reference = Date(timeIntervalSince1970: 1_736_784_000) // 12:00 UTC, 13 January 2025.
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }

    @Test func scoresUseTimeMatchedDaysAndNeverBorrowLaterOrMissingMeasurements() {
        let now = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: reference)!
        let week = (1...7).map { EnergySignal(date: now.addingTimeInterval(-Double($0)*86400), variability: Double($0)*10) }
        let otherTimes = (1...7).map { EnergySignal(date: now.addingTimeInterval(-Double($0)*86400 + 8*3600), variability: 600) }
        let sameDay = [EnergySignal(date: now, variability: 35), EnergySignal(date: now.addingTimeInterval(-60), variability: 45)]
        let invalid = [EnergySignal(date: now, variability: .nan), EnergySignal(date: now.addingTimeInterval(60), variability: 300),
                       EnergySignal(date: now, restingPulse: 60)]
        let score = PersonalHRV(signals: week + otherTimes + sameDay + invalid, at: now, calendar: calendar)
        #expect(score.percentile == 50 && score.days == 7 && score.samples == 2 && score.current == 40 && score.baseline == 40)
        #expect(PersonalHRV(signals: week + invalid, at: now, calendar: calendar).percentile == nil)
        let short = PersonalHRV(signals: Array(week.prefix(6)) + sameDay, at: now, calendar: calendar)
        #expect(short.percentile == nil && short.days == 6)
        let repeated = PersonalHRV(signals: Array(repeating: week[0], count: 50) + sameDay, at: now, calendar: calendar)
        #expect(repeated.days == 1 && repeated.percentile == nil)
    }

    @Test func activityPatternsNeedThreeDistinctDaysAndKeepBothPositiveAndNegativeChanges() throws {
        let activity = try #require(EnergyActivity.presetBoosts.first)
        func log(_ days: Int, _ after: Int) -> EnergyActivityLog {
            let start = reference.addingTimeInterval(Double(days)*86400)
            return .init(activity: activity, started: start, before: 4, after: after, finished: start.addingTimeInterval(240))
        }
        let duplicate = Array(repeating: log(0, 8), count: 25)
        #expect(EnergyActivityLog.typicalChange(for: activity.id, in: duplicate, calendar: calendar) == nil)
        let result = try #require(EnergyActivityLog.typicalChange(for: activity.id, in: duplicate + [log(1, 2), log(2, 3)], calendar: calendar))
        #expect(result.change == -1 && result.days == 3)
        #expect(EnergyActivity.presets.allSatisfy { $0.isValid })
        #expect(Set(EnergyActivity.presets.map(\.id)).count == EnergyActivity.presets.count)
        #expect(!EnergyActivityLog(activity: activity, started: reference, before: 12).isValid)
        #expect(!EnergyActivityLog(activity: activity, started: reference, before: 5, after: 6, finished: reference.addingTimeInterval(-1)).isValid)
    }
}
