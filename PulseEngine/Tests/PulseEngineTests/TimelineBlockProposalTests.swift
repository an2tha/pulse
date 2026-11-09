import Foundation
import Testing
@testable import PulseEngine

struct TimelineBlockProposalTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func span(_ a: Date, _ b: Date) -> DateInterval { DateInterval(start: a, end: b) }

    @Test func draggedRangeIsSingleDateAndCanEndAtMidnight() throws {
        let interval = span(date(9, 23, 15), date(10, 0))
        let proposal = try TimelineBlockProposal(kind: .protected, interval: interval, calendar: calendar)
        #expect(proposal.rule.singleDate(in: calendar) == date(9, 0))
        #expect(proposal.rule.hours.startMinute == 1395 && proposal.rule.hours.endMinute == 0)
        let nextWeek = try #require(calendar.dateInterval(of: .day, for: date(16, 0)))
        #expect(proposal.rule.intervals(on: nextWeek, calendar: calendar).isEmpty)
    }

    @Test func resizingOvernightTailKeepsWeeklyOpeningAndPreparation() throws {
        let hours = try #require(TaskAvailability(weekdays: [2, 5], startMinute: 22 * 60, endMinute: 120))
        let activity = UUID()
        let original = WeeklyTimeBlock(kind: .focus, title: "Night study", hours: hours, boostActivityID: activity)
        let slice = span(date(10, 0), date(10, 2))
        let edit = try TimelineBlockProposal(kind: .focus, interval: span(date(10, 0), date(10, 3)), original: original,
                                             displayedSlice: slice, calendar: calendar)
        #expect(edit.occurrence == span(date(9, 22), date(10, 3)))
        #expect(edit.rule.id == original.id && edit.rule.hours.weekdays == [2, 5])
        #expect(edit.rule.boostActivityID == activity && edit.rule.singleDay == nil)
        #expect(throws: TimelineBlockProposal.Issue.self) {
            try TimelineBlockProposal(kind: .focus, interval: span(date(10, 1), date(10, 2)), original: original,
                                      displayedSlice: slice, calendar: calendar)
        }
    }

    @Test func springForwardSelectionKeepsItsActualDuration() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 1, minute: 45)))
        let interval = DateInterval(start: start, duration: 1800)
        let proposal = try TimelineBlockProposal(kind: .focus, interval: interval, calendar: calendar)
        #expect(proposal.rule.hours.startMinute == 105)
        #expect(proposal.rule.hours.endMinute == 195)
        #expect(proposal.occurrence == interval)
    }

    @Test func resizeKeepsASingleDateBlockOnItsDate() throws {
        let initial = try TimelineBlockProposal(kind: .protected, interval: span(date(9, 8), date(9, 9)), calendar: calendar)
        let shorter = span(date(9, 8, 15), date(9, 9))
        let updated = try TimelineBlockProposal(kind: .protected, interval: shorter, original: initial.rule,
                                                displayedSlice: initial.occurrence, calendar: calendar)
        #expect(updated.rule.id == initial.rule.id)
        #expect(updated.rule.singleDay == initial.rule.singleDay)
        #expect(updated.occurrence == shorter)
    }

    @Test func repeatedHourRejectsUnrepresentableSelectionButAllowsWholeFold() throws {
        let fold = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0))!
        let early = fold.addingTimeInterval(2 * 3600)
        #expect(throws: TimelineBlockProposal.Issue.self) {
            try TimelineBlockProposal(kind: .focus, interval: span(early, early.addingTimeInterval(900)), calendar: calendar)
        }
        let whole = span(fold.addingTimeInterval(3600), fold.addingTimeInterval(5 * 3600))
        #expect(try TimelineBlockProposal(kind: .focus, interval: whole, calendar: calendar).occurrence == whole)
    }
}
