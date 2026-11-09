import Combine
import EventKit
import PulseEngine
import SwiftUI

@MainActor @Observable
final class LiveCalendarSelection {
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        source = defaults.string(forKey: "liveCalendarID")
    }

    private(set) var revision: UInt64 = 0

    var source: String? {
        didSet {
            if oldValue != source {
                revision &+= 1
                defaults.removeObject(forKey: "liveCalendarCopies")
            }
            defaults.set(source, forKey: "liveCalendarID")
        }
    }
    var snapshotIDs: Set<UUID> {
        get { Set((defaults.stringArray(forKey: "liveCalendarCopies") ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "liveCalendarCopies") }
    }
}

/// EventKit objects stay on this actor. Only the planning fields leave it.
actor LiveCalendarReader {
    private lazy var store = EKEventStore()

    struct Snapshot: Sendable {
        let events: [Commitment]
        let matchedIDs: Set<UUID>
    }

    func events(in source: String, from date: Date, journal: [Commitment], published: Set<String>) throws -> Snapshot {
        guard store.calendar(withIdentifier: source) != nil else { return Snapshot(events: [], matchedIDs: []) }
        let items = try CalendarBridge.events(in: store, calendarID: source, from: date, excluding: published)
        let imports = journal.filter { $0.id.uuid.6 >> 4 == 8 }
        return Snapshot(events: items.map(\.commitment), matchedIDs: Set(items.compactMap { $0.matchingCopy(in: imports) }))
    }

    nonisolated static func merging(_ live: [Commitment], with journal: [Commitment], trackedCopies: Set<UUID>) -> [Commitment] {
        guard !live.isEmpty || !trackedCopies.isEmpty else { return journal }
        let liveIDs = trackedCopies.union(live.map(\.id))
        return journal.filter { !liveIDs.contains($0.id) } + live
    }
}

extension Workspace {
    var calendarReadyForStart: Bool {
        guard !isDemo, !PrivacySession.connectionsLocked, liveCalendar.source != nil,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return true }
        return hasCurrentCalendarSnapshot
    }

    @discardableResult func refreshLiveCalendar() async -> Bool {
        calendarReadGeneration &+= 1
        let generation = calendarReadGeneration
        let selection = liveCalendar.revision
        guard ready, !restoring, !isDemo, !PrivacySession.connectionsLocked,
              let source = liveCalendar.source,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            replaceCalendarEvents([])
            return true
        }
        let epoch = journalEpoch
        let published = Set(journal.connections?.published.values.map { $0 } ?? [])
        let snapshot = try? await calendarReader.events(in: source, from: .now, journal: journal.events, published: published)
        guard !Task.isCancelled, generation == calendarReadGeneration, selection == liveCalendar.revision,
              epoch == journalEpoch, liveCalendar.source == source,
              !PrivacySession.connectionsLocked, !isDemo, !restoring else { return false }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            replaceCalendarEvents([])
            return false
        }
        guard let snapshot else {
            // On a failed read retain the last authoritative busy times. A first read can still
            // use locally authored commitments, without mistaking stale copies for live events.
            if !calendarReadyForStart {
                replaceCalendarEvents([], source: source, snapshotIDs: liveCalendar.snapshotIDs)
            }
            return false
        }
        let savedIDs = Set(journal.events.map(\.id))
        let copies = liveCalendar.snapshotIDs.union(snapshot.matchedIDs).union(snapshot.events.map(\.id)).intersection(savedIDs)
        if copies != liveCalendar.snapshotIDs { liveCalendar.snapshotIDs = copies }
        replaceCalendarEvents(snapshot.events, source: source, snapshotIDs: copies)
        return true
    }
}

struct LiveCalendarUpdates: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.scenePhase) private var phase
    @State private var revision = 0

    private struct Request: Equatable {
        let source: String?
        let selection: UInt64
        let active: Bool
        let day: Date
        let revision: Int
    }

    func body(content: Content) -> some View {
        let source = !privacy.lockConnections && !workspace.isDemo && !workspace.restoring ? workspace.liveCalendar.source : nil
        let request = Request(source: source, selection: workspace.liveCalendar.revision, active: phase == .active,
                              day: Calendar.current.startOfDay(for: workspace.now), revision: revision)
        content
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                .debounce(for: .milliseconds(350), scheduler: RunLoop.main)) { _ in
                    if source != nil && phase == .active { revision += 1 }
            }
            .task(id: request) {
                guard source != nil else {
                    workspace.replaceCalendarEvents([])
                    return
                }
                if request.active { await workspace.refreshLiveCalendar() }
            }
    }
}
