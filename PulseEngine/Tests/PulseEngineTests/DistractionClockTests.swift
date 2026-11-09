import Foundation
import Testing
@testable import PulseEngine

struct DistractionClockTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func draft(_ text: String, at date: Date) -> DayDraft {
        LocalDayInput.parse(text, at: date, calendar: calendar, singleTimesAreTaskPins: true)
    }

    @Test func namedDateAndNextClockRollOverLocallyWithoutMovingExplicitPastTimes() throws {
        let morning = time(9, 8)
        let tomorrow = try #require(draft("Call Sam tomorrow at 3pm for 7 minutes", at: morning).tasks.first)
        #expect(tomorrow.title == "Call Sam" && tomorrow.minutes == 7 && tomorrow.plannedStart == time(10, 15))
        #expect(tomorrow.after == time(10, 0))
        #expect(draft("Call Sam at 3pm", at: morning).tasks.first?.plannedStart == time(9, 15))
        #expect(draft("Call Sam at 3pm", at: time(9, 16)).tasks.first?.plannedStart == time(10, 15))
        #expect(draft("Call Sam at 15:00", at: time(9, 15).addingTimeInterval(12)).tasks.first?.plannedStart == time(9, 15))
        #expect(draft("Water herbs at midnight", at: time(9, 23, 55)).tasks.first?.plannedStart == time(10, 0))
        #expect(draft("Call Sam on Friday at noon", at: morning).tasks.first?.plannedStart == time(13, 12))
        #expect(draft("Call Sam today at 3pm", at: time(9, 16)).unrecognized.count == 1)
        #expect(draft("Call Sam at 3", at: morning).unrecognized.count == 1)
    }

    @Test func durationsAndDeadlinesStaySeparateFromExplicitStartTimes() throws {
        let now = time(9, 8)
        let mereDuration = try #require(draft("Read a chapter for 30 minutes", at: now).tasks.first)
        #expect(mereDuration.minutes == 30 && mereDuration.plannedStart == nil && mereDuration.after == nil && mereDuration.due == nil)
        let deadline = try #require(draft("Send slides by tomorrow at 4pm", at: now).tasks.first)
        #expect(deadline.due == time(10, 16) && deadline.plannedStart == nil && deadline.after == nil)
        let normalEvent = LocalDayInput.parse("Call Sam tomorrow at 3pm", at: now, calendar: calendar)
        #expect(normalEvent.tasks.isEmpty && normalEvent.commitments.first?.start == time(10, 15))
        let range = draft("Movie from 5pm to 7pm", at: now)
        #expect(range.tasks.first?.minutes == 120 && range.tasks.first?.plannedStart == time(9, 17) && range.commitments.isEmpty)
        let conflict = draft("Call Sam at 4pm by today at 2pm", at: now)
        #expect(conflict.tasks.isEmpty && conflict.unrecognized.count == 1)
    }

    @Test func rangesPinTasksAndUseElapsedTimeOnTheCorrectLocalDates() throws {
        let input = "Practice cello tomorrow from 3pm to 3:30pm"
        let now = time(9, 9)
        let task = try #require(draft(input, at: now).tasks.first)
        #expect(task.title == "Practice cello" && task.plannedStart == time(10, 15))
        #expect(task.minutes == 30 && task.originalMinutes == 30)
        let normal = LocalDayInput.parse(input, at: now, calendar: calendar)
        #expect(normal.tasks.isEmpty && normal.commitments.first?.start == time(10, 15))
        #expect(normal.commitments.first?.end == time(10, 15, 30))
        #expect(draft("Practice from noon to 13:05", at: time(9, 14)).tasks.first?.plannedStart == time(10, 12))
        #expect(draft("Practice from 11 PM to midnight", at: now).tasks.first?.minutes == 60)
        #expect(draft("Practice tomorrow from 23:00 to 04:00", at: time(27, 10, month: 3)).tasks.first?.minutes == 240)
        #expect(draft("Practice tomorrow from 23:00 to 04:00", at: time(23, 10, month: 10)).tasks.first?.minutes == 360)
        #expect(draft("Practice tomorrow from 23:00 to 02:30", at: time(28, 10, month: 3)).tasks.first?.minutes == 210)
    }

    @Test func conflictingOrIndeterminateRangesRemainForReview() {
        let now = time(9, 9)
        let inputs = ["Practice from 3 to 4", "Practice from 3pm to 3pm", "Practice from 25:00 to 03:00",
                      "Practice from 10:00 to 10:60", "Practice from 1 1pm to midnight", "Practice from 3pm to 4pm for 5 minutes",
                      "Practice at noon from 3pm to 4pm", "Practice from 3pm to 4pm by today at 3:30pm",
                      "Practice today from 6am to 8am"]
        for input in inputs {
            let result = draft(input, at: now)
            #expect(result.tasks.isEmpty && result.commitments.isEmpty && result.unrecognized.count == 1)
        }
        #expect(draft("Practice tomorrow from 23:00 to 02:30", at: time(27, 10, month: 3)).unrecognized.count == 1)
        #expect(draft("Practice tomorrow from 23:00 to 02:30", at: time(23, 10, month: 10)).unrecognized.count == 1)
    }

    @Test func sprintClocksNeverInventAnInstantDuringClockChanges() {
        #expect(draft("Call Sam tomorrow at 02:30", at: time(28, 16, month: 3)).unrecognized.count == 1)
        #expect(draft("Call Sam tomorrow at 02:30", at: time(24, 16, month: 10)).unrecognized.count == 1)
        let early = calendar.date(bySettingHour: 2, minute: 50, second: 0, of: time(25, 12, month: 10),
                                  matchingPolicy: .strict, repeatedTimePolicy: .first)!
        #expect(draft("Call Sam at 02:30", at: early).unrecognized.count == 1)
        #expect(draft("Call Sam at 02:30", at: time(25, 4, month: 10)).tasks.first?.plannedStart == time(26, 2, 30, month: 10))
    }
}
