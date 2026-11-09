import CryptoKit
import EventKit
import Foundation
import HealthKit
import PulseEngine

struct ConnectionState: Codable, Equatable, Sendable {
    var onDeviceAssistant = false
    var planningPreference = ""
    var oneRep = false
    var published: [String: String] = [:]
}

struct CalendarCandidate: Identifiable, Sendable {
    let id: UUID
    let title: String
    let calendar: String
    let start: Date
    let end: Date
    var singleEventKey: String?
    var legacyID: UUID?

    var commitment: Commitment {
        var event = Commitment(title, start: start, end: end)
        event.id = id
        return event
    }

    /// Earlier imports used the event's then-current start as an instance key, even for one-off events.
    func matchingCopy(in journal: [Commitment]) -> UUID? {
        if journal.contains(where: { $0.id == id }) { return id }
        if let legacyID, journal.contains(where: { $0.id == legacyID }) { return legacyID }
        guard let singleEventKey else { return nil }
        return journal.first { event in
            guard event.id.uuid.6 >> 4 == 8 else { return false }
            return CalendarBridge.stableID(singleEventKey + String(event.start.timeIntervalSince1970)) == event.id
        }?.id
    }

    func overlaps(_ existing: Commitment, calendar: Calendar = .current) -> Bool {
        guard existing.id != id, existing.start < end else { return false }
        if existing.recurrence == .once { return start < existing.end }
        let first = calendar.startOfDay(for: max(start, existing.start))
        // Recurrences repeat at least weekly. Include the eighth day for a
        // partial first or last day and use calendar arithmetic across DST.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first), day < end else { break }
            if existing.intervals(on: day, calendar: calendar).contains(where: { $0.start < end && start < $0.end }) {
                return true
            }
        }
        return false
    }
}

struct ReminderCandidate: Identifiable, Sendable {
    let id: UUID
    let title: String
    let list: String
    let listID: String
    let itemID: String
    let accountKey: UUID?
    let due: Date?
    let completed: Bool
    var selectionID: UUID { CalendarBridge.stableID("reminder-instance|" + itemID) }
}

enum ConnectionError: LocalizedError {
    case permission, unavailable, noCalendar, invalidBlock, tooMuchData
    var errorDescription: String? {
        switch self {
        case .permission: "Access is unavailable. Review Pulse’s permissions in iPhone Settings."
        case .unavailable: "This service is unavailable on this device."
        case .noCalendar: "Choose a writable calendar first."
        case .invalidBlock: "This time block changed. Review the current plan and try again."
        case .tooMuchData: "This file exceeds the supported size."
        }
    }
}

@MainActor final class CalendarBridge {
    let store = EKEventStore()

    func request(_ kind: EKEntityType) async throws {
        let allowed: Bool
        switch kind {
        case .event: allowed = try await store.requestFullAccessToEvents()
        case .reminder: allowed = try await store.requestFullAccessToReminders()
        @unknown default: allowed = false
        }
        guard allowed else { throw ConnectionError.permission }
    }

    func events(calendarID: String, from date: Date) throws -> [CalendarCandidate] {
        try Self.events(in: store, calendarID: calendarID, from: date)
    }

