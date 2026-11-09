import Foundation
import Testing
@testable import PulseEngine

@Suite struct TaskSkipPatternTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: .init(year: 2026, month: month, day: day, hour: hour))!
    }

    private func skip(_ task: UUID, _ date: Date, _ energy: Int, title: String = "Read", series: UUID? = nil) -> TaskSkipRecord {
        TaskSkipRecord(taskID: task, title: title, scheduledStart: date.addingTimeInterval(-1800),
                       skippedAt: date, reason: .notEnoughTime, energy: energy, seriesID: series)
    }

    @Test func historicalWindowUsesLocalCalendarAndReportedEnergy() throws {
        let now = day(4, 15), selected = day(4, 14)
        var task = PlanTask("Read the short stories", minutes: 10)
        task.plannedStart = now
        let records = [
            skip(task.id, day(3, 15, 23), 0),
            skip(task.id, day(3, 16, 0), 0),
            skip(task.id, day(4, 14, 23), 10),
            skip(task.id, day(4, 15, 0), 9)
        ]
        let history = try #require(TaskSkipPattern.repeated(in: records, tasks: [task], through: selected,
                                                             now: now, calendar: calendar).first)
        #expect(history.records.map(\.energy) == [10, 0])
        #expect(history.title == "Read")
        #expect(history.targetTaskID == nil)
        #expect(history.energyCounts == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    @Test func legacyArchivedOccurrencesAndDeletedOccurrencesShareTheirCurrentSeries() throws {
        let series = UUID(), now = day(4, 15)
        var old = PlanTask("Read", minutes: 10)
        old.seriesID = series
        old.archived = true
        var next = old.duplicate()
        next.seriesID = series
        next.title = "Read one chapter"
        let encoded = try JSONEncoder().encode(skip(old.id, day(4, 12), 3))
        let legacy = try JSONDecoder().decode(TaskSkipRecord.self, from: encoded)
        #expect(legacy.seriesID == nil)
        let deleted = skip(UUID(), day(4, 14), 3, series: series)
        let persisted = try JSONDecoder().decode(TaskSkipRecord.self, from: JSONEncoder().encode(deleted))
        let patterns = TaskSkipPattern.repeated(in: [legacy, persisted], tasks: [old, next], through: now, now: now, calendar: calendar)
        #expect(patterns.count == 1)
        let pattern = try #require(patterns.first)
        #expect(pattern.id == series && pattern.targetTaskID == next.id)
        #expect(pattern.title == next.title && pattern.energyCounts[3] == 2)
    }

    @Test func deletedTasksRemainVisibleWithoutCombiningMatchingTitles() throws {
        let now = day(4, 15), left = UUID(), right = UUID()
        let records = [skip(left, day(4, 11), 2), skip(right, day(4, 12), 7), skip(left, day(4, 13), 4)]
        let patterns = TaskSkipPattern.repeated(in: records, tasks: [], through: now, now: now, calendar: calendar)
        #expect(patterns.count == 1)
        let pattern = try #require(patterns.first)
        #expect(pattern.id == left && pattern.targetTaskID == nil && pattern.title == "Read")
        #expect(pattern.records.map(\.energy) == [4, 2])
    }

    @Test func ineligibleAndFutureSurveysCannotDriveSuggestions() {
        let now = day(4, 15, 11)
        var task = PlanTask("Read", minutes: 10)
        var records = [skip(task.id, day(4, 14), 2), skip(task.id, day(4, 15, 12), 3)]
        func patterns(_ active: UUID? = nil) -> [TaskSkipPattern] {
            TaskSkipPattern.repeated(in: records, tasks: [task], through: now, now: now, activeTaskID: active, calendar: calendar)
        }
        #expect(patterns().isEmpty)
        records.append(skip(task.id, day(4, 15, 10), 5))
        #expect(patterns().first?.targetTaskID == task.id)
        #expect(patterns(task.id).first?.targetTaskID == nil)
        task.inboxOnly = true
        #expect(patterns().first?.targetTaskID == nil)
        task.inboxOnly = nil
        task.done = true
        #expect(patterns().first?.targetTaskID == nil)
        task.done = false
        task.archived = true
        #expect(patterns().first?.targetTaskID == nil)
        #expect(TaskSkipPattern.repeated(in: records, tasks: [task], through: day(4, 16), now: now, calendar: calendar).isEmpty)
    }
}
