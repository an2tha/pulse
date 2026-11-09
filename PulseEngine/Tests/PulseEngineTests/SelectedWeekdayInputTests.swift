import Foundation
import Testing
@testable import PulseEngine

struct SelectedWeekdayInputTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private func time(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: .init(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func parse(_ input: String, at date: Date) -> DayDraft {
        LocalDayInput.parse(input, at: date, calendar: calendar)
    }

    @Test func weekendCaptureCreatesAWeekendRoutineAtTheNamedTime() throws {
        for phrase in ["every weekend", "on weekends"] {
            let input = "Walk the dog " + phrase + " at 8am"
            let draft = parse(input, at: time(9, 12))
            let task = try #require(draft.tasks.first)
            #expect(draft.unrecognized.isEmpty && task.title == "Walk the dog")
            #expect(task.repeatDays == [1, 7] && task.plannedStart == time(14, 8))
            #expect(LocalDayInput.hasSelectedWeekdayCadence(in: input))
        }
        let quoted = try #require(parse(#"Read "On weekends" for 5 minutes"#, at: time(9, 12)).tasks.first)
        #expect(quoted.repeatDays == nil)
        #expect(!LocalDayInput.hasSelectedWeekdayCadence(in: #"Read "On weekends" for 5 minutes"#))
    }

    @Test func onlyTheNamedWeekdaysRepeatAndEachOccurrenceKeepsItsClock() throws {
        let text = "Water plants every Tue and Thu at 8am"
        for (now, expected) in [(time(9, 16), time(10, 8)), (time(10, 7), time(10, 8)), (time(10, 16), time(12, 8))] {
            let draft = parse(text, at: now)
            #expect(draft.tasks.count == 1 && draft.unrecognized.isEmpty && draft.commitments.isEmpty)
            var task = try #require(draft.tasks.first)
            #expect(task.title == "Water plants" && task.repeated == .daily && task.repeatDays == [3,5])
            #expect(task.plannedStart == expected && task.routineAnchor == expected)
            task.done = true
            task.completedAt = expected.addingTimeInterval(600)
            var tasks = [task]
            TaskRoutines.advance(&tasks, at: expected.addingTimeInterval(600), calendar: calendar)
            let following = try #require(tasks.last?.plannedStart)
            #expect(tasks.count == 2 && tasks.last?.repeatDays == [3,5] && following > expected)
            #expect([3,5].contains(calendar.component(.weekday, from: following)) && calendar.component(.hour, from: following) == 8)
        }
    }

    @Test func complexTaskListsKeepTheirCommasAndDoNotConsumeTheFollowingTask() throws {
        let draft = parse("Practice guitar every Monday, Wednesday and Friday for 10 minutes, and read a book for 20 minutes", at: time(10, 11))
        #expect(draft.unrecognized.isEmpty && draft.commitments.isEmpty && draft.tasks.count == 2)
        let first = try #require(draft.tasks.first)
        #expect(first.title == "Practice guitar" && first.minutes == 10 && first.repeatDays == [2,4,6])
        #expect(first.after == time(11) && first.plannedStart == nil)
        #expect(draft.tasks.last?.title == "Read a book" && draft.tasks.last?.repeatDays == nil)
        let shorthand = try #require(parse("Practice guitar every Mon and Fri 10 minutes", at: time(10, 11)).tasks.first)
        #expect(shorthand.minutes == 10 && shorthand.repeatDays == [2,6])
        let dump = TodoDump.tasks(from: "Buy rice and beans\nRotate seedlings every Mon, Wed, and Fri at 17:15", at: time(10), calendar: calendar)
        #expect(dump.count == 2 && dump[0].title == "Buy rice and beans" && dump[0].repeated == nil)
        #expect(dump[1].title == "Rotate seedlings" && dump[1].plannedStart == time(11,17,15))
    }

    @Test func fixedEventsAndQuotedTitlesRetainTheirOriginalMeaning() throws {
        let event = try #require(parse("Choir every Wednesday at 6pm", at: time(9,9)).commitments.first)
        #expect(event.recurrence == .weekly && event.start == time(11,18))
        let oneOff = parse("Choir on Wednesday from 6pm to 7pm", at: time(9,9))
        #expect(oneOff.tasks.isEmpty && oneOff.commitments.count == 1 && oneOff.commitments.first?.recurrence == .once)
        let quoted = try #require(parse(#"Read "Every Monday, Wednesday and Friday" for 5 minutes"#, at: time(9,9)).tasks.first)
        #expect(quoted.title == #"Read "Every Monday, Wednesday and Friday""# && quoted.repeatDays == nil)
        for invalid in ["Choir every Tue and Thu from 9am to 10am", "Read every Monday and Wednesdax for 5 minutes",
                        "Read every Tue and Thu every Friday", "Read every Tue and Tue", "Read every Monday, Wednesday and Frdiay"] {
            let result = parse(invalid, at: time(9,9))
            #expect(result.tasks.isEmpty && result.commitments.isEmpty && !result.unrecognized.isEmpty)
            #expect(TodoDump.tasks(from: invalid, at: time(9,9), calendar: calendar).first?.title == invalid)
        }
    }

    @Test func wallClockAndDeadlineReferToTheFirstSelectedCivilDay() throws {
        // On Sunday's missing 02:30, a routine first needed Tuesday can still have that clock.
        let sunday = time(29, 1, month: 3)
        let valid = try #require(parse("Write notes every Tue and Thu at 02:30", at: sunday).tasks.first)
        #expect(valid.plannedStart == time(31, 2, 30, month: 3))
        #expect(parse("Write notes every Sun and Tue at 02:30", at: sunday).unrecognized.count == 1)
        #expect(parse("Send file every Tue and Thu by today", at: time(9, 9)).unrecognized.count == 1)
        let combo = try #require(parse("Sort mail every Tue and Thu only on weekdays from 9am to noon", at: time(9,9)).tasks.first)
        #expect(combo.repeatDays == [3,5] && combo.availability?.weekdays == [2,3,4,5,6])
    }
}