    nonisolated static func events(in store: EKEventStore, calendarID: String, from date: Date, excluding published: Set<String> = []) throws -> [CalendarCandidate] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            let calendar = store.calendar(withIdentifier: calendarID)
        else { throw ConnectionError.permission }
        let now = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 14, to: now)!
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: [calendar])
        var visited = Set<UUID>()
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.compactMap { event in
            guard event.status != .canceled, event.availability != .free, event.endDate > date,
                event.endDate > event.startDate,
                event.url?.scheme?.lowercased() != "pulse-block", !published.contains(event.eventIdentifier ?? ""),
                event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) != true
            else { return nil }
            let key = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
            let series = event.hasRecurrenceRules || event.isDetached
            let instance = series ? String((event.occurrenceDate ?? event.startDate).timeIntervalSince1970) : ""
            let seriesKey = Self.seriesIdentifier(key, detached: event.isDetached)
            let base = "event|\(calendarID)|\(seriesKey)|"
            let id = Self.stableID(base + instance)
            guard visited.insert(id).inserted else { return nil }
            return CalendarCandidate(
                id: id, title: event.title ?? "Calendar event", calendar: calendar.title, start: event.startDate,
                end: event.endDate, singleEventKey: series ? nil : base,
                legacyID: seriesKey == key ? nil : Self.stableID("event|\(calendarID)|\(key)|\(instance)"))
        }
    }

    func reminders(calendarID: String) async throws -> [ReminderCandidate] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
            let list = store.calendar(withIdentifier: calendarID)
        else { throw ConnectionError.permission }
        return try await Self.incompleteReminders(in: [list], store: store)
    }

    static func incompleteReminders(in lists: [EKCalendar], store: EKEventStore) async throws -> [ReminderCandidate] {
        guard !lists.isEmpty else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable records in
                guard let records else { continuation.resume(throwing: ConnectionError.unavailable); return }
                let result = records.compactMap(Self.candidate).sorted {
                    if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                    return $0.itemID < $1.itemID
                }
                continuation.resume(returning: result)
            }
        }
    }

    // Copy EventKit objects into values on the queue that supplied them.
    nonisolated static func candidate(_ reminder: EKReminder) -> ReminderCandidate? {
        guard let list = reminder.calendar else { return nil }
        let key = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
        let accountKey = list.source.flatMap { source in
            reminder.calendarItemExternalIdentifier.map { stableID("reminder|\(source.sourceIdentifier)|\($0)") }
        }
        let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ReminderCandidate(
            id: stableID("reminder|\(list.calendarIdentifier)|\(key)"),
            title: title.isEmpty ? "Reminder" : title, list: list.title,
            listID: list.calendarIdentifier, itemID: reminder.calendarItemIdentifier,
            accountKey: accountKey,
            due: reminder.dueDateComponents.flatMap { reminderDue($0) }, completed: reminder.isCompleted)
    }

    nonisolated static func reminderDue(_ components: DateComponents, local: Calendar = .current) -> Date? {
        var calendar = components.calendar ?? local
        calendar.timeZone = components.timeZone ?? local.timeZone
        guard let day = calendar.date(from: components) else { return nil }
        // An all-day reminder remains usable throughout its local due date.
        if components.hour == nil && components.minute == nil && components.second == nil {
            return calendar.dateInterval(of: .day, for: day)?.end.addingTimeInterval(-1)
        }
        return day
    }

    func conflicts(for block: Block, calendarID: String) throws -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            let calendar = store.calendar(withIdentifier: calendarID),
            case .task(let taskID) = block.kind
        else { throw ConnectionError.permission }
        let ownMarker = URL(string: "pulse-block://scheduled/\(Self.publicationKey(taskID, on: block.start))")
        let predicate = store.predicateForEvents(withStart: block.start, end: block.end, calendars: [calendar])
        return store.events(matching: predicate).filter {
            $0.url != ownMarker && $0.status != .canceled && $0.availability != .free
                && $0.startDate < block.end && block.start < $0.endDate
        }.map { $0.title ?? "Calendar event" }.sorted()
    }

    func publish(_ block: Block, calendarID: String, priorID: String?) throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw ConnectionError.permission }
        guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
            throw ConnectionError.noCalendar
        }
        guard case .task(let taskID) = block.kind, block.end > block.start else { throw ConnectionError.invalidBlock }
        let key = Self.publicationKey(taskID, on: block.start)
        let marker = URL(string: "pulse-block://scheduled/\(key)")!
        let day = Calendar.current.dateInterval(of: .day, for: block.start)!
        let existing = priorID.flatMap(store.event(withIdentifier:))
        let matches = store.events(
            matching: store.predicateForEvents(withStart: day.start, end: day.end, calendars: [calendar]))
        let event =
            (existing?.url == marker ? existing : nil) ?? matches.first { $0.url == marker }
            ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = block.title
        event.startDate = block.start
        event.endDate = block.end
        event.url = marker
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }

    static func publicationKey(_ id: UUID, on date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(id.uuidString)-\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    /// A detached EventKit instance can append its original recurrence identifier to the external ID.
    /// Its occurrence date already supplies that part of our per-occurrence key.
    nonisolated static func seriesIdentifier(_ key: String, detached: Bool) -> String {
        guard detached, let marker = key.range(of: "/RID=", options: .backwards),
              Int64(key[marker.upperBound...]) != nil else { return key }
        return String(key[..<marker.lowerBound])
    }

    nonisolated static func stableID(_ key: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x80
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
    }
}

struct HealthDay: Identifiable, Sendable {
    let date: Date
    let sleepHours: Double?
    let steps: Int?
    var id: Date { date }

    func checkIns(in reports: [CheckIn], calendar: Calendar = .current) -> [CheckIn] {
        reports.filter { calendar.isDate($0.date, inSameDayAs: date) }.sorted { $0.date < $1.date }
    }
}

enum HealthBridge {
    static func week(sleep: Bool, activity: Bool, requestPermission: Bool = true) async throws -> [HealthDay] {
        guard HKHealthStore.isHealthDataAvailable() else { throw ConnectionError.unavailable }
        let store = HKHealthStore()
        let cal = Calendar.current
        let rest = HKCategoryType(.sleepAnalysis)
        let step = HKQuantityType(.stepCount)
        var wanted = Set<HKObjectType>()
        if sleep { wanted.insert(rest) }
        if activity { wanted.insert(step) }
        guard !wanted.isEmpty else { return [] }
        if requestPermission { try await store.requestAuthorization(toShare: [], read: wanted) }
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -6, to: today)!
        let now = Date.now
        var intervals: [DateInterval] = []
        if sleep {
            let range = HKSamplePredicate.categorySample(
                type: rest, predicate: HKQuery.predicateForSamples(withStart: start, end: now))
            let samples = try await HKSampleQueryDescriptor(
                predicates: [range], sortDescriptors: [SortDescriptor(\.startDate)]
            ).result(for: store)
            let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
            for sample in samples where asleep.contains(sample.value) && sample.endDate > sample.startDate {
                if let last = intervals.last, sample.startDate <= last.end {
                    intervals[intervals.count - 1] = DateInterval(start: last.start, end: max(last.end, sample.endDate))
                } else {
                    intervals.append(DateInterval(start: sample.startDate, end: sample.endDate))
                }
            }
        }
        var counts: [Date: Int] = [:]
        if activity {
            let filter = HKSamplePredicate.quantitySample(
                type: step, predicate: HKQuery.predicateForSamples(withStart: start, end: now))
            let result = try await HKStatisticsCollectionQueryDescriptor(
                predicate: filter, options: .cumulativeSum, anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            ).result(for: store)
            for stats in result.statistics() {
                if let total = stats.sumQuantity() {
                    counts[cal.startOfDay(for: stats.startDate)] = Int(total.doubleValue(for: .count()))
                }
            }
        }
        return (0..<7).map { index in
            let day = cal.date(byAdding: .day, value: index, to: start)!
            let bounds = cal.dateInterval(of: .day, for: day)!
            let seconds = intervals.reduce(0.0) { $0 + ($1.intersection(with: bounds)?.duration ?? 0) }
            return HealthDay(date: day, sleepHours: seconds > 0 ? seconds / 3600 : nil, steps: counts[day])
        }.reversed()
    }
}
