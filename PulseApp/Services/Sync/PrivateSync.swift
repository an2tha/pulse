import CryptoKit
import Foundation
import PulseEngine
import Security
import SwiftUI

/// Only the user-selected journal collections cross device boundaries. Permission
/// grants, integrations, the running timer and notification state are device local.
struct SharedJournal: Codable, Equatable, Sendable {
    private var fieldVersion: Int?
    var tasks: [PlanTask]
    var events: [Commitment]
    var reports: [CheckIn]
    var sessions: [SessionRecord]
    var goals: [PersonalGoal]?
    var templates: [PlanTask]?
    var practices: [WeeklyPractice]?
    var customEnergyActivities: [EnergyActivity]?
    var energyActivityLogs: [EnergyActivityLog]?
    var timeBlocks: [WeeklyTimeBlock]?

    init(_ journal: Journal) {
        fieldVersion = 6
        tasks = journal.tasks
        events = journal.events
        reports = journal.reports
        sessions = journal.sessions
        goals = journal.goals
        templates = journal.templates
        practices = journal.practices
        customEnergyActivities = journal.customEnergyActivities
        energyActivityLogs = journal.energyActivityLogs
        timeBlocks = journal.timeBlocks
    }
    func applying(to original: Journal) throws -> Journal {
        var journal = original
        guard journal.active == nil else { throw VaultError.active }
        guard (1...6).contains(fieldVersion ?? 1) else { throw VaultError.newerJournal }
        if (fieldVersion ?? 1) >= 6 {
            journal.customEnergyActivities = customEnergyActivities
            journal.energyActivityLogs = energyActivityLogs
            journal.timeBlocks = timeBlocks
        }
        journal.tasks = tasks
        let savedRoutines = original.tasks.filter { !$0.done && $0.archived != true && !($0.routineExceptions ?? []).isEmpty }
        if !savedRoutines.isEmpty {
            for index in journal.tasks.indices where journal.tasks[index].routineExceptions == nil {
                let incoming = journal.tasks[index]
                if let prior = savedRoutines.first(where: { ($0.seriesID ?? $0.id) == (incoming.seriesID ?? incoming.id) }) {
                    journal.tasks[index].inheritExceptions(from: prior, at: .now)
                }
            }
        }
        journal.events = events
        journal.reports = reports
        journal.sessions = sessions
        // Session history is shareable with version 5 peers. A round trip through
        // one preserves the task-free UUID pair even when it drops the new field.
        let taskIDs = Set(tasks.map(\.id))
        for index in journal.sessions.indices where !taskIDs.contains(journal.sessions[index].taskID) {
            journal.sessions[index].recoverOpenSprintIdentity()
        }
        journal.goals = goals
        journal.templates = templates
        if (fieldVersion ?? 1) < 5 {
            let prior = Dictionary(uniqueKeysWithValues: original.tasks.map { ($0.id, $0) })
            let series = Dictionary(grouping: original.tasks.filter { $0.repeatDays != nil && !$0.done && $0.archived != true },
                                    by: { $0.seriesID ?? $0.id })
            for index in journal.tasks.indices where journal.tasks[index].repeated == .daily && journal.tasks[index].repeatDays == nil {
                let incoming = journal.tasks[index]
                if let same = prior[incoming.id] {
                    journal.tasks[index].repeatDays = same.repeatDays
                } else if let id = incoming.seriesID {
                    journal.tasks[index].repeatDays = series[id]?.first?.repeatDays
                }
            }
            if var incoming = journal.templates {
                let saved = Dictionary(uniqueKeysWithValues: (original.templates ?? []).map { ($0.id, $0) })
                for index in incoming.indices where incoming[index].repeated == .daily && incoming[index].repeatDays == nil {
                    incoming[index].repeatDays = saved[incoming[index].id]?.repeatDays
                }
                journal.templates = incoming
            }
        }
        if (fieldVersion ?? 1) < 4 {
            let links = Dictionary(uniqueKeysWithValues: original.tasks.compactMap { task in
                task.preparation.map { (task.id, $0) }
            })
            for index in journal.tasks.indices where journal.tasks[index].preparation == nil {
                journal.tasks[index].preparation = links[journal.tasks[index].id]
            }
        }
        if (fieldVersion ?? 1) < 3 {
            let held = Set(original.tasks.filter(\.isInboxOnly).map(\.id))
            for index in journal.tasks.indices where held.contains(journal.tasks[index].id) && !journal.tasks[index].hasSchedulingInstruction {
                journal.tasks[index].inboxOnly = true
            }
        }
        if (fieldVersion ?? 1) < 2 {
            let saved = Dictionary(uniqueKeysWithValues: original.tasks.map { ($0.id, $0) })
            let series = Dictionary(grouping: original.tasks.filter { !$0.done && $0.archived != true && $0.availability != nil },
                                    by: { $0.seriesID ?? $0.id })
            for index in journal.tasks.indices {
                let incoming = journal.tasks[index]
                let prior = saved[incoming.id]
                if incoming.availability == nil {
                    let predecessor = incoming.seriesID.flatMap { id in series[id]?.first { $0.repeated == incoming.repeated } }
                    journal.tasks[index].availability = prior != nil ? prior?.availability : predecessor?.availability
                }
                if incoming.capturedDuringSessionID == nil {
                    journal.tasks[index].capturedDuringSessionID = prior?.capturedDuringSessionID
                }
            }
            if var incoming = journal.templates {
                let saved = Dictionary(uniqueKeysWithValues: (original.templates ?? []).map { ($0.id, $0) })
                for index in incoming.indices where incoming[index].availability == nil {
                    incoming[index].availability = saved[incoming[index].id]?.availability
                }
                journal.templates = incoming
            }
            let savedSessions = Dictionary(uniqueKeysWithValues: original.sessions.map { ($0.id, $0) })
            for index in journal.sessions.indices where journal.sessions[index].finishedAt == nil {
                journal.sessions[index].finishedAt = savedSessions[journal.sessions[index].id]?.finishedAt
            }
        }
        if let practices {
            journal.practices = practices
        } else if !(original.practices ?? []).isEmpty {
            // Older peers cannot carry practice settings or their task links.
            let linkedTasks = Dictionary(uniqueKeysWithValues: original.tasks.filter { $0.practiceID != nil }.map { ($0.id, $0) })
            for index in journal.tasks.indices {
                let incoming = journal.tasks[index]
                guard let previous = linkedTasks[incoming.id], let practiceID = previous.practiceID else { continue }
                journal.tasks[index].practiceID = incoming.practiceID ?? practiceID
                if incoming.done, !previous.done, let date = incoming.completedAt,
                   let practiceIndex = journal.practices?.firstIndex(where: { $0.id == practiceID }) {
                    journal.practices?[practiceIndex].log(at: date, taskID: incoming.id)
                }
            }
        }
        if !tasks.contains(where: { $0.id == journal.nextTaskID }) { journal.nextTaskID = nil }
        journal.taskOrder = journal.taskOrder?.filter { id in tasks.contains { $0.id == id } }
        journal.starterAvailable = false
        try JournalArchive.validate(journal)
        return journal
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= JournalArchive.maxBytes else { throw VaultError.size }
        return data
    }
}

