import PulseEngine
import SwiftUI

struct TaskAvailabilityRow: View {
    @Binding var availability: TaskAvailability?
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationLink {
            TaskAvailabilityEditor(availability: $availability)
        } label: {
            if let availability {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Available hours")
                    Text(availability.formattedHours(in: calendar, locale: locale)).font(.subheadline).foregroundStyle(Color.moss)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LabeledContent("Available hours", value: "Anytime")
            }
        }
        .accessibilityIdentifier("task-available-hours")
    }
}

extension TaskAvailability {
    func formattedHours(in calendar: Calendar = .current, locale: Locale = .current) -> String {
        let week = AvailabilityWeek(calendar: calendar, locale: locale)
        let days = week.preset(for: weekdays)?.label(in: week)
            ?? week.ordered.filter(weekdays.contains).map { week.calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        return days + " · " + formattedClockRange(locale: locale)
    }

    func formattedClockRange(locale: Locale = .current) -> String {
        var clock = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        clock.timeZone = .gmt
        let start = clock.format(clockDate(startMinute))
        if startMinute == endMinute { return "24 hours from " + start }
        let end = clock.format(clockDate(endMinute))
        return start + " to " + end + (endMinute < startMinute ? " next day" : "")
    }
}

private enum DaysPreset: Hashable {
    case daily, weekdays, weekend, one(Int), custom

    func label(in week: AvailabilityWeek) -> String {
        switch self {
        case .daily: "Every day"
        case .weekdays: "Weekdays"
        case .weekend: "Weekends"
        case .one(let day): week.calendar.weekdaySymbols[day - 1]
        case .custom: "Choose days"
        }
    }
}

private struct AvailabilityWeek {
    let calendar: Calendar
    let ordered: [Int]
    let weekend: Set<Int>

    init(calendar: Calendar, locale: Locale) {
        var localized = calendar
        localized.locale = locale
        self.calendar = localized
        ordered = calendar.pulseWeekdays
        weekend = localized.pulseWeekendDays
    }

    func preset(for days: Set<Int>) -> DaysPreset? {
        if days == Set(ordered) { return .daily }
        if days == Set(ordered).subtracting(weekend) { return .weekdays }
        if days == weekend { return .weekend }
        if days.count == 1, let day = days.first { return .one(day) }
        return nil
    }
}

// A fixed UTC day lets the native picker edit a wall-clock time even on a day
// when that hour is missing locally. Pulse applies the local calendar when scheduling.
private func clockDate(_ minute: Int) -> Date {
    Date(timeIntervalSinceReferenceDate: Double(minute * 60))
}

struct TaskAvailabilityEditor: View {
    @Binding var availability: TaskAvailability?
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @State private var days: Set<Int>
    @State private var startMinute: Int
    @State private var endMinute: Int
    @State private var choosingDays = false
    private let required: Bool
    private let showsWeekdays: Bool

    init(availability: Binding<TaskAvailability?>, required: Bool = false, showsWeekdays: Bool = true) {
        self.showsWeekdays = showsWeekdays
        self.required = required
        _availability = availability
        let saved = availability.wrappedValue
        _days = State(initialValue: saved?.weekdays ?? Set(1...7))
        _startMinute = State(initialValue: saved?.startMinute ?? 9 * 60)
        _endMinute = State(initialValue: saved?.endMinute ?? 17 * 60)
    }

    var body: some View {
        let week = AvailabilityWeek(calendar: calendar, locale: locale)
        let preset = choosingDays ? DaysPreset.custom : week.preset(for: days) ?? .custom
        Form {
            if !required {
                Toggle("Limit available hours", isOn: Binding(
                    get: { availability != nil }, set: { enabled in
                        if enabled { update() } else { availability = nil }
                    }
                ))
            }
            if availability != nil {
                if showsWeekdays {
                    Section {
                        Picker("Days", selection: Binding(get: { preset }, set: { selected in
                            choosingDays = selected == .custom
                            switch selected {
                            case .daily: days = Set(week.ordered)
                            case .weekdays: days = Set(week.ordered).subtracting(week.weekend)
                            case .weekend: days = week.weekend
                            case .one(let day): days = [day]
                            case .custom: break
                            }
                            update()
                        })) {
                            ForEach([DaysPreset.daily, .weekdays, .weekend, .custom], id: \.self) {
                                Text($0.label(in: week)).tag($0)
                            }
                            Section("One weekday") {
                                ForEach(week.ordered, id: \.self) { day in
                                    Text(week.calendar.weekdaySymbols[day - 1]).tag(DaysPreset.one(day))
                                }
                            }
                        }
                        if preset == .custom {
                            ForEach(week.ordered, id: \.self) { day in
                                Toggle(week.calendar.weekdaySymbols[day - 1], isOn: Binding(
                                    get: { days.contains(day) }, set: { on in
                                        if on { days.insert(day) } else if days.count > 1 { days.remove(day) }
                                        update()
                                    }
                                )).disabled(days == [day])
                            }
                        }
                    }
                }
                Section {
                    WindowClockFields(startMinute: Binding(get: { startMinute }, set: { startMinute = $0; update() }),
                                      endMinute: Binding(get: { endMinute }, set: { endMinute = $0; update() }))
                } footer: {
                    if endMinute == startMinute { Text("Open for 24 hours from each selected start.") }
                    else if endMinute < startMinute { Text("The selected days are when this window starts.") }
                }
            }
        }
        .formPaper().navigationTitle(required ? (showsWeekdays ? "Days and hours" : "Hours") : "Available hours").navigationBarTitleDisplayMode(.inline)
    }

    private func update() {
        if let window = TaskAvailability(weekdays: days, startMinute: startMinute, endMinute: endMinute) {
            availability = window
        }
    }
}

struct WindowClockFields: View {
    @Binding var startMinute: Int
    @Binding var endMinute: Int

    var body: some View {
        Group {
            DatePicker("From", selection: clock($startMinute), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("task-window-start")
            DatePicker(endMinute <= startMinute ? "Until next day" : "Until",
                       selection: clock($endMinute), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("task-window-end")
        }.environment(\.timeZone, .gmt)
    }

    private func clock(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get: { clockDate(minute.wrappedValue) }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            minute.wrappedValue = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        })
    }
}
