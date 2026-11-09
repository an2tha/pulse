import Foundation
import Testing
@testable import PulseEngine

@Suite struct WeekPlacementTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func comparesForecastsAcrossDaysAndRetainsDayWinners() throws {
        let now = time(10, 20)
        let history = (1...26).map { day -> CheckIn in
            let date = cal.date(byAdding: .day, value: -day, to: time(10, 14))!
            let energy = cal.component(.weekday, from: date) == 5 ? 8.0 : 6.0
            return CheckIn(date: date, energy: energy, clarity: 6, interest: 6)
        }
        var task = PlanTask("Draft", minutes: 8)
        task.energyOverride = 8
        let model = EnergyTimeline(signals: [], checkIns: history, corrections: [], now: now, calendar: cal)
        let meeting = Commitment("Lab", start: time(12, 9), end: time(12, 13, 30))
        let options = Planner.weekPlacements(for: task.id, at: now, tasks: [task], commitments: [meeting],
                                             reports: history, dailyLimit: 20, preferences: .init(bufferMinutes: 5),
                                             calendar: cal, forecast: model)
        let best = try #require(options.first { $0.recommended })
        #expect(best.start == time(12, 13, 35))
        #expect(best.forecastScore == 8 && !best.forecastIsDaily)
        #expect(options.filter(\.recommended).count == 1)
        #expect(options.filter(\.recommendedForDay).count == 7)
        #expect(options.last!.start < time(17, 0))
        #expect(options.contains { $0.forecastIsDaily })
    }

    @Test func honorRestTodayAndNormalStartFollowingOlderPins() {
        var task = PlanTask("Read map", minutes: 8)
        task.plannedStart = time(10, 12)
        let options = Planner.weekPlacements(for: task.id, at: time(10, 8), tasks: [task],
                                             commitments: [], reports: [], dailyLimit: 15, usedMinutes: 15,
                                             calendar: cal, startHour: 10, todayLimit: 0, sourceDay: time(11, 12))
        #expect(options.first?.start == time(11, 10))
        #expect(options.allSatisfy { cal.component(.hour, from: $0.start) >= 10 })
    }

    @Test func earlierDayMoveHonorsAfterAndLaterPinnedDependents() {
        var prep = PlanTask("Prepare", minutes: 8)
        prep.after = time(11, 10)
        var delivery = PlanTask("Deliver", minutes: 8)
        delivery.dependency = prep.id
        delivery.plannedStart = time(12, 9)
        let slots = Planner.weekPlacements(for: prep.id, at: time(10, 9), tasks: [prep, delivery],
                                           commitments: [], reports: [], dailyLimit: 20, calendar: cal,
                                           sourceDay: time(11, 12))
        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { $0.start >= time(11, 10) && $0.start < time(12, 9) })
    }

    @Test func crossDayMoveKeepsUnpinnedWeeklyRecurrenceAnchor() throws {
        var task = PlanTask("Review", minutes: 6)
        task.repeated = .weekly
        let now = time(10, 8)
        let slots = Planner.weekPlacements(for: task.id, at: now, tasks: [task], commitments: [],
                                           reports: [], dailyLimit: 20, calendar: cal)
        let friday = try #require(slots.first { cal.isDate($0.start, inSameDayAs: time(13, 10)) })
        task.moveOccurrence(to: friday.start, originalDay: now, calendar: cal)
        task.done = true
        var tasks = [task]
        TaskRoutines.advance(&tasks, at: friday.start, calendar: cal)
        let next = try #require(tasks.last)
        #expect(next.plannedStart == nil)
        #expect(next.after == time(17, 0))
    }

    @Test func inboxCanRequestAnOpeningEvenWhenItsTaskFallsOutsideTheWeek() throws {
        let now = time(10, 9)
        let others = (0..<8).map { PlanTask("Prepare \($0)", minutes: 10) }
        let inbox = PlanTask("Email the sketch", minutes: 6)
        let all = others + [inbox]
        let preferences = PlannerPreferences(order: all.map(\.id))
        let week = Planner.weekPlacements(for: inbox.id, at: now, tasks: all, commitments: [], reports: [],
                                          dailyLimit: 10, preferences: preferences, calendar: cal)
        let best = try #require(week.first { $0.recommended })
        #expect(best.originalStart == nil && best.minutes == 6)
        var moved = all
        moved[moved.count - 1].moveOccurrence(to: best.start)
        let after = Planner.schedule(at: now, tasks: moved, commitments: [], reports: [],
                                     dailyLimit: 10, preferences: preferences, calendar: cal)
        #expect(after.contains { $0.kind == .task(inbox.id) && $0.start == best.start })
        let staleDrag = Planner.weekPlacements(for: inbox.id, at: now, tasks: all, commitments: [], reports: [],
                                               dailyLimit: 10, preferences: preferences, calendar: cal, sourceDay: now)
        #expect(staleDrag.isEmpty)
    }

    @Test func preparedBaselinesMatchDirectEstimatesAtHistoricalAndFutureTimes() {
        let history: [CheckIn] = (0..<180).map { i in
            let date = time(8, 0).addingTimeInterval(Double(i - 100) * 1920)
            return CheckIn(date: date, energy: Double((i * 7) % 11), clarity: 6, interest: 3)
        }
        let plain = PlannerPreferences()
        let cached = plain.preparingHistory(history.reversed(), calendar: cal)
        for offset in stride(from: 0, through: 4 * 24 * 60, by: 37) {
            let date = time(7, 0).addingTimeInterval(Double(offset) * 60)
            #expect(cached.capacity(at: date, reports: history.reversed(), calendar: cal)
                    == plain.capacity(at: date, reports: history.reversed(), calendar: cal))
        }
    }

    @Test func preparedVotesRespectHistoryAndLaterChanges() {
        let first = SuggestionVote(.fits, category: .study, date: time(10, 8))
        let later = SuggestionVote(.tooMuch, category: .study, date: time(11, 11))
        let ordinary = PlannerPreferences(votes: [first, later])
        var prepared = ordinary.preparingVotes()
        for date in [time(9, 10), time(10, 10), time(12, 10)] {
            #expect(prepared.preference(for: .study, at: date) == ordinary.preference(for: .study, at: date))
        }
        prepared.votes.removeAll()
        #expect(prepared.preference(for: .study, at: time(12, 10)) == 0)
    }
}

@Test func aPinBeforeThePlanningDayDoesNotReleaseOtherInboxThoughts() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9)))
    let early = monday.addingTimeInterval(23 * 3600)
    var held = PlanTask("Buy stamps", minutes: 4)
    held.inboxOnly = true
    var other = PlanTask("Read agenda", minutes: 5)
    other.plannedStart = early
    let days = WeekOutlook.project(at: monday, today: [], tasks: [held, other], events: [], reports: [],
                                   limit: 60, breaks: false, preferences: .init(), startHour: 9, calendar: calendar)
    let blocks = days.flatMap(\.blocks)
    #expect(blocks.contains { $0.kind == .task(other.id) && $0.start == early })
    #expect(!blocks.contains { $0.kind == .task(held.id) })
    let choices = Planner.weekPlacements(for: held.id, at: monday, tasks: [held, other], commitments: [],
                                         reports: [], dailyLimit: 60, breaks: false, calendar: calendar)
    #expect(choices.contains { $0.recommended })
}
