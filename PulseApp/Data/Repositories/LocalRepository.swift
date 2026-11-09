import Foundation
import PulseEngine
import SwiftData

enum CaptureDraftSlot: Equatable {
    case quick
    case sprint(UUID)
}

struct CaptureReference: Codable, Equatable, Sendable {
    let date: Date
    let timeZone: TimeZone

    init(at date: Date = .now, timeZone: TimeZone = .current) {
        self.date = date
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }
}

struct CaptureDrafts: Codable, Equatable, Sendable {
    struct SprintDraft: Codable, Equatable, Sendable {
        var text: String
        var literal: Bool
        var updatedAt: Date
        var timeZone: TimeZone?
    }

    static let sprintLimit = 32
    static let sprintByteLimit = 64 * 1024
    var sprints: [UUID: SprintDraft]?
    var quick = ""
    var quickLiteral = false
    var dump = ""
    var reviewed: [PlanTask] = []
    var quickReference: CaptureReference?
    var dumpReference: CaptureReference?
    var dumpLineReferences: [Int: CaptureReference]?
    var reviewedLineIndices: [UUID: Int]?
    var stored: Self? { quick.isEmpty && dump.isEmpty && reviewed.isEmpty && (sprints?.isEmpty ?? true) ? nil : self }

    func text(for slot: CaptureDraftSlot) -> String {
        switch slot {
        case .quick: quick
        case .sprint(let id): sprints?[id]?.text ?? ""
        }
    }

    func literal(for slot: CaptureDraftSlot) -> Bool {
        switch slot {
        case .quick: quickLiteral
        case .sprint(let id): sprints?[id]?.literal ?? false
        }
    }

    func hasRoom(for id: UUID) -> Bool {
        sprints?[id] != nil || (sprints?.count ?? 0) < Self.sprintLimit
    }

    func reference(for slot: CaptureDraftSlot) -> CaptureReference? {
        switch slot {
        case .quick: return quickReference
        case .sprint(let id):
            guard let draft = sprints?[id], let zone = draft.timeZone else { return nil }
            return CaptureReference(at: draft.updatedAt, timeZone: zone)
        }
    }

    // Older sprint drafts already recorded their edit date. Other older drafts first
    // acquire an anchor when recovered, before either previewing or saving them.
    mutating func recoverReference(for slot: CaptureDraftSlot, fallback: CaptureReference = .init()) {
        guard !text(for: slot).isEmpty, reference(for: slot) == nil else { return }
        switch slot {
        case .quick: quickReference = fallback
        case .sprint(let id): sprints?[id]?.timeZone = fallback.timeZone
        }
    }

    mutating func recoverDumpReference(fallback: CaptureReference = .init()) {
        if !dump.isEmpty && dumpReference == nil { dumpReference = fallback }
    }

    mutating func setDump(_ text: String, reference: CaptureReference = .init()) {
        guard text != dump || text.isEmpty else { return }
        let oldLines = Self.dumpLines(in: dump)
        let newLines = Self.dumpLines(in: text)
        let preserved = Self.matchingLines(old: oldLines, new: newLines)
        var overrides: [Int: CaptureReference] = [:]
        for (newIndex, oldIndex) in preserved {
            if let previous = dumpLineReferences?[oldIndex] ?? dumpReference, previous != reference {
                overrides[newIndex] = previous
            }
        }
        dump = text
        dumpReference = text.isEmpty ? nil : reference
        dumpLineReferences = overrides.isEmpty ? nil : overrides
        reviewed = []
        reviewedLineIndices = nil
    }

    private static func dumpLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // Hold both unchanged ends in place. Match moved lines one-to-one in their
    // original order so two identical lines can keep distinct edit times.
    private static func matchingLines(old: [String], new: [String]) -> [Int: Int] {
        var matches: [Int: Int] = [:]
        var prefix = 0
        while prefix < min(old.count, new.count) && old[prefix] == new[prefix] {
            matches[prefix] = prefix
            prefix += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefix && newEnd > prefix && old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
            matches[newEnd] = oldEnd
        }
        var byText: [String: [Int]] = [:]
        for index in (prefix..<oldEnd).reversed() { byText[old[index], default: []].append(index) }
        for index in prefix..<newEnd {
            if let original = byText[new[index]]?.popLast() { matches[index] = original }
        }
        return matches
    }

    func reviewDump(commitments: [Commitment]) -> (tasks: [PlanTask], indices: [UUID: Int]) {
        var tasks: [PlanTask] = []
        var indices: [UUID: Int] = [:]
        for (index, line) in Self.dumpLines(in: dump).enumerated() {
            guard let clock = dumpLineReferences?[index] ?? dumpReference,
                  let task = TodoDump.tasks(from: line, at: clock.date, calendar: clock.calendar, commitments: commitments).first
            else { continue }
            tasks.append(task)
            if dumpLineReferences?[index] != nil { indices[task.id] = index }
        }
        return (tasks, indices)
    }

    func reviewedReference(for id: UUID) -> CaptureReference? {
        reviewedLineIndices?[id].flatMap { dumpLineReferences?[$0] } ?? dumpReference
    }

