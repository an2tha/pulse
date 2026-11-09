import Foundation
import Testing
@testable import PulseEngine

struct WeekRemainderTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }
    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func emptyWeek(from start: Date? = nil) -> [OutlookDay] {
        (0..<7).map { offset in
            OutlookDay(date: calendar.date(byAdding: .day, value: offset, to: start ?? date(9))!, blocks: [])
        }
    }
    private func block(_ task: PlanTask, at start: Date, minutes: Int) -> Block {
        Block(kind: .task(task.id), title: task.title, start: start, end: start.addingTimeInterval(Double(minutes * 60)))
    }

    @Test func sumsTheActualSplitAndExcludesThoughtsAndProjectedOccurrences() {
        var large = PlanTask("Sketch", minutes: 61)
        large.recordFocus(seconds: 9 * 60 + 35, completed: false)
        let full = PlanTask("Read", minutes: 4)
        var done = PlanTask("Old", minutes: 5); done.done = true
        var archived = PlanTask("Archive", minutes: 5); archived.archived = true
        var thought = PlanTask("Later", minutes: 5); thought.inboxOnly = true
        let preview = PlanTask("Next occurrence", minutes: 30)
        var days = emptyWeek()
        days[0].blocks = [block(large, at: date(9,9), minutes: 15), block(full, at: date(9,10), minutes: 4)]
        days[1].blocks = [block(large, at: date(10,11), minutes: 11), block(preview, at: date(10,12), minutes: 15)]
        days[1].projectedTasks = [preview]
        let rows = WeekOutlook.remaining(in: days, tasks: [done, large, full, archived, thought, preview],
                                         at: date(9,9), dailyLimit: 60, calendar: calendar)
        #expect(rows == [WeekRemainder(id: large.id, plannedMinutes: 26, remainingMinutes: 26, reason: .noFurtherBlock)])
    }

    @Test func projectedPrerequisiteCompletionIsNotReportedAsABlock() {
        let ready = PlanTask("Get notes", minutes: 4)
        let partial = PlanTask("Gather readings", minutes: 12)
        var a = PlanTask("Write", minutes: 5); a.dependency = ready.id
        var b = PlanTask("Analyze", minutes: 5); b.dependency = partial.id
        var missing = PlanTask("Review", minutes: 5); missing.dependency = UUID()
        var archived = PlanTask("Closed", minutes: 5); archived.done = true; archived.archived = true
        var c = PlanTask("Continue", minutes: 5); c.dependency = archived.id
        var days = emptyWeek()
        days[2].blocks = [block(ready, at: date(11,10), minutes: 4), block(partial, at: date(11,11), minutes: 3)]
        let rows = WeekOutlook.remaining(in: days, tasks: [a, b, c, partial, ready, missing, archived],
                                         at: date(9,9), dailyLimit: 60, calendar: calendar)
        let result = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.reason) })
        #expect(result[a.id] == .noFurtherBlock && result[c.id] == .noFurtherBlock)
        #expect(result[b.id] == .prerequisite(partial.id) && result[missing.id] == .prerequisite(missing.dependency!))
    }

    @Test func theMovingCutoffOnlyExplainsWorkThatCannotFitBeforeIt() throws {
        var event = Commitment("Review", start: date(10,13), end: date(10,14))
        let shown = Block(kind: .fixed(event.id), title: event.title, start: event.start, end: event.end)
        var prep = PlanTask("Prepare", minutes: 15)
        prep.preparation = try #require(TaskPreparation(block: shown, commitment: event, after: date(9,9), calendar: calendar))
        prep.plannedStart = date(16,9)
        var far = PlanTask("Later", minutes: 5); far.after = date(16,8)
        let prefs = PlannerPreferences(bufferMinutes: 5)
        func rows(_ current: [Commitment]) -> [WeekRemainder.Reason] {
            WeekOutlook.remaining(in: emptyWeek(), tasks: [prep, far], at: date(9,9), commitments: current,
                                  dailyLimit: 20, preferences: prefs, calendar: calendar).map(\.reason)
        }
        #expect(rows([event]) == [.noFurtherBlock, .earliest(date(16,8))])
        event.start = date(9,9,15); event.end = date(9,10)
        #expect(rows([event]) == [.preparation(date(9,9,10)), .earliest(date(16,8))])
        #expect(rows([]) == [.noFurtherBlock, .earliest(date(16,8))])
    }

    @Test func availabilityChecksTheActualFixedIntervalsAndWholeOpenMinutes() {
        var film = PlanTask("Collect film", minutes: 10)
        film.availability = TaskAvailability(weekdays: [2], startMinute: 9*60, endMinute: 10*60)
        let fixed = Commitment("Call", start: date(9,9,5), end: date(9,10))
        let prefs = PlannerPreferences(bufferMinutes: 5)
        var days = emptyWeek()
        days[0].blocks = [Block(kind: .fixed(fixed.id), title: fixed.title, start: fixed.start, end: fixed.end)]
        func reason() -> WeekRemainder.Reason? {
            WeekOutlook.remaining(in: days, tasks: [film], at: date(9,9), dailyLimit: 60,
                                  preferences: prefs, calendar: calendar).first?.reason
        }
        #expect(reason() == .availability)
        days[0].blocks[0].start = date(9,9,6)
        #expect(reason() == .noFurtherBlock)
        days[0].blocks[0].start = date(9,9,6).addingTimeInterval(-1)
        #expect(reason() == .availability)
    }

    @Test func anAbsentClockHourIsNotAnAvailableWindow() throws {
        var task = PlanTask("Sunday hour", minutes: 5)
        task.availability = TaskAvailability(weekdays: [1], startMinute: 2*60, endMinute: 3*60)
        for (month, monday, missing) in [(3,23,true),(10,19,false)] {
            let start = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: monday)))
            let row = WeekOutlook.remaining(in: emptyWeek(from: start), tasks: [task], at: start,
                                            dailyLimit: 60, calendar: calendar).first
            #expect(row?.reason == (missing ? .availability : .noFurtherBlock))
        }
    }

    @Test func onlyACompleteProjectionAndSevenFullWorkBudgetsProveCapacity() {
        let task = PlanTask("Edit", minutes: 5)
        let other = PlanTask("Other", minutes: 80)
        var days = emptyWeek()
        for i in days.indices { days[i].blocks = [block(other, at: date(9+i,9), minutes: 10)] }
        func rows(_ limit: Int) -> [WeekRemainder] {
            WeekOutlook.remaining(in: days, tasks: [task], at: date(9,9), dailyLimit: limit, calendar: calendar)
        }
        #expect(rows(10).first?.reason == .atCapacity)
        days[4].blocks = [Block(kind: .rest, title: "Break", start: date(13,9), end: date(13,10))]
        #expect(rows(10).first?.reason == .noFurtherBlock && rows(0).first?.reason == .zeroLimit)
        days.removeLast()
        #expect(rows(10).isEmpty)
    }
}
