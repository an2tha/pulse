import Foundation

/// An individual appointment. A recurring series uses the occurrence's ordinal,
/// so an edit to its starting clock or weekday keeps the same appointment linked.
public struct TaskPreparation: Codable, Hashable, Sendable {
    public let commitmentID: UUID
    public let recurrence: Recurrence
    public let occurrenceIndex: Int
    public private(set) var lastKnownStart: Date

    public var isValid: Bool {
        (0...3_652_058).contains(occurrenceIndex) && (recurrence != .once || occurrenceIndex == 0)
            && lastKnownStart.timeIntervalSinceReferenceDate.isFinite
    }

    public init?(block: Block, commitment: Commitment, after now: Date, calendar: Calendar = .current) {
        guard block.kind == .fixed(commitment.id), commitment.end > commitment.start,
              let day = calendar.dateInterval(of: .day, for: block.start),
              commitment.intervals(on: block.start, calendar: calendar).contains(where: {
                  $0.start == block.start && $0.end == block.end
              }) else { return nil }
        commitmentID = commitment.id
        recurrence = commitment.recurrence
        if recurrence == .once {
            occurrenceIndex = 0
            lastKnownStart = commitment.start
        } else {
            let anchor = calendar.startOfDay(for: commitment.start)
            guard let elapsed = calendar.dateComponents([.day], from: anchor, to: day.start).day, elapsed >= 0 else { return nil }
            let pattern = OccurrencePattern(commitment: commitment, calendar: calendar)
            let span = calendar.dateComponents([.day], from: anchor, to: calendar.startOfDay(for: commitment.end)).day ?? 0
            // A day view can show the after-midnight tail. Use the actual opening
            // and reject merged coverage that cannot identify one occurrence.
            var match: (index: Int, start: Date)?
            for prior in 0...min(elapsed, max(0, span)) {
                let offset = elapsed - prior
                guard let index = pattern.index(at: offset),
                      let start = calendar.date(byAdding: .day, value: offset, to: commitment.start),
                      let shiftedEnd = calendar.date(byAdding: .day, value: offset, to: commitment.end) else { continue }
                let end = shiftedEnd > start ? shiftedEnd : start.addingTimeInterval(commitment.end.timeIntervalSince(commitment.start))
                guard start < block.end && block.start < end else { continue }
                guard match == nil, max(start, day.start) == block.start, min(end, day.end) == block.end else { return nil }
                match = (index, start)
            }
            guard let match else { return nil }
            occurrenceIndex = match.index
            lastKnownStart = match.start
        }
        guard lastKnownStart > now, isValid else { return nil }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        commitmentID = try fields.decode(UUID.self, forKey: .commitmentID)
        recurrence = try fields.decode(Recurrence.self, forKey: .recurrence)
        occurrenceIndex = try fields.decode(Int.self, forKey: .occurrenceIndex)
        lastKnownStart = try fields.decode(Date.self, forKey: .lastKnownStart)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .occurrenceIndex, in: fields,
                                                   debugDescription: "Invalid preparation occurrence.")
        }
    }

    public func sameOccurrence(as other: Self) -> Bool {
        commitmentID == other.commitmentID && recurrence == other.recurrence && occurrenceIndex == other.occurrenceIndex
    }

    public func resolvedStart(in commitments: [Commitment], calendar: Calendar = .current) -> Date? {
        guard let event = commitments.first(where: { $0.id == commitmentID }),
              event.recurrence == recurrence, event.end > event.start else { return nil }
        if recurrence == .once { return event.start }
        let pattern = OccurrencePattern(commitment: event, calendar: calendar)
        guard let offset = pattern.offset(for: occurrenceIndex) else { return nil }
        return calendar.date(byAdding: .day, value: offset, to: event.start)
    }

    public func refreshed(in commitments: [Commitment], calendar: Calendar = .current) -> Self {
        var copy = self
        if let start = resolvedStart(in: commitments, calendar: calendar) { copy.lastKnownStart = start }
        return copy
    }
}

/// The repeating seven-day pattern is anchored to the series' local starting day.
private struct OccurrencePattern {
    let offsets: [Int]

    init(commitment: Commitment, calendar: Calendar) {
        switch commitment.recurrence {
        case .daily: offsets = Array(0..<7)
        case .weekly: offsets = [0]
        case .weekdays:
            let anchor = calendar.startOfDay(for: commitment.start)
            offsets = (0..<7).filter { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: anchor) else { return false }
                return !calendar.isDateInWeekend(date)
            }
        case .once: offsets = []
        }
    }

    func index(at elapsed: Int) -> Int? {
        guard let day = offsets.firstIndex(of: elapsed % 7) else { return nil }
        return (elapsed / 7) * offsets.count + day
    }

    func offset(for index: Int) -> Int? {
        guard !offsets.isEmpty else { return nil }
        return (index / offsets.count) * 7 + offsets[index % offsets.count]
    }
}

extension PlanTask {
    public func preparationCutoff(bufferMinutes: Int) -> Date? {
        preparation?.lastKnownStart.addingTimeInterval(-Double(min(30, max(0, bufferMinutes))) * 60)
    }

    /// Derive a scheduling snapshot. The stored task keeps its independent deadline and pin.
    public func planningCopy(with commitments: [Commitment], bufferMinutes: Int, calendar: Calendar = .current) -> Self {
        guard let preparation else { return self }
        var copy = self
        copy.preparation = preparation.refreshed(in: commitments, calendar: calendar)
        if let cutoff = copy.preparationCutoff(bufferMinutes: bufferMinutes) {
            copy.due = min(due ?? cutoff, cutoff)
            if let pin = plannedStart, cutoff.timeIntervalSince(pin) < 60 { copy.plannedStart = nil }
        }
        return copy
    }
}

extension Array where Element == PlanTask {
    func resolvingPreparations(with commitments: [Commitment], bufferMinutes: Int, calendar: Calendar) -> Self {
        guard contains(where: { $0.preparation != nil && !$0.done && $0.archived != true }) else { return self }
        var copy = self
        for index in indices where self[index].preparation != nil && !self[index].done && self[index].archived != true {
            copy[index] = self[index].planningCopy(with: commitments, bufferMinutes: bufferMinutes, calendar: calendar)
        }
        return copy
    }
}

extension Commitment {
    /// Return only real upcoming occurrences starting in this local day.
    public func preparationOccurrences(on date: Date, after now: Date, calendar: Calendar = .current) -> [TaskPreparation] {
        intervals(on: date, calendar: calendar).compactMap { interval in
            let block = Block(kind: .fixed(id), title: title, start: interval.start, end: interval.end)
            guard let link = TaskPreparation(block: block, commitment: self, after: now, calendar: calendar),
                  calendar.isDate(link.lastKnownStart, inSameDayAs: date) else { return nil }
            return link
        }
    }
}
