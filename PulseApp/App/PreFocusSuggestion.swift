import Foundation
import PulseEngine

struct PreFocusSuggestion: Equatable {
    let activity: EnergyActivity
    let typicalChange: Double
    let days: Int
    let interval: DateInterval
}

extension Workspace {
    func rankedBoosts(through date: Date, calendar: Calendar = .current) -> [(activity: EnergyActivity, change: Double, days: Int)] {
        guard let logs = journal.energyActivityLogs, logs.count >= 3 else { return [] }
        let groups = Dictionary(grouping: logs.filter { ($0.finished ?? .distantFuture) <= date }, by: { $0.activity.id })
        return energyActivities.compactMap { activity -> (EnergyActivity, Double, Int)? in
            guard activity.kind == .boost, activity.isValid, let history = groups[activity.id], history.count >= 3,
                  let usual = EnergyActivityLog.typicalChange(for: activity.id, in: history, calendar: calendar),
                  usual.change > 0 else { return nil }
            return (activity, usual.change, usual.days)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.2 != right.2 { return left.2 > right.2 }
            if left.0.minutes != right.0.minutes { return left.0.minutes < right.0.minutes }
            return left.0.id.uuidString < right.0.id.uuidString
        }
    }

    func preFocusSuggestion(for rule: WeeklyTimeBlock, opening: Date, at date: Date = .now,
                            calendar: Calendar = .current) -> PreFocusSuggestion? {
        guard ready, !restoring, calendarReadyForStart, rule.kind == .focus, rule.boostActivityID == nil, opening > date else { return nil }
        let ranked = rankedBoosts(through: date, calendar: calendar)
        guard !ranked.isEmpty else { return nil }
        let events = planningEvents
        let active = journal.active?.record(now: date, tick: SessionClock.tick, boot: SessionClock.boot)
        guard let inputs = DayScheduleInputs(journal: journal, events: events, tasks: schedulingTasks,
                                             at: date, active: active, calendar: calendar) else { return nil }
        var holds: [DateInterval] = []
        if let rest = journal.restDate.flatMap({ calendar.dateInterval(of: .day, for: $0) }) {
            if rest.start <= opening && opening < rest.end { return nil }
            holds.append(rest)
        }
        if journal.breaks, let rest = Planner.recoveryInterval(journal.recovery, at: date, commitments: events, calendar: calendar) {
            if rest.start <= opening && opening < rest.end { return nil }
            holds.append(rest)
        }
        let room = preferences.preFocusMinutes(for: rule, opening: opening, at: date, tasks: inputs.tasks,
                                               commitments: inputs.events, reports: journal.reports,
                                               extraHolds: holds, calendar: calendar)
        guard let (activity, change, days) = ranked.first(where: { $0.0.minutes <= room }) else { return nil }
        return PreFocusSuggestion(activity: activity, typicalChange: change, days: days,
                                  interval: DateInterval(start: opening.addingTimeInterval(Double(-activity.minutes) * 60), end: opening))
    }
}
