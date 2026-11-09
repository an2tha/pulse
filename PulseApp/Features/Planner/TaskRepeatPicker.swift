import PulseEngine
import SwiftUI

struct TaskRepeatPicker: View {
    @Binding var task: PlanTask
    @Environment(\.calendar) private var calendar

    private var anchorDay: Int {
        calendar.component(.weekday, from: task.plannedStart ?? task.routineAnchor ?? task.after ?? .now)
    }
    private var weeklyDay: Int {
        if let days = task.repeatDays, days.count == 1, let day = days.first { return day }
        return anchorDay
    }
    private var pattern: SchedulePattern {
        if let selected = task.repeatDays {
            if selected.count == 1 { return .weekly }
            if selected == calendar.pulseWeekendDays { return .weekends }
            if selected == Set(1...7).subtracting(calendar.pulseWeekendDays) { return .weekdays }
            return .custom
        }
        switch task.repeated ?? .once {
        case .once: return .once
        case .daily: return .daily
        case .weekdays: return .weekdays
        case .weekly: return .weekly
        }
    }

    var body: some View {
        SchedulePatternFields(pattern: Binding(get: { pattern }, set: apply),
                              weekdays: Binding(get: { task.repeatDays ?? [anchorDay] }, set: { task.repeatDays = $0 }),
                              weeklyDay: weeklyDay)
    }

    private func apply(_ choice: SchedulePattern) {
        let previous = task.repeatDays ?? pattern.weekdays(anchor: anchorDay, calendar: calendar)
        switch choice {
        case .weekly, .weekdays, .weekends, .custom:
            task.repeated = .daily
            task.repeatDays = choice == .custom ? previous : choice.weekdays(anchor: weeklyDay, calendar: calendar)
        case .once: task.repeated = .once; task.repeatDays = nil
        case .daily: task.repeated = .daily; task.repeatDays = nil
        }
    }
}
