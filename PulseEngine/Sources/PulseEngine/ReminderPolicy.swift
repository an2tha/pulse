import Foundation

public struct ReminderPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var taskAlerts = false
    public var morningCheckIn = false
    public var morningMinute = 9 * 60
    public var recoveryPrompt = false
    public var quietHours = true
    public var quietStart = 21 * 60
    public var quietEnd = 8 * 60
    public var widgetDetails = false
    public var liveTimer = false
    public var showTitles = false
    public init() {}

    public func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return isQuiet(minute: minute)
    }

    private func isQuiet(minute: Int) -> Bool {
        guard quietHours else { return false }
        if quietStart == quietEnd { return true }
        return quietStart < quietEnd
            ? (quietStart..<quietEnd).contains(minute) : minute >= quietStart || minute < quietEnd
    }

    public var morningDeliveryMinute: Int? {
        guard morningCheckIn else { return nil }
        if !isQuiet(minute: morningMinute) { return morningMinute }
        return quietStart != quietEnd ? quietEnd : nil
    }

    public func nextAllowed(_ date: Date, calendar: Calendar = .current) -> Date? {
        guard isQuiet(date, calendar: calendar) else { return date }
        guard quietStart != quietEnd else { return nil }
        return calendar.nextDate(
            after: date, matching: DateComponents(hour: quietEnd / 60, minute: quietEnd % 60, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}

public struct PlanningAlert: Equatable, Sendable {
    public var id: String
    public var date: Date
    public init(id: String, date: Date) {
        self.id = id
        self.date = date
    }
}

/// Deterministically spreads competing reminders. A reconciliation always starts from the
/// original requested dates, including requests shifted out of quiet hours earlier.
public enum ReminderPolicy {
    public static func schedule(
        _ candidates: [PlanningAlert], after now: Date, preferences: ReminderPreferences,
        occupied: [Date] = [], calendar: Calendar = .current
    ) -> [PlanningAlert] {
        guard preferences.enabled else { return [] }
        var result: [PlanningAlert] = []
        var reserved = occupied.sorted()
        for item in candidates.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) where item.date > now {
            guard var date = preferences.nextAllowed(item.date, calendar: calendar) else { continue }
            // Do not let a backlog spill into a stream of reminders on subsequent days.
            let intendedDay = calendar.startOfDay(for: date)
            for other in reserved where abs(other.timeIntervalSince(date)) < 900 {
                guard let allowed = preferences.nextAllowed(other.addingTimeInterval(900), calendar: calendar) else {
                    break
                }
                date = allowed
            }
            guard calendar.isDate(date, inSameDayAs: intendedDay),
                reserved.lazy.filter({ calendar.isDate($0, inSameDayAs: date) }).count < 6
            else { continue }
            result.append(PlanningAlert(id: item.id, date: date))
            reserved.append(date)
            reserved.sort()
            if result.count == 48 { break }
        }
        return result
    }
}
