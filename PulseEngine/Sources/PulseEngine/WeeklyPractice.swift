import Foundation

/// A weekly target counts distinct local days. A missed day never creates extra work.
public struct WeeklyPractice: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var targetDays: Int
    public var minutes: Int
    public private(set) var logs: [Log] = []

    public struct Log: Codable, Equatable, Sendable {
        public let date: Date
        public let taskID: UUID?
    }

    public init(_ title: String, targetDays: Int = 3, minutes: Int = 10) {
        self.title = title
        self.targetDays = min(7, max(1, targetDays))
        self.minutes = min(1440, max(1, minutes))
    }

    public func logged(on date: Date, calendar: Calendar = .current) -> Log? {
        logs.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    public func progress(at now: Date, calendar: Calendar = .current) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return Set(logs.filter { $0.date >= week.start && $0.date < week.end && $0.date <= now }
            .map { calendar.startOfDay(for: $0.date) }).count
    }

    public mutating func log(at date: Date, taskID: UUID? = nil, calendar: Calendar = .current) {
        guard logged(on: date, calendar: calendar) == nil else { return }
        logs.append(Log(date: date, taskID: taskID))
    }

    public mutating func removeLog(on date: Date, calendar: Calendar = .current) {
        logs.removeAll { calendar.isDate($0.date, inSameDayAs: date) }
    }

    public mutating func removeLog(_ entry: Log) {
        logs.removeAll { $0 == entry }
    }

    public func pending(in tasks: [PlanTask]) -> PlanTask? {
        tasks.first { $0.practiceID == id && !$0.done && $0.archived != true }
    }

    public func session(for date: Date, tasks: [PlanTask], calendar: Calendar = .current) -> PlanTask? {
        guard pending(in: tasks) == nil, logged(on: date, calendar: calendar) == nil,
              progress(at: date, calendar: calendar) < targetDays else { return nil }
        var task = PlanTask(title, minutes: minutes, category: .personal)
        task.practiceID = id
        return task
    }
}
