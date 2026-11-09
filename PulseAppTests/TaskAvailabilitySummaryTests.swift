import Foundation
import PulseEngine
import Testing

@testable import Pulse

struct TaskAvailabilitySummaryTests {
    @Test func summariesUseLocalClockMinutesAndNameTheClosingDay() throws {
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        func description(_ window: TaskAvailability) -> String {
            // Foundation varies the leading zero with the device’s hour-cycle preference.
            window.formattedHours(in: calendar, locale: locale).replacingOccurrences(of: " 0", with: " ")
        }
        let night = try #require(TaskAvailability(weekdays: [6], startMinute: 22 * 60, endMinute: 6 * 60))
        #expect(description(night) == "Friday · 22:00 to 6:00 next day")
        let full = try #require(TaskAvailability(weekdays: Set(1...7), startMinute: 9 * 60, endMinute: 9 * 60))
        #expect(description(full) == "Every day · 24 hours from 9:00")
        let office = try #require(TaskAvailability(weekdays: Set(2...6), startMinute: 9 * 60, endMinute: 17 * 60))
        #expect(description(office) == "Weekdays · 9:00 to 17:00")
    }
}
