import Foundation
import Testing
@testable import PulseEngine

struct AvailabilityInputTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.locale = Locale(identifier: "en_GB")
        return cal
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 8))! }
    private func parsed(_ input: String) -> DayDraft { LocalDayInput.parse(input, at: now, calendar: calendar) }

    @Test func sharedParserDistinguishesAvailabilityFromAnEventAndARepetition() throws {
        for (input, title, weekdays, start, end) in [
            ("Call the repair shop only on weekdays from 9am to 5pm", "Call the repair shop", [2,3,4,5,6], 540, 1020),
            ("Review notes only on Tue and Thu between 10:15 and 11:00", "Review notes", [3,5], 615, 660),
            ("Back up photos only on Friday from 22:00 to 06:00", "Back up photos", [6], 1320, 360),
            ("Read only on weekends from noon to midnight", "Read", [1,7], 720, 0),
            ("Collect mail only on weekdays from 09:00 to 09:00", "Collect mail", [2,3,4,5,6], 540, 540),
            ("Call only on Fri through Mon between 09:00 and 10:00", "Call", [6,7,1,2], 540, 600),
        ] {
            let draft = parsed(input)
            #expect(draft.unrecognized.isEmpty && draft.commitments.isEmpty)
            let task = try #require(draft.tasks.first)
            #expect(draft.tasks.count == 1 && task.title == title && task.repeated == nil && task.after == nil)
            #expect(task.availability == TaskAvailability(weekdays: Set(weekdays), startMinute: start, endMinute: end))
        }
        let original = parsed("Studio meeting on Friday from 9am to 10am")
        #expect(original.commitments.count == 1 && original.tasks.isEmpty && original.unrecognized.isEmpty)
        let routine = try #require(parsed("Water herbs every day").tasks.first)
        #expect(routine.repeated == .daily && routine.availability == nil)
    }

    @Test func modifiersBeforeAndAfterTheWindowProduceTheSameDayAndDuration() throws {
        let window = "only on Tue and Thu between 10:15 and 11:00"
        for text in ["Review notes for 12 minutes by Friday " + window, "Review notes " + window + " for 12 minutes by Friday"] {
            let task = try #require(parsed(text).tasks.first)
            #expect(task.title == "Review notes" && task.minutes == 12 && task.availability?.weekdays == [3,5])
            let due = try #require(task.due)
            #expect(calendar.component(.weekday, from: due) == 6)
        }
        let later = try #require(parsed("Call the shop in 20 minutes only on weekdays from 9am to noon").tasks.first)
        #expect(later.after == now.addingTimeInterval(1200) && later.availability?.endMinute == 720)
        let recurring = try #require(parsed("Organize notes weekly only on Sat from 12 pm to 1 pm").tasks.first)
        #expect(recurring.repeated == .weekly && recurring.availability?.weekdays == [7])
    }

    @Test func commasWithinAWeekdayListAndQuotedTitlesSurviveMultiItemCapture() throws {
        let text = #"Read "Only on Monday from 9am to 5pm" only on Mon, Wed, and Fri from noon to 1pm, and call Pat for 5 minutes"#
        let draft = parsed(text)
        #expect(draft.unrecognized.isEmpty && draft.commitments.isEmpty && draft.tasks.count == 2)
        let task = try #require(draft.tasks.first)
        #expect(task.title == #"Read "Only on Monday from 9am to 5pm""# && task.availability?.weekdays == [2,4,6])
        #expect(draft.tasks.last?.title == "Call Pat" && draft.tasks.last?.availability == nil)
        let mixed = parsed("Write only on paper, call only on Tue, Wed from 9am to 10am")
        #expect(mixed.tasks.count == 2 && mixed.tasks.last?.availability?.weekdays == [3,4])
        #expect(parsed("Read a book\rCall the shop").tasks.count == 2)
        #expect(!LocalDayInput.hasAvailabilityCue(in: #"Read "Only on Monday from 9am to 5pm""#))
    }

    @Test func unsupportedOrAmbiguousInstructionsStayIntactInTheDump() {
        for text in ["Call only on Funday from 9am to 5pm", "Call only on Mon from 9 to 5", "Call only on Mon from 25:00 to 08:00",
                     "Call only on Mon between 09:00 to 17:00", "Call only on weekdays from 9am to 5pm except holidays",
                     "Call only on Wed from 9am to 5pm or Thursday from noon to 3pm",
                     "Call at 11am only on Monday from 09:00 to 12:00"] {
            let invalid = parsed(text)
            #expect(!invalid.unrecognized.isEmpty && invalid.tasks.isEmpty && invalid.commitments.isEmpty)
            let kept = TodoDump.tasks(from: text, at: now, calendar: calendar)
            #expect(kept.count == 1 && kept[0].title == text && kept[0].availability == nil)
        }
        let tasks = TodoDump.tasks(from: "Write only on paper\nCall only on Fridays from 10:00 to 11:00", at: now, calendar: calendar)
        #expect(tasks.count == 2 && tasks[0].title == "Write only on paper" && tasks[0].availability == nil)
        #expect(tasks[1].title == "Call" && tasks[1].availability?.weekdays == [6])
    }
}
