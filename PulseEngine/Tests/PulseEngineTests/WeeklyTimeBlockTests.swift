import Foundation
import Testing
@testable import PulseEngine

struct WeeklyTimeBlockTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func time(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func rule(_ kind: WeeklyTimeBlock.Kind, days: Set<Int> = [2], start: Int, end: Int, boost: UUID? = nil) -> WeeklyTimeBlock {
        WeeklyTimeBlock(kind: kind, hours: TaskAvailability(weekdays: days, startMinute: start, endMinute: end)!, boostActivityID: boost)
    }

    @Test func firstDateStartsOvernightPatternWithoutPreviousDaysTailAndPersists() throws {
        var zone = rule(.protected, days: Set(1...7), start: 22 * 60, end: 2 * 60)
        zone.setFirstDate(time(16, 12), calendar: calendar)
        let restored = try JSONDecoder().decode(WeeklyTimeBlock.self, from: JSONEncoder().encode(zone))
        let day = try #require(calendar.dateInterval(of: .day, for: time(16, 0)))
        #expect(restored.blocks(on: day, calendar: calendar).map(\.start) == [time(16, 22)])
        let prior = try #require(calendar.dateInterval(of: .day, for: time(15, 0)))
        #expect(restored.blocks(on: prior, calendar: calendar).isEmpty)
        let next = try #require(calendar.dateInterval(of: .day, for: time(17, 0)))
        #expect(restored.blocks(on: next, calendar: calendar).map(\.start) == [time(17, 0), time(17, 22)])
        #expect(restored.nextOpening(after: time(1, 0), calendar: calendar) == time(16, 22))
    }

    @Test func lastDateIncludesFinalOvernightTailWithoutOpeningAnotherNight() throws {
        var zone = rule(.protected, days: Set(1...7), start: 22 * 60, end: 2 * 60)
        zone.setFirstDate(time(16, 12), calendar: calendar)
        zone.setLastDate(time(18, 12), calendar: calendar)
        let restored = try JSONDecoder().decode(WeeklyTimeBlock.self, from: JSONEncoder().encode(zone))
        #expect(restored.hasValidDates)
        var preferences = PlannerPreferences()
        preferences.timeBlocks = [restored]
        let tail = Planner.workExclusions(at: time(19, 0), commitments: [], reports: [], preferences: preferences, calendar: calendar)
        #expect(tail == [DateInterval(start: time(19, 0), end: time(19, 2))])
        #expect(Planner.workExclusions(at: time(20, 0), commitments: [], reports: [], preferences: preferences, calendar: calendar).isEmpty)
        #expect(restored.nextOpening(after: time(18, 21), calendar: calendar) == time(18, 22))
        #expect(restored.nextOpening(after: time(18, 23), calendar: calendar) == nil)
        var invalid = restored
        invalid.setLastDate(time(15, 0), calendar: calendar)
        #expect(!invalid.hasValidDates)
    }

    @Test func aroundTheClockZoneKeepsItsAuthoredOpeningTime() {
        var zone = rule(.focus, days: Set(1...7), start: 6 * 60, end: 6 * 60)
        zone.setFirstDate(time(16, 12), calendar: calendar)
        #expect(zone.nextOpening(after: time(1, 12), calendar: calendar) == time(16, 6))
        #expect(zone.nextOpening(after: time(16, 12), calendar: calendar) == time(17, 6))
    }

    @Test func focusGetsReservedForFocusedWorkWithoutMovingAnAuthoredPin() throws {
        let monday = time(9, 9)
        let focus = rule(.focus, start: 11 * 60, end: 12 * 60)
        var preferences = PlannerPreferences()
        preferences.timeBlocks = [focus]
        let study = PlanTask("Study", minutes: 20, category: .study)
        var admin = PlanTask("Post the letter", minutes: 15, category: .personal)
        admin.plannedStart = time(9, 9, 30)
        let task = PlanTask("Personal", minutes: 10, category: .personal)
        let plan = Planner.schedule(at: monday, tasks: [study, admin, task], commitments: [], reports: [], dailyLimit: 60, breaks: false, preferences: preferences, calendar: calendar)
        #expect(plan.first(where: { $0.kind == .task(study.id) })?.start == time(9, 11))
        #expect(plan.first(where: { $0.kind == .task(admin.id) })?.start == admin.plannedStart)
        #expect(plan.first(where: { $0.kind == .task(task.id) })?.start == monday)
        let restricted = Planner.schedule(at: time(9, 11), tasks: [admin, task], commitments: [], reports: [], dailyLimit: 30, preferences: preferences, calendar: calendar)
        #expect(restricted.filter { if case .task = $0.kind { true } else { false } }.allSatisfy { $0.start >= time(9, 12) })
    }

    @Test func protectionCoversOvernightWeekdayAndBothDSTHoursEvenWithPinnedTasks() throws {
        let rule = rule(.protected, days: [7], start: 22 * 60, end: 3 * 60)
        var preferences = PlannerPreferences()
        preferences.timeBlocks = [rule]
        let fall = time(25, 0, month: 10)
        let busy = Planner.workExclusions(at: fall, commitments: [], reports: [], preferences: preferences, calendar: calendar)
        #expect(busy.first?.duration == 14_400.0)
        let spring = time(29, 0, month: 3)
        #expect(Planner.workExclusions(at: spring, commitments: [], reports: [], preferences: preferences, calendar: calendar).first?.duration == 7_200.0)
        var pinned = PlanTask("Pinned", minutes: 5)
        pinned.plannedStart = fall
        let plan = Planner.schedule(at: fall, tasks: [pinned], commitments: [], reports: [], dailyLimit: 20, breaks: false, preferences: preferences, calendar: calendar)
        #expect(plan.first(where: { $0.kind == .task(pinned.id) })?.start == time(25, 3, month: 10))
        #expect(Planner.spareMoments(at: fall, minutes: 5, tasks: [pinned], commitments: [], reports: [], dailyLimit: 20, preferences: preferences, calendar: calendar).isEmpty)
    }

    @Test func boostReservesOnlyAUsableSlotAndRespectsAdjacentAppointments() throws {
        let activity = EnergyActivity.presetBoosts[0]
        let focus = rule(.focus, start: 660, end: 690, boost: activity.id)
        var prefs = PlannerPreferences()
        prefs.timeBlocks = [focus]
        let boost = try #require(prefs.weeklyBlocks(on: time(9, 9), commitments: [], reports: [], calendar: calendar).first { $0.kind == .timeBlock(focus.id, .boost) })
        #expect(boost.start == time(9, 10, 55) && boost.end == time(9, 11) && boost.title == activity.title)
        let meeting = Commitment("Meeting", start: time(9, 10, 45), end: time(9, 10, 56))
        #expect(!prefs.weeklyBlocks(on: time(9, 9), commitments: [meeting], reports: [], calendar: calendar).contains { $0.kind == .timeBlock(focus.id, .boost) })
        prefs.timeBlocks.append(rule(.protected, start: 659, end: 670))
        #expect(!prefs.weeklyBlocks(on: time(9, 9), commitments: [], reports: [], calendar: calendar).contains { $0.kind == .timeBlock(focus.id, .boost) })
    }

    @Test func weekIncludesEarlyFocusBeforeTheUsualStartWithoutMovingOtherWorkEarlier() throws {
        var prefs = PlannerPreferences()
        let focus = rule(.focus, days: [3], start: 6 * 60, end: 6 * 60 + 30)
        prefs.timeBlocks = [focus, rule(.protected, days: [3], start: 4 * 60, end: 5 * 60)]
        let study = PlanTask("Practice", minutes: 10)
        let errand = PlanTask("Note", minutes: 5, category: .personal)
        let tuesday = time(10, 0)
        let plan = WeekOutlook.futureBlocks(on: tuesday, tasks: [errand, study], events: [], reports: [], limit: 60,
                                            breaks: false, preferences: prefs, startHour: 9, calendar: calendar)
        #expect(plan.first { $0.kind == .task(study.id) }?.start == time(10, 6))
        #expect(plan.first { $0.kind == .task(errand.id) }?.start == time(10, 9))
        #expect(plan.contains { $0.kind == .timeBlock(focus.id, .focus) })
        let options = Planner.weekPlacements(for: errand.id, at: time(9, 9), tasks: [errand], commitments: [], reports: [], dailyLimit: 60,
                                             preferences: prefs, calendar: calendar)
        #expect(!options.contains { time(10, 6) <= $0.start && $0.start < time(10, 6, 30) })
    }

    @Test func authoredPinsWinOverAnOptionalBoostAndPulsePicksAnInHourFocusOpening() throws {
        let activity = EnergyActivity.presetBoosts[0]
        let focus = rule(.focus, start: 10 * 60 + 30, end: 11 * 60, boost: activity.id)
        var prefs = PlannerPreferences()
        prefs.timeBlocks = [focus]
        var errand = PlanTask("Collect the parcel", minutes: 5, category: .personal)
        errand.plannedStart = time(9, 10, 25)
        let study = PlanTask("Translate", minutes: 5, category: .study)
        let tasks = [errand, study]
        let blocks = Planner.schedule(at: time(9, 9), tasks: tasks, commitments: [], reports: [], dailyLimit: 60, breaks: false,
                                      preferences: prefs, calendar: calendar)
        #expect(blocks.first { $0.kind == .task(errand.id) }?.start == errand.plannedStart)
        #expect(!blocks.contains { $0.kind == .timeBlock(focus.id, .boost) })
        let choices = Planner.placements(for: study.id, at: time(9, 9), tasks: tasks, commitments: [], reports: [], dailyLimit: 60,
                                         breaks: false, preferences: prefs, calendar: calendar)
        #expect(choices.contains { $0.start == time(9,10,30) && $0.inFocusTime && $0.recommended })
        let spare = Planner.spareMoments(at: time(9, 9), minutes: 5, tasks: [study, PlanTask("Mail a letter", minutes: 5, category: .personal)],
                                         commitments: [], reports: [], dailyLimit: 5, preferences: prefs, calendar: calendar)
        #expect(spare.isEmpty)
    }

    @Test func oneOffCrossMidnightUsesItsCivilDateAndNeverRepeats() throws {
        let monday = time(9, 12)
        var once = rule(.protected, days: [1], start: 22 * 60, end: 2 * 60)
        once.setSingleDate(monday, calendar: calendar)
        var prefs = PlannerPreferences()
        prefs.timeBlocks = [once]
        let tuesday = time(10, 0)
        let tail = try #require(Planner.workExclusions(at: tuesday, commitments: [], reports: [], preferences: prefs, calendar: calendar).first)
        #expect(tail.start == tuesday && tail.end == time(10, 2))
        #expect(Planner.workExclusions(at: time(16, 23), commitments: [], reports: [], preferences: prefs, calendar: calendar).isEmpty)
        let week = WeekOutlook.project(at: time(8, 17), today: [], tasks: [], events: [], reports: [], limit: 60, breaks: false,
                                       preferences: prefs, startHour: 9, calendar: calendar)
        #expect(week.flatMap(\.blocks).filter { $0.kind == .timeBlock(once.id, .protected) }.count == 2)
        var pacific = calendar
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let persisted = try JSONDecoder().decode(WeeklyTimeBlock.self, from: JSONEncoder().encode(once))
        let west = try #require(persisted.singleDate(in: pacific))
        #expect(pacific.component(.day, from: west) == 9 && pacific.component(.hour, from: west) == 0)
        once.setSingleDate(nil)
        let legacy = try JSONDecoder().decode(WeeklyTimeBlock.self, from: JSONEncoder().encode(once))
        #expect(legacy.singleDay == nil && legacy.hours.weekdays == [1])
    }
}
