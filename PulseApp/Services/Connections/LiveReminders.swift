import Combine
import EventKit
import PulseEngine
import SwiftUI

@MainActor @Observable
final class LiveReminderSelection {
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        sources = Set(defaults.stringArray(forKey: "automaticReminderLists") ?? [])
    }

    var sources: Set<String> {
        didSet { defaults.set(sources.sorted(), forKey: "automaticReminderLists") }
    }
}

struct ReminderImportRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable { case open, missing, completed }
    var listID: String
    var itemID: String
    var accountKey: UUID?
    var titleHash: UUID
    var due: Date?
    var status: Status

    init(_ reminder: ReminderCandidate) {
        listID = reminder.listID
        itemID = reminder.itemID
        accountKey = reminder.accountKey
        titleHash = CalendarBridge.stableID(reminder.title)
        due = reminder.due
        status = reminder.completed ? .completed : .open
    }
}

extension Journal {
    /// Keep local deletions in the import ledger, so the next refresh cannot undo them.
    @discardableResult
    mutating func importReminders(_ reminders: [ReminderCandidate], missing: Set<String> = [], manual: Bool = false) -> Bool {
        var receipts = reminderImports ?? [:]
        let native = Dictionary(grouping: receipts.keys, by: { receipts[$0]!.itemID })
        let external = Dictionary(grouping: receipts.keys, by: { receipts[$0]!.accountKey })
        let incoming = Dictionary(grouping: reminders, by: \.accountKey)
        var positions = Dictionary(uniqueKeysWithValues: tasks.indices.map { (tasks[$0].id, $0) })
        let protected = Set((photos ?? []).map(\.taskID)).union(taskOrder ?? []).union([nextTaskID, active?.taskID].compactMap { $0 })
        var changed = false
        var seen = Set<String>()
        for reminder in reminders where seen.insert(reminder.itemID).inserted {
            let receipt = ReminderImportRecord(reminder)
            var id = native[reminder.itemID]?.first ?? reminder.id
            if native[reminder.itemID] == nil, let key = reminder.accountKey,
               incoming[key]?.count == 1, let matches = external[key], matches.count == 1,
               let prior = receipts[matches[0]], prior.status != .completed {
                id = matches[0]
            } else if let collision = receipts[id], collision.itemID != reminder.itemID {
                id = CalendarBridge.stableID("reminder-instance|" + reminder.itemID)
            }
            let previous = receipts[id]
            guard previous != nil || !reminder.completed else { continue }
            if let index = positions[id], let previous, !tasks[index].done, tasks[index].archived != true {
                var task = tasks[index]
                var baseline = PlanTask(task.title, minutes: 15, category: .personal, id: task.id)
                baseline.createdAt = task.createdAt
                baseline.due = previous.due
                baseline.inboxOnly = previous.due == nil ? true : nil
                let originalTitle = CalendarBridge.stableID(task.title) == previous.titleHash
                let untouched = originalTitle && task == baseline && !protected.contains(id)
                if reminder.completed {
                    if active?.taskID == id { continue }
                    if previous.status != .completed && untouched {
                        task.done = true
                        task.completedAt = .now
                    }
                } else {
                    if originalTitle { task.title = reminder.title }
                    if task.due == previous.due && task.due != reminder.due {
                        task.due = reminder.due
                        if reminder.due != nil { task.inboxOnly = nil }
                        else if untouched { task.inboxOnly = true }
                    }
                }
                if task != tasks[index] {
                    tasks[index] = task
                    changed = true
                }
            } else if positions[id] == nil, !reminder.completed, previous == nil || manual {
                var task = PlanTask(reminder.title, minutes: 15, category: .personal, id: id)
                task.due = reminder.due
                task.inboxOnly = reminder.due == nil ? true : nil
                positions[id] = tasks.count
                tasks.append(task)
                starterAvailable = false
                changed = true
            }
            if previous != receipt {
                receipts[id] = receipt
                changed = true
            }
        }
        for item in missing.subtracting(seen) {
            for id in native[item] ?? [] where receipts[id]?.status == .open {
                receipts[id]?.status = .missing
                changed = true
            }
        }
        if changed { reminderImports = receipts }
        return changed
    }
}

extension CalendarBridge {
    func importSnapshot(sources: Set<String>, tracked: [ReminderImportRecord],
                        inspectCompletionsFor localOpenItems: Set<String>? = nil) async throws -> ([ReminderCandidate], Set<String>) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw ConnectionError.permission }
        let lists = store.calendars(for: .reminder).filter { sources.contains($0.calendarIdentifier) }
        let available = Set(lists.map(\.calendarIdentifier))
        var reminders = try await Self.incompleteReminders(in: lists, store: store)
        let openIDs = Set(reminders.map(\.itemID))
        let openExternalKeys = Set(reminders.compactMap(\.accountKey))
        var missing = Set<String>()
        for record in tracked where available.contains(record.listID) && !openIDs.contains(record.itemID) {
            // A newly materialized recurring reminder may share the completed item's external identifier.
            // Inspect that prior native item even if the user already finished its Pulse task.
            let sharesExternalID = record.accountKey.map(openExternalKeys.contains) == true
            guard localOpenItems?.contains(record.itemID) != false || sharesExternalID else { continue }
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw ConnectionError.permission }
            if let item = store.calendarItem(withIdentifier: record.itemID) as? EKReminder,
               let candidate = Self.candidate(item), available.contains(candidate.listID) {
                reminders.append(candidate)
            } else {
                missing.insert(record.itemID)
            }
        }
        return (reminders, missing)
    }
}

extension Workspace {
    func refreshLiveReminders() async {
        let sources = liveReminders.sources
        guard !sources.isEmpty, ready, !restoring, !isDemo, !PrivacySession.connectionsLocked,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let epoch = journalEpoch
        let openIDs = Set(journal.tasks.lazy.filter { !$0.done && $0.archived != true }.map(\.id))
        let records = journal.reminderImports ?? [:]
        let tracked = records.values.filter { $0.status == .open && sources.contains($0.listID) }
        let localOpenItems = Set(records.compactMap { openIDs.contains($0.key) ? $0.value.itemID : nil })
        guard let (reminders, missing) = try? await reminderReader.importSnapshot(
            sources: sources, tracked: tracked, inspectCompletionsFor: localOpenItems
        ),
              !Task.isCancelled, sources == liveReminders.sources, epoch == journalEpoch,
              ready, !restoring, !isDemo, !PrivacySession.connectionsLocked,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        var updated = journal
        guard updated.importReminders(reminders, missing: missing) else { return }
        change { journal in
            journal.tasks = updated.tasks
            journal.reminderImports = updated.reminderImports
            journal.starterAvailable = updated.starterAvailable
        }
    }
}

struct LiveReminderUpdates: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.scenePhase) private var phase
    @State private var revision = 0

    private struct Request: Equatable {
        let sources: Set<String>
        let active: Bool
        let focus: UUID?
        let day: Date
        let revision: Int
    }

    func body(content: Content) -> some View {
        let sources = privacy.lockConnections || workspace.isDemo || workspace.restoring ? [] : workspace.liveReminders.sources
        let request = Request(sources: sources, active: workspace.ready && phase == .active, focus: workspace.journal.active?.taskID,
                              day: Calendar.current.startOfDay(for: workspace.now), revision: revision)
        content
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                .debounce(for: .milliseconds(350), scheduler: RunLoop.main)) { _ in
                    if request.active && !sources.isEmpty { revision += 1 }
                }
            .task(id: request) {
                if request.active && !sources.isEmpty { await workspace.refreshLiveReminders() }
            }
    }
}