    @discardableResult mutating func setText(_ text: String, for slot: CaptureDraftSlot,
                                              reference: CaptureReference = .init()) -> Bool {
        guard !text.isEmpty else { clear(slot); return true }
        guard text != self.text(for: slot) else { return true }
        switch slot {
        case .quick: quick = text; quickReference = reference
        case .sprint(let id):
            guard hasRoom(for: id), text.utf8.count <= Self.sprintByteLimit else { return false }
            if sprints == nil { sprints = [:] }
            let literal = sprints?[id]?.literal ?? false
            sprints?[id] = SprintDraft(text: text, literal: literal, updatedAt: reference.date, timeZone: reference.timeZone)
        }
        return true
    }

    mutating func toggleLiteral(for slot: CaptureDraftSlot) {
        switch slot {
        case .quick: quickLiteral.toggle()
        case .sprint(let id): sprints?[id]?.literal.toggle()
        }
    }

    mutating func clear(_ slot: CaptureDraftSlot) {
        switch slot {
        case .quick: quick = ""; quickLiteral = false; quickReference = nil
        case .sprint(let id):
            sprints?.removeValue(forKey: id)
            if sprints?.isEmpty == true { sprints = nil }
        }
    }
}

struct Journal: Codable, Equatable, Sendable {
    var sleepWindow: PlannedSleepWindow?
    var sleepTarget: Double?
    var stimulantIntakes: [StimulantIntake]?
    var stimulantBloodSamples: [StimulantBloodSample]?
    var captureDrafts: CaptureDrafts?
    var customEnergyActivities: [EnergyActivity]?
    var energyActivityLogs: [EnergyActivityLog]?
    var timeBlocks: [WeeklyTimeBlock]?
    var energyCorrections: [EnergyCorrection]?
    var energyExpectations: [EnergyExpectation]?
    var forecastHistory: [DayAheadForecast]?
    var photos: [JournalPhoto]?
    var photoProofEnabled: Bool?
    var reminderImports: [UUID: ReminderImportRecord]?
    var importedShares: Set<UUID>?
    var localSprintStarts: [UUID: Date]?
    var tasks: [PlanTask] = []
    var events: [Commitment] = []
    var reports: [CheckIn] = []
    var sessions: [SessionRecord] = []
    var active: ActiveSession?
    var limit = 60
    var breaks = true
    var atmosphere: String?
    var landscapeTheme: String?
    var notifications = false
    // Retain the original key so older local journals and exports still decode.
    var starterAvailable = false
    var restDate: Date?
    var recovery: DateInterval?
    var practices: [WeeklyPractice]?
    var inboxUndo: InboxTriage.Receipt?
    var nextTaskID: UUID?
    var tuning: PlanTuning?
    var taskOrder: [UUID]?
    var bufferMinutes: Int?
    var planHistory: [DayPlanRecord]?
    var taskSkips: [TaskSkipRecord]?
    var automaticTaskStarts: [UUID: Date]?
    var votes: [SuggestionVote]?
    var templates: [PlanTask]?
    var goals: [PersonalGoal]?
    var preferredName: String?
    var continueTask: Bool?
    var ambientSound: Bool?
    var planningStartHour: Int?
    var wrapUpMinute: Int?
    var connections: ConnectionState?
    var reminderPreferences: ReminderPreferences?

}

@Model
final class JournalEntry {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var bytes: Data
    init(bytes: Data, key: String = "journal") {
        self.key = key
        self.bytes = bytes
    }
}