enum VaultError: LocalizedError {
    case key, folder, format, exists, missing, changed, active, size, locked, newerJournal
    var errorDescription: String? {
        switch self {
        case .key: "Enter the 44-character recovery key for this folder."
        case .folder: "Pulse couldn’t open this folder. Reconnect it from Files."
        case .format:
            "This encrypted revision cannot be authenticated. Check the recovery key and let Files finish downloading."
        case .exists: "An encrypted journal already exists here. Join it with its recovery key."
        case .missing: "No Pulse Sync folder was found at this location."
        case .changed: "A revision arrived during your review. Refresh and choose again."
        case .active: "Sync resumes after the current focus session."
        case .size: "This revision exceeds the supported journal size."
        case .locked: "The recovery key could not be accessed in this device’s Keychain."
        case .newerJournal: "Update Pulse to open this journal revision."
        }
    }
}

@MainActor private enum VaultKey {
    @MainActor static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.pulseplanner.sync",
        kSecAttrAccount as String: "vault-key", kSecAttrSynchronizable as String: false,
    ]
    static func write(_ key: Data) throws {
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        if result == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary) == errSecSuccess
            else { throw VaultError.locked }
        } else if result != errSecSuccess {
            throw VaultError.locked
        }
    }
    static func read() throws -> Data {
        var item = query
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let key = result as? Data,
            key.count == 32
        else { throw VaultError.locked }
        return key
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

struct VaultLink: Codable, Sendable {
    var bookmark: Data
    var revision: UUID?
    var digest: Data?
}
struct VaultHead: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let content: SharedJournal
}
enum VaultResult: Sendable {
    case linked(UUID, Data)
    case pull(VaultHead, Data)
    case conflict([VaultHead])
}
enum VaultChoice: Sendable {
    case normal, create
    case keepLocal(Set<UUID>)
    case take(UUID, Set<UUID>)
}

