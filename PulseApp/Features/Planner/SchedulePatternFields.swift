import PulseEngine
import SwiftUI

enum SchedulePattern: CaseIterable {
    case once, daily, weekdays, weekends, weekly, custom

    func label(weeklyDay: Int, calendar: Calendar) -> String {
        switch self {
        case .once: "Doesn’t repeat"
        case .daily: "Every day"
        case .weekdays: "Weekdays"
        case .weekends: "Weekends"
        case .weekly: "Weekly on " + calendar.weekdaySymbols[weeklyDay - 1]
        case .custom: "Choose days"
        }
    }

    func weekdays(anchor: Int, calendar: Calendar) -> Set<Int> {
        switch self {
        case .daily: return Set(1...7)
        case .weekdays: return Set(1...7).subtracting(calendar.pulseWeekendDays)
        case .weekends: return calendar.pulseWeekendDays
        case .once, .weekly, .custom: return [anchor]
        }
    }
}

extension Calendar {
    var pulseWeekdays: [Int] { (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 } }

    var pulseWeekendDays: Set<Int> {
        let today = startOfDay(for: .now)
        return Set((0..<7).compactMap { offset in
            guard let date = date(byAdding: .day, value: offset, to: today), isDateInWeekend(date) else { return nil }
            return component(.weekday, from: date)
        })
    }
}

/// One shared set of day controls for a recurring to-do or a local-clock reservation.
struct SchedulePatternFields: View {
    @Binding var pattern: SchedulePattern
    @Binding var weekdays: Set<Int>
    let weeklyDay: Int
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var type
    @State private var choosingDays = false

    var body: some View {
        Picker("Repeat", selection: Binding(get: { choosingDays ? .custom : pattern }, set: { next in
            choosingDays = next == .custom
            pattern = next
        })) {
            ForEach(SchedulePattern.allCases, id: \.self) { choice in
                Text(choice.label(weeklyDay: weeklyDay, calendar: calendar)).tag(choice)
            }
        }
        .accessibilityIdentifier("schedule-repeat")
        if pattern == .custom || choosingDays {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { ForEach(calendar.pulseWeekdays, id: \.self) { dayButton($0) } }
                    .fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: type.isAccessibilitySize ? 88 : 48))], spacing: 4) {
                    ForEach(calendar.pulseWeekdays, id: \.self) { dayButton($0) }
                }
            }
            Menu("Day patterns") {
                ForEach([[2, 4, 6], [3, 5]], id: \.self) { days in
                    Button(days.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")) {
                        weekdays = Set(days)
                    }
                }
            }
        }
    }

    private func dayButton(_ day: Int) -> some View {
        let selected = weekdays.contains(day)
        return Button {
            if selected {
                if weekdays.count > 1 { weekdays.remove(day) }
            } else {
                weekdays.insert(day)
            }
        } label: {
            Text(calendar.shortWeekdaySymbols[day - 1])
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 3)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(selected ? Color.paper : Color.journalInk)
                .background(selected ? Color.journalAccent : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.weekdaySymbols[day - 1])
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("repeat-weekday-\(day)")
    }
}

extension WeeklyTimeBlock {
    var hasOpeningInRange: Bool {
        guard let first = firstDate(), lastDay != nil else { return true }
        return nextOpening(after: first.addingTimeInterval(-1)) != nil
    }
}

struct BlockRepeatFields: View {
    @Binding var rule: WeeklyTimeBlock
    let anchor: Date
    var editingStart: Binding<Date>? = nil
    @Environment(\.calendar) private var calendar

    private var anchorDay: Int { calendar.component(.weekday, from: anchor) }
    private var days: Binding<Set<Int>> {
        Binding(get: { rule.hours.weekdays }, set: { values in
            guard let hours = TaskAvailability(weekdays: values, startMinute: rule.hours.startMinute,
                                               endMinute: rule.hours.endMinute) else { return }
            rule.hours = hours
        })
    }
    private var pattern: SchedulePattern {
        if rule.singleDay != nil { return .once }
        let selected = rule.hours.weekdays
        if selected == Set(1...7) { return .daily }
        if selected == calendar.pulseWeekendDays { return .weekends }
        if selected == Set(1...7).subtracting(calendar.pulseWeekendDays) { return .weekdays }
        if selected.count == 1 { return .weekly }
        return .custom
    }

    var body: some View {
        let weeklyDay = pattern == .weekly ? (rule.hours.weekdays.first ?? anchorDay) : anchorDay
        SchedulePatternFields(pattern: Binding(get: { pattern }, set: { next in
            if next == .once {
                rule.setSingleDate(anchor, calendar: calendar)
            } else {
                if rule.singleDay != nil {
                    rule.setSingleDate(nil)
                    rule.setFirstDate(anchor, calendar: calendar)
                    if next == .custom && days.wrappedValue.count == 1 { days.wrappedValue = [anchorDay] }
                }
                if next != .custom { days.wrappedValue = next.weekdays(anchor: weeklyDay, calendar: calendar) }
            }
        }), weekdays: days, weeklyDay: weeklyDay)
        if let editingStart {
            if rule.singleDay != nil || rule.firstDay != nil {
                DatePicker(rule.singleDay == nil ? "Starting" : "Date", selection: Binding(get: { editingStart.wrappedValue }, set: { date in
                    editingStart.wrappedValue = date
                    if rule.singleDay != nil { rule.setSingleDate(date) }
                    else { rule.setFirstDate(date) }
                }), in: ...(rule.lastDate() ?? .distantFuture), displayedComponents: .date)
            } else {
                Button("Set a starting date", systemImage: "calendar") {
                    let start = min(editingStart.wrappedValue, rule.lastDate(in: calendar) ?? .distantFuture)
                    editingStart.wrappedValue = start
                    rule.setFirstDate(start, calendar: calendar)
                }
            }
        }
        if rule.singleDay == nil {
            if let last = rule.lastDate(in: calendar) {
                DatePicker("Last day", selection: Binding(get: { last }, set: { rule.setLastDate($0, calendar: calendar) }),
                           in: (rule.firstDate(in: calendar) ?? .distantPast)..., displayedComponents: .date)
                Button("Remove end date") { rule.setLastDate(nil) }
            } else {
                Button("Add end date", systemImage: "calendar.badge.plus") {
                    let start = rule.firstDate(in: calendar) ?? anchor
                    rule.setLastDate(calendar.date(byAdding: .month, value: 1, to: start) ?? start, calendar: calendar)
                }
            }
        }
    }
}
