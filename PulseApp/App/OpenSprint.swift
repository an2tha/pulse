import Foundation
import PulseEngine
import UIKit

extension Workspace {
    func openSprintSeconds(at date: Date) -> Double {
        guard journal.active == nil, planReadyForOpenSprint else { return 0 }
        let room = openSprintRoom(at: date, active: nil, verifySchedule: false)
        return floor(room / 60) * 60
    }

    @discardableResult func startOpenSprint(at date: Date = .now) -> Bool {
        guard journal.active == nil else { return false }
        let room = floor(openSprintRoom(at: date, active: nil, verifySchedule: true) / 60) * 60
        guard room >= 60 else { return false }
        change { journal in
            journal.beginLocalSession(ActiveSession(openSprintSeconds: room, now: date, tick: SessionClock.tick, boot: SessionClock.boot))
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        return true
    }

    func openSprintRoom(at date: Date, active: ActiveSession?, verifySchedule: Bool) -> Double {
        let calendar = Calendar.current
        guard ready, !restoring, calendarReadyForStart, !Task.isCancelled,
              journal.restDate.map({ calendar.isDate($0, inSameDayAs: date) }) != true,
              let day = calendar.dateInterval(of: .day, for: date) else { return 0 }
        let events = planningEvents
        if journal.breaks, Planner.recoveryInterval(journal.recovery, at: date, commitments: events) != nil { return 0 }

        let options = preferences
        guard options.capacity(at: date, reports: journal.reports, calendar: calendar) > 0 else { return 0 }
        let activeSeconds = active?.record(now: date, tick: SessionClock.tick, boot: SessionClock.boot).seconds(in: day) ?? 0
        let used = journal.sessions.reduce(activeSeconds) { $0 + $1.seconds(in: day) }
        let budget = Capacity.workloadLimit(userLimit: journal.limit, reports: journal.reports, at: date, calendar: calendar)
        let minimum = options.tuning.map { $0.minimumDay && calendar.isDate($0.date, inSameDayAs: date) } ?? false
        var seconds = Double(minimum ? min(budget, 5) : budget) * 60 - used
        var boundary = min(day.end, options.workEnd(on: date))
        for interval in Planner.workExclusions(at: date, commitments: events, reports: journal.reports, preferences: options)
        where interval.end > date {
            boundary = min(interval.start, boundary)
        }
        guard boundary > date, seconds > 0 else { return 0 }

        // Preview the displayed plan. Before reserving actual time, verify against
        // today's tasks again in case a pending edit has not reached the timeline yet.
        let plan = verifySchedule ? Planner.schedule(
            at: date, tasks: schedulingTasks, commitments: events, reports: journal.reports,
            dailyLimit: journal.limit, usedMinutes: Int(ceil(used / 60)), breaks: journal.breaks,
            recovery: journal.recovery, nextTaskID: journal.nextTaskID, preferences: options, calendar: calendar
        ) : blocks
        for block in plan where block.end > date {
            if case .task = block.kind {
                let start = max(date, block.start)
                boundary = min(boundary, start)
                seconds -= block.end.timeIntervalSince(start)
            } else if block.kind == .rest {
                boundary = min(boundary, block.start)
            }
        }
        return max(0, min(120, seconds, boundary.timeIntervalSince(date)))
    }
}
