import Foundation

/// Repeated survey responses for a task, or for successive occurrences of one routine.
public struct TaskSkipPattern: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let records: [TaskSkipRecord]
    public let targetTaskID: UUID?

    /// Index is reported energy (0...10); value is the number of surveys at that level.
    public var energyCounts: [Int] {
        records.reduce(into: [Int](repeating: 0, count: 11)) { $0[$1.energy] += 1 }
    }

    public static func repeated(in records: [TaskSkipRecord], tasks: [PlanTask], through day: Date, now: Date,
                                activeTaskID: UUID? = nil, calendar: Calendar = .current) -> [Self] {
        guard !records.isEmpty, let endDay = calendar.dateInterval(of: .day, for: day),
              endDay.start <= now,
              let start = calendar.date(byAdding: .day, value: -29, to: endDay.start) else { return [] }

        let surveys = records.filter { $0.skippedAt >= start && $0.skippedAt < endDay.end && $0.skippedAt <= now && $0.isValid }
        guard surveys.count >= 2 else { return [] }

        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byFamily = Dictionary(grouping: tasks) { $0.seriesID ?? $0.id }
        // Older surveys did not store a series ID. Archived occurrences retain their lineage.
        let histories = Dictionary(grouping: surveys) { $0.seriesID ?? byID[$0.taskID]?.seriesID ?? $0.taskID }
        let isCurrent = calendar.isDate(day, inSameDayAs: now)
        return histories.compactMap { id, surveys -> Self? in
            guard surveys.count >= 2 else { return nil }
            let ordered = surveys.sorted {
                if $0.skippedAt != $1.skippedAt { return $0.skippedAt > $1.skippedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let open = (byFamily[id] ?? []).filter { !$0.done && $0.archived != true }
            let target = open.first { !$0.isInboxOnly && $0.id != activeTaskID }
            let currentTitle = target?.title ?? open.first?.title ?? byID[ordered[0].taskID]?.title
            return Self(id: id, title: isCurrent ? currentTitle ?? ordered[0].title : ordered[0].title,
                        records: ordered, targetTaskID: isCurrent ? target?.id : nil)
        }.sorted {
            if $0.records.count != $1.records.count { return $0.records.count > $1.records.count }
            if $0.records[0].skippedAt != $1.records[0].skippedAt { return $0.records[0].skippedAt > $1.records[0].skippedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
