import Foundation
import Testing
@testable import PulseEngine

struct TaskPreparationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func link(_ event: Commitment, on day: Date, after now: Date) throws -> TaskPreparation {
        let intervals = event.intervals(on: day, calendar: calendar)
        let shown = try #require(intervals.first { $0.start <= day && day < $0.end } ?? intervals.first)
        let block = Block(kind: .fixed(event.id), title: event.title, start: shown.start, end: shown.end)
        return try #require(TaskPreparation(block: block, commitment: event, after: now, calendar: calendar))
    }

    @Test func oneOccurrenceTracksEditsAndKeepsItsLatestKnownTimeWhenMissing() throws {
        let now = date(9, 9)
        var event = Commitment("Review", start: date(10, 13), end: date(10, 14))
        let initial = try link(event, on: event.start, after: now)
        event.start = date(11, 15)
        event.end = date(11, 16)
        let updated = initial.refreshed(in: [event], calendar: calendar)
        #expect(initial.sameOccurrence(as: updated))
        #expect(initial.lastKnownStart == date(10, 13) && updated.lastKnownStart == date(11, 15))
        #expect(updated.resolvedStart(in: [], calendar: calendar) == nil)
        #expect(updated.refreshed(in: [], calendar: calendar) == updated)
        #expect(try JSONDecoder().decode(TaskPreparation.self, from: JSONEncoder().encode(updated)) == updated)
        event.recurrence = .daily
        #expect(updated.resolvedStart(in: [event], calendar: calendar) == nil)
    }

    @Test func movedWeekdaySeriesKeepsTheSameOrdinalAcrossAWeekend() throws {
        var event = Commitment("Visit", start: date(9, 10), end: date(9, 11), recurrence: .weekdays)
        let fourth = try link(event, on: date(12, 9), after: date(8, 12))
        let fifth = try link(event, on: date(13, 9), after: date(8, 12))
        #expect(fourth.occurrenceIndex == 3 && !fourth.sameOccurrence(as: fifth))
        event.start = date(12, 16)
        event.end = date(12, 17)
        #expect(fourth.resolvedStart(in: [event], calendar: calendar) == date(17, 16))
        #expect(fifth.resolvedStart(in: [event], calendar: calendar) == date(18, 16))
    }

    @Test func weeklyClockKeepsItsLocalTimeAcrossDaylightSavingAndRejectsInvalidStoredOrdinals() throws {
        func october(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        var event = Commitment("Training", start: october(20, 9), end: october(20, 10), recurrence: .weekly)
        let next = try link(event, on: october(27, 9), after: october(19, 9))
        #expect(next.occurrenceIndex == 1 && next.lastKnownStart == october(27, 9))
        event.start = october(21, 16)
        event.end = october(21, 17)
        #expect(next.resolvedStart(in: [event], calendar: calendar) == october(28, 16))
        let encoded = try JSONEncoder().encode(next)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["occurrenceIndex"] = -1
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TaskPreparation.self, from: corrupt) }
    }

    @Test func overnightTailUsesItsRealOpeningAndRejectsPastOrAmbiguousCoverage() throws {
        let night = Commitment("Night shift", start: date(9, 22), end: date(10, 6), recurrence: .weekdays)
        let opening = try link(night, on: date(13, 22), after: date(12, 12))
        let tail = try link(night, on: date(14, 0), after: date(12, 12))
        #expect(tail.sameOccurrence(as: opening) && tail.lastKnownStart == date(13, 22))
        let clipped = Block(kind: .fixed(night.id), title: night.title, start: date(14, 0), end: date(14, 6))
        #expect(TaskPreparation(block: clipped, commitment: night, after: date(13, 23), calendar: calendar) == nil)
        var wrong = night
        wrong.id = UUID()
        #expect(TaskPreparation(block: clipped, commitment: wrong, after: date(12, 12), calendar: calendar) == nil)
        let guessed = Block(kind: .fixed(night.id), title: night.title, start: date(14, 1), end: date(14, 6))
        #expect(TaskPreparation(block: guessed, commitment: night, after: date(12, 12), calendar: calendar) == nil)
        let flexible = Block(kind: .task(night.id), title: night.title, start: clipped.start, end: clipped.end)
        #expect(TaskPreparation(block: flexible, commitment: night, after: date(12, 12), calendar: calendar) == nil)
        let long = Commitment("Overlap", start: date(2, 10), end: date(12, 12), recurrence: .weekly)
        let ambiguous = Block(kind: .fixed(long.id), title: long.title, start: date(11, 0), end: date(12, 0))
        #expect(TaskPreparation(block: ambiguous, commitment: long, after: date(1, 8), calendar: calendar) == nil)
    }

    @Test func upcomingPickerListsOvernightEventsOnlyOnTheirStartingDay() {
        let night = Commitment("Night shift", start: date(9, 22), end: date(10, 6), recurrence: .weekdays)
        let single = Commitment("Overnight train", start: date(13, 19), end: date(14, 9))
        for event in [night, single] {
            let friday = event.preparationOccurrences(on: date(13, 10), after: date(12, 8), calendar: calendar)
            #expect(friday.count == 1)
            #expect(event.preparationOccurrences(on: date(14, 10), after: date(12, 8), calendar: calendar).isEmpty)
        }
    }

    @Test func shortenedAppointmentReleasesStalePinAndKeepsAuthoredSoftDeadline() throws {
        let now = date(9, 9)
        var event = Commitment("Studio", start: date(9, 12), end: date(9, 13))
        var prep = PlanTask("Print proofs", minutes: 40)
        prep.preparation = try link(event, on: now, after: now)
        prep.due = date(9, 8)
        prep.plannedStart = date(9, 11)
        event.start = date(9, 9, 17)
        event.end = date(9, 10)
        let planning = prep.planningCopy(with: [event], bufferMinutes: 5, calendar: calendar)
        #expect(planning.plannedStart == nil && planning.due == prep.due)
        #expect(prep.plannedStart == date(9, 11) && prep.preparation?.lastKnownStart == date(9, 12))
        let prefs = PlannerPreferences(bufferMinutes: 5)
        let blocks = Planner.schedule(at: now, tasks: [prep], commitments: [event], reports: [], dailyLimit: 60,
                                      breaks: false, preferences: prefs, calendar: calendar)
        let block = try #require(blocks.first { $0.kind == .task(prep.id) })
        #expect(block.start == now && block.end == date(9, 9, 12))
        let options = Planner.weekPlacements(for: prep.id, at: now, tasks: [prep], commitments: [event], reports: [],
                                             dailyLimit: 60, breaks: false, preferences: prefs, calendar: calendar)
        #expect(!options.isEmpty)
        #expect(options.allSatisfy { $0.start.addingTimeInterval(Double($0.minutes * 60)) <= block.end && $0.projectedFinish == nil })
        let today = Planner.placements(for: prep.id, at: now, tasks: [prep], commitments: [event], reports: [],
                                       dailyLimit: 60, breaks: false, preferences: prefs, calendar: calendar)
        #expect(!today.isEmpty && today.allSatisfy { $0.start.addingTimeInterval(Double($0.minutes * 60)) <= block.end })
        #expect(Planner.spareMoments(at: now, minutes: 40, tasks: [prep], commitments: [event], reports: [],
                                     dailyLimit: 60, preferences: prefs, calendar: calendar).isEmpty)
        var known = prep
        known.preparation = planning.preparation
        let missing = Planner.schedule(at: date(9, 9, 13), tasks: [known], commitments: [], reports: [], dailyLimit: 60,
                                       preferences: prefs, calendar: calendar)
        #expect(!missing.contains { $0.kind == .task(prep.id) })
        known.minutes = 12
        #expect(Planner.spareMoments(at: now, minutes: 12, tasks: [known], commitments: [], reports: [],
                                     dailyLimit: 60, preferences: prefs, calendar: calendar).first?.minutes == 12)
    }

    @Test func availablePrepMovesRetainOtherPinsAndHonorExplicitRestHours() throws {
        let now = date(9, 9)
        let visit = Commitment("Visit", start: date(9, 12), end: date(9, 13))
        var prep = PlanTask("Take samples", minutes: 8)
        prep.preparation = try link(visit, on: now, after: now)
        var fixed = PlanTask("Place order", minutes: 12)
        fixed.plannedStart = date(9, 10)
        var options = PlannerPreferences()
        options.expectations = [try #require(EnergyExpectation(at: now, scope: .hour, score: 0, calendar: calendar))]
        let choices = Planner.weekPlacements(for: prep.id, at: now, tasks: [prep, fixed], commitments: [visit],
                                             reports: [], dailyLimit: 25, breaks: false, preferences: options, calendar: calendar)
        #expect(!choices.isEmpty)
        for choice in choices {
            #expect(choice.start >= date(9, 10, 12) && choice.start.addingTimeInterval(480) <= visit.start)
            var pinned = prep
            pinned.moveOccurrence(to: choice.start, originalDay: now, calendar: calendar)
            let plan = Planner.schedule(at: now, tasks: [pinned, fixed], commitments: [visit], reports: [],
                                        dailyLimit: 25, breaks: false, preferences: options, calendar: calendar)
            #expect(plan.contains { $0.kind == .task(fixed.id) && $0.start == fixed.plannedStart && $0.minutes == 12 })
        }
    }

    @Test func splitAcrossDaysAndPrerequisitesAndWindowsStayProtected() throws {
        let now = date(9, 9)
        let event = Commitment("Walkthrough", start: date(10, 9, 20), end: date(10, 10))
        let before = PlanTask("Unlock desk", minutes: 5)
        var prep = PlanTask("Mark drawings", minutes: 25)
        prep.preparation = try link(event, on: event.start, after: now)
        prep.dependency = before.id
        prep.availability = TaskAvailability(weekdays: [2, 3], startMinute: 9 * 60 + 5, endMinute: 11 * 60)
        let prefs = PlannerPreferences(bufferMinutes: 5)
        let tasks = [before, prep]
        let today = Planner.schedule(at: now, tasks: tasks, commitments: [event], reports: [], dailyLimit: 30,
                                     breaks: false, preferences: prefs, calendar: calendar)
        let week = WeekOutlook.project(at: now, today: today, tasks: tasks, events: [event], reports: [], limit: 30,
                                       breaks: false, preferences: prefs, calendar: calendar)
        let pieces = week.flatMap(\.blocks).filter { $0.kind == .task(prep.id) }
        #expect(pieces.map(\.minutes) == [15, 10])
        #expect(pieces.first?.start == date(9, 9, 5) && pieces.last?.end == date(10, 9, 15))
        var repeating = prep
        repeating.done = true
        repeating.repeated = .weekdays
        var completed = [repeating]
        TaskRoutines.advance(&completed, at: now, calendar: calendar)
        #expect(completed.count == 1 && prep.duplicate().preparation == nil)
    }
}
