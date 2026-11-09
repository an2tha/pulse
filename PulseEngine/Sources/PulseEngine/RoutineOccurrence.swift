import CryptoKit
import Foundation

/// The civil day on the original cadence identifies the occurrence even after its pin moves.
public struct RoutineOccurrence: Codable, Hashable, Sendable {
    public let seriesID: UUID
    public let rule: Recurrence
    public let nominalDay: Int
    public let id: UUID

    public init(seriesID: UUID, rule: Recurrence, day: Date, calendar: Calendar) {
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let parts = civil.dateComponents([.year, .month, .day], from: day)
        self.seriesID = seriesID
        self.rule = rule
        self.nominalDay = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        self.id = Self.identifier(seriesID, rule: rule, day: nominalDay)
    }

    public var isValid: Bool {
        rule != .once && day(in: Calendar(identifier: .gregorian)) != nil
            && id == Self.identifier(seriesID, rule: rule, day: nominalDay)
    }

    func day(in calendar: Calendar) -> Date? {
        guard (10_101...99_991_231).contains(nominalDay) else { return nil }
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let components = DateComponents(year: nominalDay / 10_000, month: nominalDay / 100 % 100, day: nominalDay % 100)
        guard components.isValidDate(in: civil) else { return nil }
        return civil.date(from: components)
    }

    private static func identifier(_ series: UUID, rule: Recurrence, day: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("pulse/routine/1/\(series.uuidString)/\(rule.rawValue)/\(day)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public struct RoutineException: Codable, Equatable, Sendable {
    public let occurrence: RoutineOccurrence
    public let start: Date
    /// This nominal occurrence now lives in the drawer as its own task.
    public let detached: Bool?

    public init(occurrence: RoutineOccurrence, start: Date, detached: Bool? = nil) {
        self.detached = detached
        self.occurrence = occurrence
        self.start = start
    }
}

extension PlanTask {
    /// A generated occurrence keeps the UUID derived from its nominal civil day.
    public func occurrence(in calendar: Calendar = .current) -> RoutineOccurrence? {
        guard let seriesID, let anchor = routineAnchor, let rule = repeated, rule != .once else { return nil }
        let key = RoutineOccurrence(seriesID: seriesID, rule: rule, day: anchor, calendar: calendar)
        return key.id == id ? key : nil
    }

    public func owns(_ occurrence: RoutineOccurrence) -> Bool {
        guard !done, archived != true, repeated == occurrence.rule, (seriesID ?? id) == occurrence.seriesID else { return false }
        if repeated == .daily, let repeatDays {
            var civil = Calendar(identifier: .gregorian)
            civil.timeZone = .gmt
            guard let nominal = occurrence.day(in: civil) else { return false }
            return repeatDays.contains(civil.component(.weekday, from: nominal))
        }
        return true
    }

    public mutating func setException(_ replacement: RoutineException?, for occurrence: RoutineOccurrence, calendar: Calendar = .current) {
        guard owns(occurrence), replacement.map({ $0.occurrence == occurrence }) != false else { return }
        if let replacement, repeatDays != nil, !keepsRepeatException(replacement, calendar: calendar) { return }
        var entries = routineExceptions ?? []
        entries.removeAll { $0.occurrence == occurrence }
        if let replacement { entries.append(replacement) }
        // An explicit removal must survive a sync with a device that still has the old exception.
        routineExceptions = entries
    }

    /// Exception moves may run before the generated nominal release after their predecessor closes.
    mutating func applyException(_ start: Date, nominalDay: Date, calendar: Calendar) {
        let original = after
        let release = min(after ?? nominalDay, calendar.startOfDay(for: start))
        moveOccurrence(to: start, originalDay: nominalDay, calendar: calendar)
        if original != release {
            movedRoutineTimes?.availability = MovedRoutineTime(original: original, moved: release)
            after = release
        }
    }

    /// Older peers can still complete a predecessor without understanding saved future times.
    public mutating func inheritExceptions(from older: PlanTask, at now: Date, calendar: Calendar = .current) {
        guard routineExceptions == nil, !done, archived != true, let rule = repeated, rule != .once,
              older.repeated == rule, (older.seriesID ?? older.id) == (seriesID ?? id),
              let entries = older.routineExceptions, !entries.isEmpty else { return }
        if older.id == id {
            routineExceptions = entries
            if repeatDays != nil { pruneRepeatExceptions(calendar: calendar) }
            return
        }
        guard let anchor = routineAnchor, let seriesID else { return }
        let identity = RoutineOccurrence(seriesID: seriesID, rule: rule, day: anchor, calendar: calendar)
        if movedRoutineTimes?.pin == nil, plannedStart == nil || plannedStart == anchor,
           owns(identity), let move = entries.first(where: { $0.occurrence == identity }), move.detached != true, move.start >= now,
           repeatDays == nil || keepsRepeatException(move, calendar: calendar),
           nextCadenceDay(calendar: calendar).map({ move.start < $0 }) == true {
            applyException(move.start, nominalDay: anchor, calendar: calendar)
        }
        routineExceptions = entries.filter { $0.occurrence.rule == rule && $0.occurrence.nominalDay > identity.nominalDay && $0.start >= now }
        if repeatDays != nil { pruneRepeatExceptions(calendar: calendar) }
    }

    func nextCadenceDay(calendar: Calendar) -> Date? {
        guard let anchor = routineAnchor else { return nil }
        return cadenceDay(from: anchor, anchor: anchor, calendar: calendar)
    }
}
