import Foundation
import PulseEngine

enum JournalArchive {
    static let version = 1
    static let maxBytes = 64 * 1024 * 1024

    enum Failure: LocalizedError {
        case newerVersion, invalid, tooLarge, missing
        var errorDescription: String? {
            switch self {
            case .newerVersion: "This journal uses a newer Pulse format. Update Pulse before opening it."
            case .invalid: "This file does not contain a valid Pulse journal."
            case .tooLarge: "This journal exceeds the 64 MB restore limit."
            case .missing: "The selected file could not be read."
            }
        }
    }

    private struct Envelope: Codable {
        var format = "app.pulseplanner.journal"
        var version = JournalArchive.version
        var journal: Journal
    }
    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    static func database(_ journal: Journal) throws -> Data {
        try JSONEncoder().encode(Envelope(journal: journal))
    }

    static func readDatabase(_ data: Data) throws -> Journal {
        try decode(data, using: JSONDecoder())
    }

    static func backup(_ journal: Journal) throws -> Data {
        var copy = journal
        copy.captureDrafts = nil
        copy.importedShares = nil
        copy.localSprintStarts = nil
        copy.reminderImports = nil
        // Paused work can safely resume on a different device or after a reboot.
        copy.active?.pause(now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
        let writer = JSONEncoder()
        writer.dateEncodingStrategy = .iso8601
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try writer.encode(Envelope(journal: copy))
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return data
    }

    static func decodeBackup(_ data: Data) throws -> Journal {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        var journal = try decode(data, using: reader)
        journal.captureDrafts = nil
        journal.importedShares = nil
        journal.localSprintStarts = nil
        journal.reminderImports = nil
        journal.active?.pause(now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
        return journal
    }

    private static func decode(_ data: Data, using reader: JSONDecoder) throws -> Journal {
        let header = try reader.decode(Header.self, from: data)
        let journal: Journal
        if header.format != nil || header.version != nil {
            guard header.format == "app.pulseplanner.journal", let v = header.version, v > 0 else {
                throw Failure.invalid
            }
            guard v <= version else { throw Failure.newerVersion }
            journal = try reader.decode(Envelope.self, from: data).journal
        } else {
            // The original app encoded the journal directly without a schema header.
            journal = try reader.decode(Journal.self, from: data)
        }
        try validate(journal)
        return journal
    }

    static func validate(_ journal: Journal) throws {
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) < 32_000_000_000
        }
        func rating(_ n: Double?) -> Bool { n.map { $0.isFinite && (0...10).contains($0) } ?? true }
        func named(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func unique<T: Identifiable>(_ items: [T]) -> Bool {
            Set(items.map(\.id)).count == items.count
        }
        func validSteps(_ steps: [TaskStep]) -> Bool {
            unique(steps) && steps.allSatisfy { named($0.title) }
        }
        func validTask(_ task: PlanTask) -> Bool {
            named(task.title) && (1...1440).contains(task.minutes) && task.icon?.isValid != false
                && (task.timelineDurations ?? []).allSatisfy { validDate($0.start) && (1...1440).contains($0.minutes) }
                && task.originalMinutes.map { (1...1440).contains($0) } != false
                && task.focusedSeconds.map { $0.isFinite && $0 >= 0 } != false
                && task.resumeNote.map { $0.count <= PlanTask.resumeNoteLimit } != false
                && task.sourceURL.map(SharedCapture.isWebLink) != false
                && task.hasValidRepeatDays
                && task.preparation?.isValid != false
                && rating(task.energyOverride)
                && task.remainingSeconds.isFinite && task.remainingSeconds > 0
                && task.remainingSeconds <= Double(task.minutes) * 60
                && [task.importance, task.effort, task.overwhelm, task.setup].allSatisfy(rating)
                && [
                    task.due, task.after, task.reminder, task.plannedStart, task.preparation?.lastKnownStart, task.createdAt, task.completedAt,
                    task.routineAnchor, task.movedRoutineTimes?.pin?.original, task.movedRoutineTimes?.pin?.moved,
                    task.movedRoutineTimes?.reminder?.original, task.movedRoutineTimes?.reminder?.moved,
                    task.movedRoutineTimes?.availability?.original, task.movedRoutineTimes?.availability?.moved,
                ]
                .compactMap { $0 }.allSatisfy(validDate)
                && (task.routineExceptions ?? []).allSatisfy { $0.occurrence.isValid && validDate($0.start)
                    && $0.occurrence.seriesID == (task.seriesID ?? task.id) }
                && Set((task.routineExceptions ?? []).map(\.occurrence)).count == (task.routineExceptions?.count ?? 0)
                && validSteps(task.steps ?? [])
        }
        func duration(_ seconds: Double) -> Bool { seconds.isFinite && (0...86400).contains(seconds) }
        func validSession(_ session: SessionRecord) -> Bool {
            validDate(session.start) && (session.finishedAt.map(validDate) ?? true) && duration(session.seconds)
                && session.plannedSeconds.map(duration) != false
                && (session.periods ?? []).allSatisfy { validDate($0.start) && duration($0.seconds) }
        }
        let skips = journal.taskSkips ?? []
        guard unique(skips), skips.allSatisfy({ $0.isValid && validDate($0.scheduledStart) && validDate($0.skippedAt) }),
              (journal.automaticTaskStarts ?? [:]).values.allSatisfy(validDate) else { throw Failure.invalid }
        let intakes = journal.stimulantIntakes ?? [], blood = journal.stimulantBloodSamples ?? []
        guard unique(intakes), unique(blood), intakes.allSatisfy(\.isValid), blood.allSatisfy(\.isValid) else { throw Failure.invalid }
        let windows = journal.timeBlocks ?? []
        guard unique(windows), windows.allSatisfy({ $0.title.count <= 140 && $0.hasValidDates && ($0.kind == .focus || $0.boostActivityID == nil) })
        else { throw Failure.invalid }
        let photos = journal.photos ?? []
        let expectations = journal.energyExpectations ?? []
        let forecasts = journal.forecastHistory ?? []
        guard forecasts.count <= 120, unique(forecasts), forecasts.allSatisfy(\.isValid) else { throw Failure.invalid }
        guard expectations.count <= 512, unique(expectations), expectations.allSatisfy(\.isValid) else { throw Failure.invalid }
        guard journal.inboxUndo?.isValid != false, (journal.energyCorrections ?? []).allSatisfy({ validDate($0.date) && rating($0.score) }),
            photos.count <= 300, unique(photos), photos.reduce(0, { $0 + $1.jpeg.count }) <= JournalPhoto.budget,
            photos.allSatisfy({ named($0.title) && validDate($0.date) && $0.isSafeImage })
        else { throw Failure.invalid }
        let ids = Set(journal.tasks.map(\.id))
        let practices = journal.practices ?? []
        guard unique(practices), practices.allSatisfy({ practice in
            named(practice.title) && (1...7).contains(practice.targetDays)
                && (1...1440).contains(practice.minutes) && practice.logs.allSatisfy { validDate($0.date) }
        }) else { throw Failure.invalid }
        let customActivities = journal.customEnergyActivities ?? []
        let activityLogs = journal.energyActivityLogs ?? []
        let presetIDs = Set(EnergyActivity.presets.map(\.id))
        guard unique(customActivities), customActivities.allSatisfy({ $0.isValid && !presetIDs.contains($0.id) }),
              unique(activityLogs), activityLogs.allSatisfy(\.isValid) else { throw Failure.invalid }
        let templates = journal.templates ?? []
        if let drafts = journal.captureDrafts?.sprints {
            guard drafts.count <= CaptureDrafts.sprintLimit, drafts.values.allSatisfy({
                !$0.text.isEmpty && $0.text.utf8.count <= CaptureDrafts.sprintByteLimit && validDate($0.updatedAt)
            }) else { throw Failure.invalid }
        }
        let draftItems = journal.captureDrafts?.reviewed ?? []
        guard unique(draftItems), draftItems.allSatisfy(validTask) else { throw Failure.invalid }
        let goals = journal.goals ?? []
        let votes = journal.votes ?? []
        guard (0...480).contains(journal.limit), unique(journal.tasks), unique(journal.events),
            unique(journal.reports), unique(journal.sessions), unique(templates), unique(goals),
            unique(votes),
            journal.tasks.allSatisfy({ validTask($0) && $0.dependency.map(ids.contains) != false }),
            templates.allSatisfy(validTask),
            goals.allSatisfy({ named($0.title) && validSteps($0.milestones) }),
            votes.allSatisfy({ validDate($0.date) }),
            journal.wrapUpMinute.map({ (0..<1440).contains($0) }) != false,
            journal.planningStartHour.map({ (0..<24).contains($0) }) != false,
            journal.tuning.map({ validDate($0.date) && rating($0.manualCapacity) }) != false,
            journal.restDate.map(validDate) != false,
            journal.recovery.map({ validDate($0.start) && validDate($0.end) && $0.start <= $0.end })
                != false,
            journal.reminderPreferences.map({ prefs in
                [prefs.morningMinute, prefs.quietStart, prefs.quietEnd].allSatisfy {
                    (0..<1440).contains($0)
                }
            }) != false,
            journal.events.allSatisfy({
                named($0.title) && validDate($0.start) && validDate($0.end) && $0.start < $0.end
            }),
            journal.reports.allSatisfy({
                validDate($0.date)
                    && [$0.energy, $0.interest, $0.clarity, $0.sleep, $0.workload, $0.stress].allSatisfy(
                        rating)
            }),
            journal.sessions.allSatisfy(validSession)
        else { throw Failure.invalid }

        let parents = Dictionary(uniqueKeysWithValues: journal.tasks.map { ($0.id, $0.dependency) })
        var visited = Set<UUID>()
        for id in ids where !visited.contains(id) {
            var path = Set<UUID>()
            var next: UUID? = id
            while let item = next, !visited.contains(item) {
                guard path.insert(item).inserted else { throw Failure.invalid }
                next = parents[item] ?? nil
            }
            visited.formUnion(path)
        }
        if let active = journal.active {
            let validOwner = active.isOpenSprint
                ? active.sessionID == active.taskID && active.stepID == nil && !ids.contains(active.taskID)
                : ids.contains(active.taskID)
            guard validOwner, active.target.isFinite, active.target > 0,
                active.target <= 86400,
                active.accumulated.isFinite, (0...active.target).contains(active.accumulated),
                validDate(active.started),
                active.wallAnchor.map(validDate) ?? true, active.tickAnchor?.isFinite != false
            else { throw Failure.invalid }
        }
    }

    static func csv(_ journal: Journal, includePrivateNotes: Bool) -> Data {
        func field(_ text: String) -> String {
            // Spreadsheet programs evaluate formulas even when the CSV cell is quoted.
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
            let safe = first.map { "=+-@".contains($0) } == true ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let iso = ISO8601DateFormatter()
        var rows = [
            [
                "kind", "date", "title", "energy", "clarity", "interest", "sleep", "workload",
                "felt_worse_after_activity", "focus_seconds", "stress", "fatigue_note",
            ]
        ]
        for r in journal.reports.sorted(by: { $0.date < $1.date }) {
            var row = [
                "check-in", iso.string(from: r.date), "", String(r.energy), String(r.clarity),
                String(r.interest),
                r.sleep.map { String($0) } ?? "", r.workload.map { String($0) } ?? "",
                includePrivateNotes ? r.feltWorseAfterActivity.map { String($0) } ?? "" : "", "", "", "",
            ]
            if includePrivateNotes {
                row[10] = r.stress.map { String($0) } ?? ""
                row[11] = r.fatigueNote ?? ""
            }
            rows.append(row)
        }
        for s in journal.sessions.sorted(by: { $0.start < $1.start }) {
            rows.append([
                "focus", iso.string(from: s.start), s.title, "", "", "", "", "", "", String(s.seconds), "",
                "",
            ])
        }
        return Data(
            (rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
