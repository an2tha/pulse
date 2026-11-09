import Foundation
import PulseEngine
import Testing
@testable import Pulse

@MainActor struct PreFocusSuggestionTests {
    private let calendar = Calendar.current
    private var opening: Date { calendar.date(bySettingHour: 13, minute: 0, second: 0, of: .now)! }
    private var now: Date { opening.addingTimeInterval(-3600) }
    private let walk = EnergyActivity(title: "Walk by the river", minutes: 20, kind: .boost)
    private let stretch = EnergyActivity.presetBoosts[3]

    private func entries(_ activity: EnergyActivity, gains: [Int], ending day: Int = -1) -> [EnergyActivityLog] {
        gains.enumerated().map { index, gain in
            let started = calendar.date(byAdding: .day, value: day - index, to: now)!
            return EnergyActivityLog(activity: activity, started: started, before: 3, after: 3 + gain,
                                     finished: started.addingTimeInterval(Double(activity.minutes * 60)))
        }
    }

    private func workspace() -> Workspace {
        let store = Workspace()
        store.isDemo = true
        store.ready = true
        store.journal.customEnergyActivities = [walk]
        store.journal.energyActivityLogs = entries(walk, gains: [3, 4, 4]) + entries(stretch, gains: [1, 2, 1])
        return store
    }

    private var focus: WeeklyTimeBlock {
        var block = WeeklyTimeBlock(kind: .focus, hours: TaskAvailability(weekdays: Set(1...7), startMinute: 780, endMinute: 825)!)
        block.setSingleDate(opening)
        return block
    }

    @Test func strongestPersonalBoostBecomesTheActualPlannedInterval() throws {
        let store = workspace()
        let suggestion = try #require(store.preFocusSuggestion(for: focus, opening: opening, at: now))
        #expect(suggestion.activity == walk)
        #expect(suggestion.typicalChange == 4 && suggestion.days == 3)
        var saved = focus
        saved.boostActivityID = suggestion.activity.id
        store.journal.timeBlocks = [saved]
        let blocks = store.preferences.weeklyBlocks(on: opening, commitments: [], reports: [])
        let prep = try #require(blocks.first { $0.kind == .timeBlock(saved.id, .boost) })
        #expect(DateInterval(start: prep.start, end: prep.end) == suggestion.interval)
        #expect(store.preFocusSuggestion(for: saved, opening: opening, at: now) == nil)
    }

    @Test func shorterBoostCanFitAfterACommitmentOrProtectedTime() throws {
        let store = workspace()
        store.journal.events = [Commitment("Lesson", start: now, end: opening.addingTimeInterval(-8 * 60))]
        store.journal.bufferMinutes = 5
        let suggestion = try #require(store.preFocusSuggestion(for: focus, opening: opening, at: now))
        #expect(suggestion.activity == stretch && suggestion.interval.duration == 180)
        store.journal.bufferMinutes = 6
        #expect(store.preFocusSuggestion(for: focus, opening: opening, at: now) == nil)
        store.journal.events = []
        store.journal.timeBlocks = [.init(kind: .protected, hours: TaskAvailability(weekdays: Set(1...7), startMinute: 720, endMinute: 776)!)]
        #expect(store.preFocusSuggestion(for: focus, opening: opening, at: now)?.activity == stretch)
        store.journal.restDate = opening
        #expect(store.preFocusSuggestion(for: focus, opening: opening, at: now) == nil)
    }

    @Test func requiresThreeDistinctCompletedDatesAndPositivePersonalChange() {
        let store = workspace()
        let recent = entries(walk, gains: [5, 5])
        let ongoing = EnergyActivityLog(activity: walk, started: now, before: 3)
        let future = entries(walk, gains: [6], ending: 1)
        let drain = EnergyActivity.presets.last!
        store.journal.energyActivityLogs = recent + recent + future + [ongoing]
        store.journal.energyActivityLogs?.append(contentsOf: entries(stretch, gains: [-1, 0, 0]))
        store.journal.energyActivityLogs?.append(contentsOf: entries(drain, gains: [6, 6, 6]))
        #expect(store.preFocusSuggestion(for: focus, opening: opening, at: now) == nil)
        store.journal.energyActivityLogs?.append(contentsOf: entries(walk, gains: [5], ending: -3))
        #expect(store.preFocusSuggestion(for: focus, opening: opening, at: now)?.days == 3)
        var protected = focus
        protected.kind = .protected
        #expect(store.preFocusSuggestion(for: protected, opening: opening, at: now) == nil)
        #expect(store.preFocusSuggestion(for: focus, opening: opening, at: opening) == nil)
    }
}
