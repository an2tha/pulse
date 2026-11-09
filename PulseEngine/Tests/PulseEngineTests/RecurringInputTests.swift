import Foundation
import Testing

@testable import PulseEngine

@Suite struct RecurringInputTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func day(_ date: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: date, hour: hour))!
    }

    @Test func dateAnchorsWeeklyTasksAndEvents() throws {
        let parsed = LocalDayInput.parse(
            "Water fern for 10 min every Tuesday, Choir every Wednesday at 6pm for 1.5 hours, Read weekly",
            at: day(8), calendar: calendar)
        #expect(parsed.unrecognized.isEmpty)
        let fern = try #require(parsed.tasks.first)
        #expect(fern.title == "Water fern" && fern.minutes == 10 && fern.repeated == .weekly)
        #expect(fern.after == day(10, 0) && fern.routineAnchor == day(10, 0))
        let choir = try #require(parsed.commitments.first)
        #expect(choir.title == "Choir" && choir.recurrence == .weekly && choir.start == day(11, 18))
        #expect(choir.end.timeIntervalSince(choir.start) == 5400)
        let read = try #require(parsed.tasks.last)
        #expect(read.title == "Read" && read.repeated == .weekly && read.routineAnchor == day(8, 0))
    }

    @Test func weekendsAdvanceToFirstWeekday() throws {
        let result = LocalDayInput.parse("Walk weekdays, Studio every weekday at 9am", at: day(8), calendar: calendar)
        let task = try #require(result.tasks.first)
        #expect(task.after == day(9, 0))
        #expect(task.repeated == .weekdays)
        #expect(result.commitments.first?.start == day(9))
    }

    @Test func namedDatesAndISODeadlinesUseLocalCalendar() throws {
        let parsed = LocalDayInput.parse(
            "Read on Monday for 20 minutes by Friday at noon, Dentist on 2026-11-20 at 10am",
            at: day(8), calendar: calendar)
        let task = try #require(parsed.tasks.first)
        #expect(task.after == day(9, 0) && task.due == day(13, 12))
        #expect(task.title == "Read" && task.minutes == 20)
        #expect(parsed.commitments.first?.start == day(20, 10))
    }

    @Test func unsupportedInputStaysInReview() {
        for line in [
            "Walk every other Wednesday", "Class next week at 4pm", "Read for twenty minutes",
            "Write for 30-45 minutes", "Read for 20 minutes for 30 minutes", "Class from 9am",
            "Meet on 11/12/2026 at 9am", "Meet on 2026-02-30 at 9am",
            "Class from 9am to noon for 5 minutes", "Phone tomorrow evening",
            "Call in 30 to 45 minutes", "Class Friday afternoon", "Dentist on May 7 at 9am",
            "Dentist tomorrow 9am", "Read on Friday by Wednesday",
        ] {
            let parsed = LocalDayInput.parse(line, at: day(8), calendar: calendar)
            #expect(parsed.tasks.isEmpty && parsed.commitments.isEmpty, "\(line)")
            #expect(parsed.unrecognized == [line])
            #expect(parsed.clarification(for: line).contains(line))
        }
    }

    @Test func relativeAvailabilityAndDeadlinesHaveSeparateMeanings() throws {
        let result = LocalDayInput.parse(
            "Call Eli in 20 minutes for 5 min, Read after 2h by Friday, Return book within 2 hours, Submit due in 10m",
            at: day(8), calendar: calendar)
        #expect(result.unrecognized.isEmpty && result.commitments.isEmpty)
        try #require(result.tasks.count == 4)
        #expect(result.tasks[0].title == "Call Eli" && result.tasks[0].minutes == 5)
        #expect(result.tasks[0].after == day(8).addingTimeInterval(1200) && result.tasks[0].due == nil)
        #expect(result.tasks[1].after == day(8, 11) && result.tasks[1].due == day(14, 0).addingTimeInterval(-1))
        #expect(result.tasks[2].after == nil && result.tasks[2].due == day(8, 11))
        #expect(result.tasks[3].due == day(8).addingTimeInterval(600))
    }

    @Test func spokenAmountsWorkForDictatedCapture() {
        let spoken = LocalDayInput.parse("Call back in half an hour, Walk after two hours, Reply within an hour",
                                         at: day(8), calendar: calendar)
        #expect(spoken.tasks.map(\.after) == [day(8).addingTimeInterval(1800), day(8, 11), nil])
        #expect(spoken.tasks.last?.due == day(8, 10))
    }

    @Test func isoDatesKeepGregorianMeaningWithAnotherDisplayCalendar() {
        var displayCalendar = Calendar(identifier: .buddhist)
        displayCalendar.timeZone = calendar.timeZone
        let parse = LocalDayInput.parse("Send receipt due by 2026-11-20", at: day(8), calendar: displayCalendar)
        #expect(parse.tasks.first?.title == "Send receipt")
        #expect(parse.tasks.first?.due == day(21, 0).addingTimeInterval(-1))
    }

    @Test func nextFridayAndRelativeElapsedTimeAcrossClockChanges() throws {
        #expect(LocalDayInput.parse("Paint next Friday", at: day(13), calendar: calendar).tasks.first?.after == day(20, 0))
        let beforeGap = calendar.date(from: DateComponents(year: 2027, month: 3, day: 28, hour: 1, minute: 45))!
        let after = try #require(LocalDayInput.parse("Check bread in 20 min", at: beforeGap, calendar: calendar).tasks.first?.after)
        #expect(after.timeIntervalSince(beforeGap) == 1200)
        #expect(calendar.component(.hour, from: after) == 3 && calendar.component(.minute, from: after) == 5)
        let fall = calendar.date(from: DateComponents(year: 2027, month: 10, day: 31, hour: 1, minute: 45))!
        let end = try #require(LocalDayInput.parse("Call due in 2 hours", at: fall, calendar: calendar).tasks.first?.due)
        #expect(end.timeIntervalSince(fall) == 7200 && calendar.component(.hour, from: end) == 2)
    }

    @Test func quotedWordsAndAmbiguousTimesStayLiteral() throws {
        let result = LocalDayInput.parse("Read “Friday, Meet at noon” in 10m, \"due in 2 hours\"", at: day(8), calendar: calendar)
        #expect(result.tasks.map(\.title) == ["Read “Friday, Meet at noon”", "\"due in 2 hours\""])
        #expect(result.tasks.first?.after == day(8).addingTimeInterval(600))
        #expect(result.tasks.last?.due == nil && result.commitments.isEmpty)
        for input in ["Call in 20 minutes tomorrow", "Call in 1 hour or 2 hours", "Call in -20 minutes",
                      "Lunch in 2 hours at 9am", "Call due in 20 minutes by tomorrow", "Call after 1.5 hours",
                      "Call in 1,5 hours", "Due in 2 hours", "Call by in 20 minutes"] {
            let parsed = LocalDayInput.parse(input, at: day(8), calendar: calendar)
            #expect(parsed.unrecognized == [input] && parsed.tasks.isEmpty && parsed.commitments.isEmpty)
        }
    }

    @Test func lunchUsesOneActualCommitmentAndStaysATask() throws {
        let lunch = Commitment("Lunch break", start: day(8, 13), end: day(8, 14), recurrence: .daily)
        let input = "Pick recipe at lunch"
        let tasks = TodoDump.tasks(from: input + " next Friday", at: day(8), calendar: calendar, commitments: [lunch])
        #expect(tasks.first?.title == "Pick recipe" && tasks.first?.after == day(13, 13))
        for events in [[], [lunch, lunch]] {
            let skipped = LocalDayInput.parse(input, at: day(8), calendar: calendar, commitments: events)
            #expect(skipped.unrecognized == [input] && skipped.commitments.isEmpty)
        }
        let past = LocalDayInput.parse(input, at: day(8, 16), calendar: calendar, commitments: [lunch])
        #expect(past.unrecognized == [input])
    }

    @Test func repeatedWallClockHourRequiresClarification() {
        let raw = "Meet on 2027-10-31 at 02:15"
        let result = LocalDayInput.parse(raw, at: day(8), calendar: calendar)
        #expect(result.unrecognized == [raw] && result.commitments.isEmpty)
    }

    @Test func daylightSavingGapRequiresANewTime() {
        let parsed = LocalDayInput.parse("Meet on 2027-03-28 at 02:30", at: day(8), calendar: calendar)
        #expect(parsed.commitments.isEmpty && !parsed.unrecognized.isEmpty)
    }
}