/// Revisions have unique names and are immutable. Simultaneous offline writers
/// create sibling heads. Resolving them writes a new authenticated revision with
/// both parents. No device ever replaces or deletes another device's file.
enum VaultIO {
    private struct Manifest: Codable {
        let version: Int
        let id: UUID
        let created: Date
        let parents: [UUID]
    }
    static func exchange(link: VaultLink, key: Data, local: SharedJournal, choice: VaultChoice) throws -> VaultResult {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: link.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw VaultError.folder }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = url.appendingPathComponent("Pulse Sync", isDirectory: true)
        let manager = FileManager.default
        var coordinatorError: NSError?
        var result: Result<VaultResult, Error>?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinatorError) {
            location in
            result = Result {
                try Task.checkCancellation()
                if !manager.fileExists(atPath: location.path) {
                    guard case .create = choice else { throw VaultError.missing }
                    try manager.createDirectory(at: location, withIntermediateDirectories: false)
                }
                let localBytes = try local.encoded()
                let digest = Data(SHA256.hash(data: localBytes))
                let names = try manager.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
                let rootKey = SymmetricKey(data: key)
                let manifestKey = HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: rootKey,
                    info: Data("PulseSync1/manifest".utf8), outputByteCount: 32)
                var manifests: [UUID: Manifest] = [:]
                var parents = Set<UUID>()
                func availableBytes(_ file: URL, limit: Int) throws -> Data {
                    if manager.isUbiquitousItem(at: file) {
                        try manager.startDownloadingUbiquitousItem(at: file)
                    }
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard let size, (0...limit).contains(size) else { throw VaultError.size }
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    guard data.count <= limit else { throw VaultError.size }
                    return data
                }
                for entry in names {
                    var name = entry.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
                    guard name.hasSuffix(".pulselink") else { continue }
                    guard let id = UUID(uuidString: String(name.dropLast(".pulselink".count))), manifests[id] == nil
                    else { throw VaultError.format }
                    let signed = try availableBytes(location.appendingPathComponent(name), limit: 1024 * 1024)
                    guard signed.count > 32 else { throw VaultError.format }
                    let raw = signed.dropLast(32)
                    guard
                        HMAC<SHA256>.isValidAuthenticationCode(
                            signed.suffix(32), authenticating: raw, using: manifestKey)
                    else { throw VaultError.format }
                    let parsed = try JSONDecoder().decode(Manifest.self, from: raw)
                    guard parsed.version == 1, parsed.id == id, !parsed.parents.contains(id) else {
                        throw VaultError.format
                    }
                    manifests[id] = parsed
                    parents.formUnion(parsed.parents)
                }
                let headIDs = Set(manifests.keys).subtracting(parents)
                func descends(_ id: UUID, from base: UUID) -> Bool {
                    var queue = [id]
                    var seen = Set<UUID>()
                    while let next = queue.popLast() {
                        if next == base { return true }
                        if seen.insert(next).inserted { queue.append(contentsOf: manifests[next]?.parents ?? []) }
                    }
                    return false
                }
                func load(_ id: UUID) throws -> VaultHead {
                    guard let manifest = manifests[id] else { throw VaultError.changed }
                    let file = location.appendingPathComponent(id.uuidString + ".pulsevault")
                    let encrypted = try availableBytes(file, limit: JournalArchive.maxBytes + 512)
                    let opened: Data
                    do {
                        opened = try AES.GCM.open(
                            AES.GCM.SealedBox(combined: encrypted), using: rootKey,
                            authenticating: Data(("PulseSync1/" + id.uuidString).utf8))
                    } catch { throw VaultError.format }
                    let decoded = try JSONDecoder().decode(SharedJournal.self, from: opened)
                    _ = try decoded.applying(to: Journal())
                    return VaultHead(id: id, date: manifest.created, content: decoded)
                }
                func append(_ bytes: Data) throws -> UUID {
                    try Task.checkCancellation()
                    let id = UUID()
                    guard
                        let sealed = try AES.GCM.seal(
                            bytes, using: rootKey, authenticating: Data(("PulseSync1/" + id.uuidString).utf8)
                        ).combined
                    else { throw VaultError.format }
                    let metadata = try JSONEncoder().encode(
                        Manifest(version: 1, id: id, created: .now, parents: Array(headIDs)))
                    let signature = HMAC<SHA256>.authenticationCode(for: metadata, using: manifestKey)
                    let payload = location.appendingPathComponent(id.uuidString + ".pulsevault")
                    try sealed.write(to: payload, options: [.atomic, .completeFileProtection])
                    // Publishing the small authenticated manifest commits this immutable revision.
                    do {
                        try Task.checkCancellation()
                        try (metadata + Data(signature)).write(
                            to: location.appendingPathComponent(id.uuidString + ".pulselink"),
                            options: [.atomic, .completeFileProtection])
                    } catch {
                        try? manager.removeItem(at: payload)
                        throw error
                    }
                    return id
                }
                switch choice {
                case .create:
                    guard manifests.isEmpty, !names.contains(where: { $0.pathExtension == "pulsevault" }) else {
                        throw VaultError.exists
                    }
                    return .linked(try append(localBytes), digest)
                case .keepLocal(let expected):
                    guard headIDs == expected else { throw VaultError.changed }
                    for id in headIDs { _ = try load(id) }
                    return .linked(try append(localBytes), digest)
                case .take(let selected, let expected):
                    guard headIDs == expected else { throw VaultError.changed }
                    let head = try load(selected)
                    let bytes = try head.content.encoded()
                    let id = expected.count == 1 ? selected : try append(bytes)
                    return .pull(
                        VaultHead(id: id, date: head.date, content: head.content), Data(SHA256.hash(data: bytes)))
                case .normal:
                    guard !headIDs.isEmpty else { throw VaultError.missing }
                    if headIDs.count == 1, let only = headIDs.first {
                        if only == link.revision {
                            return .linked(digest == link.digest ? only : try append(localBytes), digest)
                        }
                        let head = try load(only)
                        let remoteDigest = Data(SHA256.hash(data: try head.content.encoded()))
                        if remoteDigest == digest { return .linked(only, digest) }
                        if let base = link.revision, digest == link.digest, descends(only, from: base) {
                            return .pull(head, remoteDigest)
                        }
                        return .conflict([head])
                    }
                    return .conflict(try headIDs.map(load).sorted { $0.date > $1.date })
                }
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw VaultError.folder }
        return try result.get()
    }
}