@ModelActor
actor LocalRepository {
    private var lastRevision = 0
    private var lastDraftRevision = 0
    private var draftLayoutReady = false
    private static let draftKey = "capture-drafts"
    private var lastGoodJournal: Journal?
    private var photoCache: [UUID: LocalPictures.Cached] = [:]
    private func entry(_ key: String) throws -> JournalEntry? {
        let sought = key
        var query = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.key == sought })
        query.fetchLimit = 1
        return try modelContext.fetch(query).first
    }

    func load() throws -> Journal { try loadSnapshot().journal }

    func loadSnapshot() throws -> (journal: Journal, recovered: Bool, unavailablePhotos: Int) {
        let draftRow = try entry(Self.draftKey)
        let separate = try draftRow.map { row in
            let drafts = try JSONDecoder().decode(CaptureDrafts.self, from: row.bytes)
            try JournalArchive.validate(Journal(captureDrafts: drafts))
            return drafts
        }
        guard let current = try entry("journal") else { return (Journal(captureDrafts: separate), false, 0) }
        let loaded: LocalPictures.Loaded
        let recovered: Bool
        do {
            loaded = try read(current)
            recovered = false
        } catch JournalArchive.Failure.newerVersion { throw JournalArchive.Failure.newerVersion } catch {
            guard let prior = try entry("previous") else { throw error }
            loaded = try read(prior)
            recovered = true
        }
        var body = loaded.journal
        body.captureDrafts = nil
        lastGoodJournal = body
        photoCache = loaded.cache
        var result = loaded.journal
        if let separate { result.captureDrafts = separate }
        if draftRow != nil { draftLayoutReady = true }
        return (result, recovered, loaded.unavailable)
    }

    private func read(_ row: JournalEntry) throws -> LocalPictures.Loaded {
        try LocalPictures.read(row.bytes) { id in try entry(LocalPictures.key(id))?.bytes }
    }

    // Legacy documents embedded unfinished input in both the live and recovery
    // journals. Remove just that field, retaining the two distinct revisions.
    private func separateInlineDrafts() throws {
        for key in ["journal", "previous"] {
            guard let row = try entry(key), row.bytes.range(of: Data(#""captureDrafts""#.utf8)) != nil else { continue }
            guard var document = try JSONSerialization.jsonObject(with: row.bytes) as? [String: Any] else {
                throw JournalArchive.Failure.invalid
            }
            if var body = document["journal"] as? [String: Any] {
                guard body.removeValue(forKey: "captureDrafts") != nil else { continue }
                document["journal"] = body
            } else if document.removeValue(forKey: "captureDrafts") == nil { continue }
            row.bytes = try JSONSerialization.data(withJSONObject: document)
        }
    }

    private func writeDrafts(_ drafts: CaptureDrafts?) throws {
        let existing = try entry(Self.draftKey)
        if let drafts {
            try JournalArchive.validate(Journal(captureDrafts: drafts))
            let bytes = try JSONEncoder().encode(drafts)
            if let existing {
                if existing.bytes != bytes { existing.bytes = bytes }
            } else { modelContext.insert(JournalEntry(bytes: bytes, key: Self.draftKey)) }
        } else if let existing { modelContext.delete(existing) }
    }

    func saveDrafts(_ drafts: CaptureDrafts?, revision: Int) throws {
        guard revision > lastDraftRevision else { return }
        try Task.checkCancellation()
        do {
            if !draftLayoutReady { try separateInlineDrafts() }
            try writeDrafts(drafts)
            try Task.checkCancellation()
            try modelContext.save()
            lastDraftRevision = revision
            draftLayoutReady = true
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func save(_ journal: Journal, revision: Int) throws {
        guard revision > lastRevision else { return }
        let photoIDs = Set((journal.photos ?? []).map(\.id))
        let empty =
            journal.tasks.isEmpty && journal.events.isEmpty && journal.reports.isEmpty && journal.sessions.isEmpty
            && (journal.stimulantIntakes ?? []).isEmpty && (journal.stimulantBloodSamples ?? []).isEmpty
            && photoIDs.isEmpty && (journal.practices ?? []).isEmpty && (journal.energyExpectations ?? []).isEmpty
            && (journal.goals ?? []).isEmpty && (journal.templates ?? []).isEmpty && (journal.energyCorrections ?? []).isEmpty
            && (journal.timeBlocks ?? []).isEmpty && (journal.customEnergyActivities ?? []).isEmpty && (journal.energyActivityLogs ?? []).isEmpty
            && (journal.taskSkips ?? []).isEmpty
            && (journal.forecastHistory ?? []).isEmpty && journal.captureDrafts == nil && journal.active == nil && !journal.starterAvailable
        do {
            let current = try entry("journal")
            if current != nil, lastGoodJournal == nil { _ = try loadSnapshot() }
            var cache = photoCache
            func encode(_ snapshot: Journal) throws -> LocalPictures.Document {
                try LocalPictures.encode(snapshot, cache: &cache) { id, jpeg in
                    modelContext.insert(JournalEntry(bytes: jpeg, key: LocalPictures.key(id)))
                }
            }
            var retained: Set<UUID> = []
            let prior = try entry("previous")
            if empty {
                if let prior { modelContext.delete(prior) }
            } else if var previous = lastGoodJournal, current != nil {
                // Both journal revisions share the single device-local draft row.
                previous.captureDrafts = nil
                // A deleted picture must also disappear from the recovery copy.
                previous.photos?.removeAll { !photoIDs.contains($0.id) }
                let recovery = try encode(previous)
                retained = recovery.payloadIDs
                if let prior { prior.bytes = recovery.bytes }
                else { modelContext.insert(JournalEntry(bytes: recovery.bytes, key: "previous")) }
            }
            var body = journal
            body.captureDrafts = nil
            let document = try encode(body)
            retained.formUnion(document.payloadIDs)
            if let current { current.bytes = document.bytes }
            else { modelContext.insert(JournalEntry(bytes: document.bytes)) }

            // Fetch only row keys. Editing a note does not read or rewrite image bytes.
            let retainedKeys = Set(retained.map(LocalPictures.key))
            var query = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.key.starts(with: "picture/") })
            query.propertiesToFetch = [\.key]
            for row in try modelContext.fetch(query) where !retainedKeys.contains(row.key) {
                modelContext.delete(row)
            }
            // Committing a capture and clearing its draft is one transaction.
            // A later standalone edit can reach this actor before an older task save.
            if revision > lastDraftRevision { try writeDrafts(journal.captureDrafts) }
            try modelContext.save()
            lastDraftRevision = max(lastDraftRevision, revision)
            draftLayoutReady = true
            lastRevision = revision
            lastGoodJournal = body
            photoCache = cache.filter { photoIDs.contains($0.key) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