@MainActor @Observable final class PrivateSync {
    static let shared = PrivateSync()
    private static let storeKey = "pulse.encrypted-sync.v1"
    private var link: VaultLink?
    private(set) var status = "Disconnected"
    private(set) var conflicts: [VaultHead] = []
    private(set) var busy = false
    private var generation = UUID()
    private var pending: Task<Void, Never>?
    private var transfer: Task<VaultResult, Error>?
    private weak var owner: Workspace?
    var connected: Bool { link != nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey) {
            link = try? JSONDecoder().decode(VaultLink.self, from: data)
        }
        if link != nil { status = "Connected" }
    }
    static func newKey() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() } }
    func recoveryKey() throws -> String { try VaultKey.read().base64EncodedString() }
    func disconnect() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        transfer?.cancel()
        transfer = nil
        link = nil
        conflicts = []
        busy = false
        owner = nil
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        VaultKey.remove()
        status = "Disconnected"
    }
    func connect(folder: URL, code: String, creating: Bool, store: Workspace) async throws {
        guard store.canSync, store.ready, !store.restoring,
            !PrivacySession.connectionsLocked, !connected, !busy else { throw VaultError.changed }
        guard let key = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32
        else { throw VaultError.key }
        guard store.journal.active == nil else { throw VaultError.active }
        let scope = folder.startAccessingSecurityScopedResource()
        defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let fresh = VaultLink(bookmark: bookmark)
        busy = true
        owner = store
        let ticket = generation
        defer { if generation == ticket { transfer = nil; busy = false } }
        let local = SharedJournal(store.journal)
        try await store.saveForShortcut()
        guard generation == ticket, !store.restoring, SharedJournal(store.journal) == local else { throw VaultError.changed }
        let job = Task.detached(priority: .utility) {
            try VaultIO.exchange(link: fresh, key: key, local: local, choice: creating ? .create : .normal)
        }
        transfer = job
        let response = try await job.value
        guard generation == ticket else { return }
        try VaultKey.write(key)
        link = fresh
        do {
            try await apply(response, link: fresh, store: store, expected: local, ticket: ticket)
        } catch {
            if generation == ticket { disconnect() }
            throw error
        }
    }
    func journalChanged(_ journal: Journal) {
        guard connected, !PrivacySession.connectionsLocked, let owner, !owner.isDemo, conflicts.isEmpty else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await synchronize(store: owner, choice: .normal)
        }
    }
    func refresh(store: Workspace) {
        guard connected, !PrivacySession.connectionsLocked, !store.isDemo,
            ProcessInfo.processInfo.environment["PULSE_TEST_JOURNAL"] == nil
        else { return }
        owner = store
        Task { await synchronize(store: store, choice: .normal) }
    }
    func keepLocal(store: Workspace) {
        let ids = Set(conflicts.map(\.id))
        Task { await synchronize(store: store, choice: .keepLocal(ids)) }
    }
    func take(_ revision: UUID, store: Workspace) {
        let ids = Set(conflicts.map(\.id))
        Task { await synchronize(store: store, choice: .take(revision, ids)) }
    }
    func manualRefresh(store: Workspace) { Task { await synchronize(store: store, choice: .normal) } }
    private func synchronize(store: Workspace, choice: VaultChoice) async {
        guard store.canSync, store.ready, !store.restoring, !PrivacySession.connectionsLocked, let current = link else { return }
        owner = store
        guard !busy else {
            journalChanged(store.journal)
            return
        }
        guard store.journal.active == nil else {
            status = VaultError.active.localizedDescription
            return
        }
        busy = true
        let ticket = generation
        let local = SharedJournal(store.journal)
        defer { if ticket == generation { transfer = nil; busy = false } }
        do {
            let key = try VaultKey.read()
            try await store.saveForShortcut()
            guard generation == ticket, !store.restoring, SharedJournal(store.journal) == local else { throw VaultError.changed }
            let job = Task.detached(priority: .utility) {
                try VaultIO.exchange(link: current, key: key, local: local, choice: choice)
            }
            transfer = job
            let response = try await job.value
            guard generation == ticket else { return }
            try await apply(response, link: current, store: store, expected: local, ticket: ticket)
        } catch { if generation == ticket { status = error.localizedDescription } }
    }
    private func apply(
        _ response: VaultResult, link original: VaultLink, store: Workspace, expected: SharedJournal, ticket: UUID
    ) async throws {
        guard generation == ticket, store.ready, !store.restoring, !PrivacySession.connectionsLocked else { throw VaultError.changed }
        var current = original
        switch response {
        case .linked(let id, let digest):
            current.revision = id
            current.digest = digest
            conflicts = []
            status = "Up to date"
        case .pull(let head, let digest):
            guard SharedJournal(store.journal) == expected, store.journal.active == nil else {
                conflicts = [head]
                status = "Review incoming changes"
                break
            }
            var replacement = try head.content.applying(to: store.journal)
            replacement.captureDrafts = store.captureDrafts.stored
            // The repository must commit the incoming revision before its
            // digest becomes our baseline for the next outgoing change.
            try await store.restoreJournal(replacement)
            guard generation == ticket, !store.restoring, !PrivacySession.connectionsLocked else { return }
            guard SharedJournal(store.journal) == SharedJournal(replacement) else {
                conflicts = [head]
                status = "Review incoming changes"
                break
            }
            current.revision = head.id
            current.digest = digest
            conflicts = []
            status = "Up to date"
        case .conflict(let heads):
            conflicts = heads
            status = "Choose which journal to keep"
        }
        link = current
        UserDefaults.standard.set(try JSONEncoder().encode(current), forKey: Self.storeKey)
        switch response {
        case .pull(let head, _) where SharedJournal(store.journal) != head.content:
            journalChanged(store.journal)
        case .linked where SharedJournal(store.journal) != expected:
            journalChanged(store.journal)
        default:
            break
        }
    }
}
