 import Darwin
import PulseEngine
import SwiftData
import SwiftUI
import UIKit

enum SessionClock {
    static var tick: Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }
    static let boot: String? = {
        var bytes = [CChar](repeating: 0, count: 128)
        var count = bytes.count
        if sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 {
            return String(
                decoding: bytes.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        // The process token still lets live sessions ignore wall-clock changes.
        return UUID().uuidString
    }()
}

@Observable @MainActor
final class Workspace {
    var journal = Journal()
    var canSync: Bool { !isDemo && ProcessInfo.processInfo.environment["PULSE_TEST_JOURNAL"] == nil }
    let healthController = HealthEnergyController()
    let calendarReader = LiveCalendarReader()
    let liveReminders = LiveReminderSelection(defaults: PrivacySession.preferences)
    let reminderReader = CalendarBridge()
    let liveCalendar: LiveCalendarSelection

    init(liveCalendar: LiveCalendarSelection? = nil) {
        self.liveCalendar = liveCalendar ?? LiveCalendarSelection(defaults: PrivacySession.preferences)
    }
    @ObservationIgnored var calendarReadGeneration: UInt64 = 0
    private(set) var loadedCalendarRevision: UInt64?
    private(set) var loadedCalendarID: String?
    private(set) var calendarEvents: [Commitment] = []

    private var liveSnapshotIDs = Set<UUID>()

    func replaceCalendarEvents(_ events: [Commitment], source: String? = nil, snapshotIDs: Set<UUID> = []) {
        if let source, source != liveCalendar.source { return }
        let revision = source == nil ? nil : liveCalendar.revision
        guard events != calendarEvents || snapshotIDs != liveSnapshotIDs || loadedCalendarID != source || loadedCalendarRevision != revision else { return }
        loadedCalendarRevision = revision
        loadedCalendarID = source
        calendarEvents = events
        liveSnapshotIDs = snapshotIDs
        if ready, !restoring {
            let changed = refreshPreparationLinks()
            let shortened = shortenFocusForCommitments()
            if shortened || changed { persist() }
            if shortened { syncSystemSurfaces() }
        }
        regenerate()
    }

    var hasCurrentCalendarSnapshot: Bool {
        loadedCalendarID == liveCalendar.source && (loadedCalendarID == nil || loadedCalendarRevision == liveCalendar.revision)
    }
    var planningEvents: [Commitment] {
        guard !isDemo, !PrivacySession.connectionsLocked, hasCurrentCalendarSnapshot else { return journal.events }
        return LiveCalendarReader.merging(calendarEvents, with: journal.events, trackedCopies: liveSnapshotIDs)
    }
    private var appliedHealthDay: Date?
    var healthPlanningToday: Bool {
        appliedHealthDay.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
    }
    func useHealthForToday(_ enabled: Bool) {
        appliedHealthDay = enabled && !isDemo && !PrivacySession.connectionsLocked ? .now : nil
        now = .now
    }
    var automaticallyPlanEnergy = false
    @ObservationIgnored var energyCache: (date: Date, revision: Int, sleepTarget: Double?, reports: [CheckIn], corrections: [EnergyCorrection], expectations: [EnergyExpectation], timeline: EnergyTimeline)?
    var ready = false
    var captureDrafts = CaptureDrafts() {
        didSet {
            guard ready, !restoring else { return }
            draftSave?.cancel()
            draftSave = Task {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                flushCaptureDrafts()
            }
        }
    }
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    @ObservationIgnored private var syncPending = false
    var isDemo = false
    private(set) var restoring = false
    var loadFailure: String?
    var notice: String?
    var now = Date.now { didSet { if ready { refreshPlan() } } }
    private(set) var blocks: [Block] = []
    var recentPrep: UUID?
    var latestPrepAttachmentID: UUID?
    var lastTimeMove: TaskTimeMove?
    var lastListCompletion: PlanListCompletion?
    private(set) var taskCompletion: TaskCompletionEvent?
    var pendingCompletionProof: CompletionProofRequest?
    private(set) var projectedRoutines: [UUID: PlanTask] = [:]
    @ObservationIgnored private var projectedDays: (generation: Int, tasks: [Date: Set<UUID>])?

    func hasScheduledTask(_ id: UUID, on day: Date) -> Bool {
        if Calendar.current.isDate(day, inSameDayAs: now), blocks.contains(where: { $0.kind == .task(id) }) {
            return true
        }
        guard let projectedDays, projectedDays.generation == generation else { return false }
        return projectedDays.tasks[Calendar.current.startOfDay(for: day)]?.contains(id) == true
    }

    func timingTask(_ id: UUID) -> PlanTask? {
        if let real = offeredTasks.first(where: { $0.id == id }) { return real.done ? nil : real }
        guard var preview = projectedRoutines[id], let key = preview.occurrence(),
              let owner = journal.tasks.first(where: { $0.owns(key) }) else { return nil }
        if let saved = owner.routineExceptions?.first(where: { $0.occurrence == key }) {
            preview.plannedStart = saved.start
        } else if let original = preview.movedRoutineTimes?.pin {
            preview.plannedStart = original.original
        }
        return preview
    }
    @ObservationIgnored private var planning: Task<Void, Never>?
    private(set) var planReadyForOpenSprint = false
    private(set) var generation = 0
    @ObservationIgnored private var placementCache: (generation: Int, healthRevision: Int, minute: Int, id: UUID, week: Bool, day: Date?, options: [TaskPlacement])?
    @ObservationIgnored private var loading = false
    private var repository: LocalRepository?
    static let sharedPhotoSpaceNotice = "A shared photo is waiting. Remove an older photo from the picture log to make room."
    var waitingForPhotoSpace = false
    @ObservationIgnored private var readingSharedInbox = false
    @ObservationIgnored private var clearingSharedInbox = false
    @ObservationIgnored private(set) var journalEpoch = UUID()
    private var revision = 0
    @ObservationIgnored private var pendingFullSave: Int?
    @ObservationIgnored private var retryDraftSave = false
    /// Recognize legacy intention sessions which the user already started or edited.
    static let starter: PlanTask = {
        var task = PlanTask("Set a daily intention", minutes: 5, category: .personal,
                            id: UUID(uuidString: "E3029F9E-C8A7-4054-84D0-B5374E3F0592")!)
        task.steps = [TaskStep("Name one thing you’d like to do today"), TaskStep("Choose when to try it")]
        return task
    }()
    func load() async {
        guard !ready, !loading else { return }
        loading = true
        defer { loading = false }
        loadFailure = nil
        do {
            let repo = try await Task.detached {
                var name = "Pulse"
                #if DEBUG
                    if let token = ProcessInfo.processInfo.environment["PULSE_TEST_JOURNAL"],
                        let id = UUID(uuidString: token)
                    {
                        name = "UITest-" + id.uuidString
                    }
                #endif
                let config = ModelConfiguration(name, groupContainer: .none, cloudKitDatabase: .none)
                let container = try ModelContainer(for: JournalEntry.self, configurations: config)
                return LocalRepository(modelContainer: container)
            }.value
            let snapshot = try await repo.loadSnapshot()
            journal = snapshot.journal
            let removedDefault = journal.retireLegacyStarter(Self.starter)
            captureDrafts = journal.captureDrafts ?? CaptureDrafts()
            if snapshot.recovered { notice = "Pulse recovered the previous saved journal." }
            if snapshot.unavailablePhotos > 0 {
                notice = snapshot.unavailablePhotos == 1
                    ? "One saved photo couldn’t be opened. Your other journal entries are available."
                    : "\(snapshot.unavailablePhotos) saved photos couldn’t be opened. Your other journal entries are available."
            }
            repository = repo
            ready = true
            let restoredSession = journal.observeLocalSession(at: .now)
            if shortenFocusForCommitments() || restoredSession || removedDefault { persist(sync: false) }
            if canSync { PrivateSync.shared.refresh(store: self) }
            refreshPlan()
            if let active = journal.active, journal.notifications, active.wallAnchor != nil,
                elapsed(active) < active.target
            {
                syncReminder()
            }
        } catch JournalArchive.Failure.newerVersion {
            loadFailure = JournalArchive.Failure.newerVersion.localizedDescription
        } catch { loadFailure = "Your journal couldn’t be opened. Try opening it again." }
    }
    func change(celebrateCompletion: Bool = false, _ edit: (inout Journal) -> Void) {
        guard ready, !restoring else { return }
        let finished = Set(journal.tasks.filter(\.done).map(\.id))
        let oldEvents = journal.events
        let oldTimeBlocks = journal.timeBlocks
        let oldBoosts = journal.customEnergyActivities
        let oldBuffer = journal.bufferMinutes
        var proposed = journal
        edit(&proposed)
        // Verify the whole edit before committing its task, session, and practice changes.
        if proposed.tasks.contains(where: { $0.done && !finished.contains($0.id) && proposed.needsCompletionPhoto(for: $0) }) {
            notice = "Add a completion photo to finish this task."
            return
        }
        journal = proposed
        if oldTimeBlocks != journal.timeBlocks {
            let rules = Dictionary((journal.timeBlocks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in journal.tasks.indices {
                guard let id = journal.tasks[index].assignedFocusBlockID else { continue }
                if journal.tasks[index].plannedStart.flatMap({ rules[id]?.focusWindow(containing: $0) }) == nil {
                    journal.tasks[index].assignedFocusBlockID = nil
                }
            }
        }
        if journal.events != oldEvents { refreshPreparationLinks() }
        if journal.events != oldEvents || journal.bufferMinutes != oldBuffer || journal.timeBlocks != oldTimeBlocks || journal.customEnergyActivities != oldBoosts { shortenFocusForCommitments() }
        for index in journal.tasks.indices where journal.tasks[index].inboxOnly == true &&
                (journal.tasks[index].plannedStart != nil || journal.tasks[index].id == journal.nextTaskID) {
            journal.tasks[index].inboxOnly = nil
        }
        journal.captureDrafts = captureDrafts.stored
        for i in journal.tasks.indices
        where journal.tasks[i].done && !finished.contains(journal.tasks[i].id) {
            let finishedAt = Date.now
            journal.tasks[i].completedAt = finishedAt
            if celebrateCompletion { taskCompletion = .init(taskID: journal.tasks[i].id) }
            if let practice = journal.tasks[i].practiceID,
               let index = journal.practices?.firstIndex(where: { $0.id == practice }) {
                let taskID = journal.tasks[i].id
                journal.practices?[index].log(at: finishedAt, taskID: taskID)
            }
            if let steps = journal.tasks[i].steps {
                journal.tasks[i].steps = steps.map {
                    var step = $0
                    step.done = true
                    return step
                }
            }
        }
        if let cue = taskCompletion, !journal.tasks.contains(where: { $0.id == cue.taskID && $0.done }) { taskCompletion = nil }
        TaskRoutines.advance(&journal.tasks, at: .now)
        if !journal.breaks { journal.recovery = nil }
        now = .now
        persist()
        if !isDemo { syncSystemSurfaces() }
    }
    func flushCaptureDrafts() {
        let drafts = captureDrafts.stored
        guard ready, !restoring, journal.captureDrafts != drafts || retryDraftSave else { return }
        journal.captureDrafts = drafts
        guard let repository else { return }
        retryDraftSave = false
        // If an earlier task edit is not durable, keep its save and the new draft
        // in one transaction. A draft-only transaction must never overtake it.
        if pendingFullSave != nil {
            persist(sync: false)
            return
        }
        revision += 1
        let current = revision
        Task {
            do {
                try await repository.saveDrafts(drafts, revision: current)
            } catch {
                if current == revision {
                    retryDraftSave = true
                    notice = "Your draft couldn’t be saved. Retry to keep it on this device."
                }
            }
        }
    }

    func persist(sync: Bool = true) {
        guard let repository else { return }
        syncPending = syncPending || sync
        revision += 1
        let current = revision
        let snapshot = journal
        pendingFullSave = current
        Task {
            do {
                try await repository.save(snapshot, revision: current)
                if pendingFullSave == current { pendingFullSave = nil }
                if revision == current { retryDraftSave = false }
                if revision == current, syncPending {
                    syncPending = false
                    if canSync { PrivateSync.shared.journalChanged(snapshot) }
                }
            } catch {
                if current == revision {
                    notice = "Your latest change couldn’t be saved. Retry to keep it on this device."
                }
            }
        }
    }
    func saveForShortcut() async throws {
        guard ready, !restoring, let repository else { throw CocoaError(.fileWriteUnknown) }
        try await repository.save(journal, revision: revision)
    }
    /// A capture is acknowledged only after its task and import receipt reach disk.
    func receiveSharedCaptures() async {
        guard ready, !restoring, !isDemo, canSync, !readingSharedInbox, !clearingSharedInbox else { return }
        let epoch = journalEpoch
        readingSharedInbox = true
        defer { readingSharedInbox = false }
        do {
            let photos = journal.photos ?? []
            let seen = (journal.importedShares ?? []).union(journal.tasks.map(\.id))
            let batch = try await SharedCaptureQueue.shared.batch(
                availableBytes: JournalPhoto.budget - photos.reduce(0) { $0 + $1.jpeg.count },
                availableCount: JournalPhoto.maximumCount - photos.count, alreadyImported: seen)
            guard !clearingSharedInbox, !restoring, epoch == journalEpoch else { return }
            if !batch.captures.isEmpty { change { $0.importSharedCaptures(batch.captures) } }
            let persistedIDs = (journal.importedShares ?? []).union(journal.tasks.map(\.id))
            let attempted = Set(batch.captures.map(\.id))
            let pendingIDs = batch.known.union(attempted.intersection(persistedIDs))
            let blocked = batch.waitingForSpace || !attempted.isSubset(of: persistedIDs)
            if blocked && !waitingForPhotoSpace { notice = Self.sharedPhotoSpaceNotice }
            waitingForPhotoSpace = blocked
            guard !pendingIDs.isEmpty else { return }
            try await saveForShortcut()
            guard !clearingSharedInbox, !restoring, epoch == journalEpoch else { return }
            try await SharedCaptureQueue.shared.acknowledge(pendingIDs)
            guard !clearingSharedInbox, !restoring, epoch == journalEpoch,
                  let receipts = journal.importedShares, !receipts.isDisjoint(with: pendingIDs) else { return }
            let remaining = receipts.subtracting(pendingIDs)
            journal.importedShares = remaining.isEmpty ? nil : remaining
            persist()
        } catch {
            if epoch == journalEpoch && !clearingSharedInbox {
                notice = "Shared captures couldn’t be imported. Pulse will try again when you return."
            }
        }
    }

    func restoreJournal(_ restored: Journal, disconnectOneRep: Bool = false) async throws {
        guard journal.active == nil else { throw CocoaError(.userCancelled) }
        try await replaceJournal(restored, disconnectOneRep: disconnectOneRep)
    }
    func eraseJournal() async throws {
        clearingSharedInbox = true
        defer { clearingSharedInbox = false }
        if canSync { try await SharedCaptureQueue.shared.clear() }
        waitingForPhotoSpace = false
        var empty = Journal()
        empty.starterAvailable = false
        try await replaceJournal(empty, disconnectOneRep: true)
        if !isDemo {
            liveCalendar.source = nil
            liveReminders.sources = []
        }
        replaceCalendarEvents([])
        automaticallyPlanEnergy = false
        appliedHealthDay = nil
        healthController.clear(pausePassiveReads: !isDemo)
        if !isDemo { PrivateSync.shared.disconnect() }
    }
    private func replaceJournal(_ restored: Journal, disconnectOneRep: Bool) async throws {
        guard ready, !restoring else { throw CocoaError(.userCancelled) }
        restoring = true
        journalEpoch = UUID()
        taskCompletion = nil
        pendingCompletionProof = nil
        defer { restoring = false }
        if canSync && disconnectOneRep { try OneRepCredentials.delete() }
        var restored = restored
        restored.retireLegacyStarter(Self.starter)
        restored.observeLocalSession(at: .now)
        revision += 1
        if let repository { try await repository.save(restored, revision: revision) }
        draftSave?.cancel()
        syncPending = false
        captureDrafts = restored.captureDrafts ?? CaptureDrafts()
        energyCache = nil
        recentPrep = nil
        latestPrepAttachmentID = nil
        lastTimeMove = nil
        lastListCompletion = nil
        projectedRoutines = [:]
        journal = restored
        now = .now
        syncReminder()
    }
    func waitForCurrentPlan() async {
        repeat {
            let ticket = generation
            await planning?.value
            if ticket == generation { return }
        } while !Task.isCancelled
    }

    func regenerate() { now = .now }
    var latest: CheckIn? {
        journal.reports.last(where: { Calendar.current.isDate($0.date, inSameDayAs: now) })
    }
    var landscapeTheme: LandscapeTheme {
        LandscapeTheme.resolve(journal.landscapeTheme)
    }
    var sky: Sky {
        AtmosphereEngine.sky(at: now, override: journal.atmosphere.flatMap(Atmosphere.init(rawValue:)))
    }
    var isRestDay: Bool {
        journal.restDate.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
    }
    var liveRecovery: DateInterval? {
        journal.breaks && !isRestDay && journal.limit > 0
            ? Planner.recoveryInterval(journal.recovery, at: now, commitments: planningEvents) : nil
    }
    var offeredTasks: [PlanTask] {
        return journal.tasks.filter { $0.archived != true }
    }
    var schedulingTasks: [PlanTask] { journal.tasks }

    private func refreshPlan() {
        planReadyForOpenSprint = false
        generation += 1
        let ticket = generation
        planning?.cancel()
        let snapshot = journal
        let events = planningEvents
        let options = preferences
        let clock = now
        let tasks = schedulingTasks
        let limit = isRestDay ? 0 : journal.limit
        let activeRecord = snapshot.active?.record(
            now: clock, tick: SessionClock.tick, boot: SessionClock.boot)
        planning = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            guard let inputs = DayScheduleInputs(journal: snapshot, events: events, tasks: tasks, at: clock, active: activeRecord) else { return }
            let plan = Planner.schedule(
                at: clock, tasks: inputs.tasks, commitments: inputs.events, reports: snapshot.reports,
                dailyLimit: limit, usedMinutes: inputs.used, breaks: snapshot.breaks,
                recovery: limit > 0 ? snapshot.recovery : nil, nextTaskID: snapshot.nextTaskID,
                preferences: options)
            guard !Task.isCancelled else { return }
            await self?.apply(plan, ticket: ticket)
        }
    }
    private func weekProjection(at clock: Date) -> WeekProjection {
        WeekProjection(clock: clock, journal: journal, tasks: schedulingTasks, events: planningEvents,
                       preferences: preferences,
                       active: journal.active?.record(now: clock, tick: SessionClock.tick, boot: SessionClock.boot))
    }

    func resizeTimelineTask(_ id: UUID, start: Date, end: Date, to minutes: Int) async throws {
        guard ready, !restoring, journal.active?.taskID != id else { throw TimelineResizeError.unavailable }
        let epoch = journalEpoch
        if !calendarReadyForStart { _ = await refreshLiveCalendar() }
        guard calendarReadyForStart, epoch == journalEpoch else { throw TimelineResizeError.changed }
        let ticket = generation
        let energyRevision = healthController.revision
        let projection = weekProjection(at: now)
        let job = Task.detached(priority: .userInitiated) {
            try projection.resizedTasks(id, start: start, end: end, minutes: minutes)
        }
        let resized = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        try Task.checkCancellation()
        guard ready, !restoring, epoch == journalEpoch, ticket == generation, calendarReadyForStart,
              journal.active?.taskID != id, start.addingTimeInterval(60) > Date.now,
              energyRevision == healthController.revision else { throw TimelineResizeError.changed }
        change { $0.tasks = resized }
        lastTimeMove = nil
    }

    func projectedWeek() async -> (days: [OutlookDay], remaining: [WeekRemainder])? {
        let ticket = generation
        let energyRevision = healthController.revision
        let request = weekProjection(at: now)
        let job = Task.detached(priority: .userInitiated) {
            let days = request.days()
            let activeID = request.journal.active?.taskID
            let tasks = activeID == nil ? request.journal.tasks : request.journal.tasks.filter { $0.id != activeID }
            let remaining = WeekOutlook.remaining(in: days, tasks: tasks, at: request.clock, commitments: request.events,
                                                  dailyLimit: request.journal.limit, preferences: request.preferences,
                                                  calendar: request.calendar)
            return (days, remaining)
        }
        let (days, remaining) = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard !Task.isCancelled, generation == ticket, healthController.revision == energyRevision else { return nil }
        projectedDays = (ticket, Dictionary(uniqueKeysWithValues: days.map { day in
            (day.date, Set(day.blocks.compactMap { block in
                if case .task(let id) = block.kind { return id }
                return nil
            }))
        }))
        projectedRoutines = Dictionary(days.flatMap(\.projectedTasks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (days, remaining)
    }

    func weekImpact(for id: UUID, slot: TaskPlacement) async -> WeekSlotImpact? {
        guard ready, !restoring, journal.active?.taskID != id else { return nil }
        let ticket = generation
        let energyRevision = healthController.revision
        let request = weekProjection(at: .now)
        let job = Task.detached(priority: .userInitiated) { request.impact(of: slot, taskID: id) }
        let impact = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard !Task.isCancelled, generation == ticket, healthController.revision == energyRevision else { return nil }
        return impact
    }

    func timingOptions(for id: UUID) async -> [TaskPlacement] {
        await searchPlacements(for: id, week: false, sourceDay: nil)
    }

    func weekPlacements(for id: UUID, sourceDay: Date? = nil, exactStart: Date? = nil) async -> [TaskPlacement] {
        await searchPlacements(for: id, week: true, sourceDay: sourceDay, exactStart: exactStart)
    }

    private func searchPlacements(for id: UUID, week: Bool, sourceDay: Date?, exactStart: Date? = nil) async -> [TaskPlacement] {
        let clock = Date.now
        let restToday = journal.restDate.map { Calendar.current.isDate($0, inSameDayAs: clock) } == true
        guard ready, !restoring, journal.active?.taskID != id, week || !restToday else { return [] }
        let ticket = generation
        let minute = Int(clock.timeIntervalSinceReferenceDate / 60)
        let day = sourceDay.map { Calendar.current.startOfDay(for: $0) }
        let healthRevision = healthController.revision
        if exactStart == nil, let cached = placementCache, cached.generation == ticket, cached.minute == minute,
           cached.id == id, cached.week == week, cached.day == day, cached.healthRevision == healthRevision {
            return cached.options
        }
        let snapshot = journal
        let events = planningEvents
        let tasks = schedulingTasks
        let options = preferences
        let forecast = energyTimeline
        let active = snapshot.active?.record(now: clock, tick: SessionClock.tick, boot: SessionClock.boot)
        let familyID = timingTask(id)?.seriesID ?? id
        let search = Task.detached(priority: .userInitiated) {
            guard let inputs = DayScheduleInputs(journal: snapshot, events: events, tasks: tasks, at: clock, active: active) else { return [TaskPlacement]() }
            let skipRecords = TaskSkipPattern.repeated(in: snapshot.taskSkips ?? [], tasks: tasks,
                                                       through: clock, now: clock)
                .first { $0.id == familyID }?.records ?? []
            if week {
                return Planner.weekPlacements(for: id, at: clock, tasks: inputs.tasks, commitments: inputs.events,
                                              reports: snapshot.reports, dailyLimit: snapshot.limit, usedMinutes: inputs.used,
                                              breaks: snapshot.breaks, recovery: snapshot.recovery, nextTaskID: snapshot.nextTaskID,
                                              preferences: options, forecast: forecast, startHour: snapshot.planningStartHour ?? 9,
                                              todayLimit: restToday ? 0 : snapshot.limit, sourceDay: sourceDay,
                                              exactStart: exactStart, skipRecords: skipRecords)
            }
            return Planner.placements(for: id, at: clock, tasks: inputs.tasks, commitments: inputs.events,
                                      reports: snapshot.reports, dailyLimit: snapshot.limit, usedMinutes: inputs.used,
                                      breaks: snapshot.breaks, recovery: snapshot.recovery, nextTaskID: snapshot.nextTaskID,
                                      preferences: options, forecast: forecast, exactStart: exactStart, skipRecords: skipRecords)
        }
        let optionsFound = await withTaskCancellationHandler {
            await search.value
        } onCancel: {
            search.cancel()
        }
        guard !Task.isCancelled, generation == ticket, healthController.revision == healthRevision else { return [] }
        if exactStart == nil { placementCache = (ticket, healthRevision, minute, id, week, day, optionsFound) }
        return optionsFound
    }

    /// Pin one actual task occurrence inside a reviewed focus window. Creating the
    /// rule and releasing an Inbox thought are committed together after the same trial.
    @discardableResult
    func assignTask(_ id: UUID, to rule: WeeklyTimeBlock, on occurrence: Date, creating: Bool = false) async throws -> TaskPlacement {
        let clock = Date.now
        guard ready, !restoring, calendarReadyForStart else { throw FocusAssignmentError.unavailable }
        guard rule.kind == .focus, let day = Calendar.current.dateInterval(of: .day, for: occurrence),
              journal.tasks.contains(where: { $0.id == id && !$0.done && $0.archived != true }),
              journal.active?.taskID != id else { throw FocusAssignmentError.taskChanged }
        let storedRule = journal.timeBlocks?.first { $0.id == rule.id }
        guard creating ? storedRule == nil : storedRule == rule else { throw FocusAssignmentError.blockChanged }
        if let boost = rule.boostActivityID, !energyActivities.contains(where: { $0.id == boost && $0.kind == .boost }) {
            throw FocusAssignmentError.blockChanged
        }
        let distance = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: clock), to: day.start).day ?? 0
        guard distance <= Planner.focusAssignmentLookaheadDays else { throw FocusAssignmentError.beyondHorizon }
        let slices = rule.blocks(on: day)
        guard let target = slices.first(where: { $0.start <= occurrence && occurrence < $0.end }) ?? (slices.count == 1 ? slices.first : nil),
              target.end > clock else { throw FocusAssignmentError.noTime }

        let ticket = generation
        let revision = healthController.revision
        let epoch = journalEpoch
        let projection = weekProjection(at: clock)
        let forecast = energyTimeline
        let search = Task.detached(priority: .userInitiated) {
            projection.focusPlacement(taskID: id, target: target, newRule: creating ? rule : nil, forecast: forecast)
        }
        let candidate = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
        try Task.checkCancellation()
        guard ready, !restoring, epoch == journalEpoch, ticket == generation, revision == healthController.revision,
              calendarReadyForStart else { throw FocusAssignmentError.changed }
        guard let slot = candidate else { throw FocusAssignmentError.noTime }
        guard slot.start >= Date.now else { throw FocusAssignmentError.changed }
        guard let index = journal.tasks.firstIndex(where: { $0.id == id && !$0.done && $0.archived != true }) else {
            throw FocusAssignmentError.taskChanged
        }
        change { journal in
            if creating { journal.timeBlocks = (journal.timeBlocks ?? []) + [rule] }
            let previous = journal.tasks[index]
            let source = slot.originalStart ?? slot.start
            journal.tasks[index].moveOccurrence(to: slot.start, originalDay: source)
            journal.tasks[index].assignedFocusBlockID = rule.id
            lastTimeMove = TaskTimeMove(from: previous, to: journal.tasks[index], sourceDay: source)
        }
        return slot
    }

    @discardableResult
    func moveTask(_ id: UUID, toHour hour: Date?, exact: Bool = false) async -> Bool {
        let ticket = generation
        let energyRevision = healthController.revision
        guard calendarReadyForStart else { return false }
        let options = await searchPlacements(for: id, week: false, sourceDay: nil, exactStart: exact ? hour : nil)
        guard calendarReadyForStart else { return false }
        let choice: TaskPlacement?
        if let hour {
            let interval = Calendar.current.dateInterval(of: .hour, for: hour)
            choice = options.first { slot in
                if exact { return slot.start == hour }
                return interval.map { slot.start >= $0.start && slot.start < $0.end } ?? false
            }
        } else {
            choice = options.first(where: \.recommended)
        }
        return commitPlacement(choice, taskID: id, generation: ticket, energyRevision: energyRevision, sourceDay: now)
    }

    @discardableResult
    func moveWeekTask(_ id: UUID, day: Date?, hour: Date?, sourceDay: Date? = nil, exactStart: Bool = false) async -> Bool {
        let ticket = generation
        let energyRevision = healthController.revision
        guard calendarReadyForStart else { return false }
        let options = await searchPlacements(for: id, week: true, sourceDay: sourceDay, exactStart: exactStart ? hour : nil)
        guard calendarReadyForStart else { return false }
        let calendar = Calendar.current
        let daily = options.filter { option in day.map { calendar.isDate(option.start, inSameDayAs: $0) } ?? true }
        let choice: TaskPlacement?
        if let hour, let interval = calendar.dateInterval(of: .hour, for: hour) {
            choice = daily.first { exactStart ? $0.start == hour : ($0.start >= interval.start && $0.start < interval.end) }
        } else if day != nil {
            choice = daily.first(where: \.recommendedForDay)
        } else {
            choice = options.first(where: \.recommended)
        }
        return commitPlacement(choice, taskID: id, generation: ticket, energyRevision: energyRevision, sourceDay: choice?.originalStart ?? sourceDay ?? choice?.start ?? now)
    }

    private func commitPlacement(_ choice: TaskPlacement?, taskID id: UUID, generation ticket: Int, energyRevision: Int, sourceDay: Date) -> Bool {
        guard !Task.isCancelled, ticket == generation, energyRevision == healthController.revision, !restoring, ready, let slot = choice,
              slot.start.addingTimeInterval(60) > Date.now else { return false }
        if let key = slot.projectedOccurrence {
            guard id == key.id, let owner = journal.tasks.firstIndex(where: { $0.owns(key) }) else { return false }
            let move = RoutineException(occurrence: key, start: slot.start)
            let previous = journal.tasks[owner].routineExceptions?.first { $0.occurrence == key }
            let title = journal.tasks[owner].title
            change { $0.tasks[owner].setException(move, for: key) }
            if let receipt = TaskTimeMove(before: previous, after: move, title: title, sourceDay: sourceDay) {
                lastTimeMove = receipt
            }
        } else {
            guard journal.tasks.contains(where: { $0.id == id && !$0.done && $0.archived != true }) else { return false }
            change { journal in
                if let index = journal.tasks.firstIndex(where: { $0.id == id }) {
                    let previous = journal.tasks[index]
                    journal.tasks[index].moveOccurrence(to: slot.start, originalDay: sourceDay)
                    if let move = TaskTimeMove(from: previous, to: journal.tasks[index], sourceDay: sourceDay) {
                        lastTimeMove = move
                    }
                }
            }
        }
        return true
    }

    private func apply(_ plan: [Block], ticket: Int) {
        if ticket == generation, !restoring {
            blocks = plan
            planReadyForOpenSprint = true
            var updatedHistory = recordTomorrowForecast()
            if !journal.tasks.isEmpty, let record = DayPlanRecord(date: now, blocks: plan),
                journal.planHistory?.contains(where: { $0.day == record.day }) != true
            {
                journal.planHistory = Array(((journal.planHistory ?? []) + [record]).suffix(366))
                updatedHistory = true
            }
            let starts = TaskSkipping.automaticStarts(journal.automaticTaskStarts ?? [:], tasks: journal.tasks, blocks: plan, at: now,
                                                   activeTask: journal.active?.taskID)
            if starts != (journal.automaticTaskStarts ?? [:]) {
                journal.automaticTaskStarts = starts.isEmpty ? nil : starts
                updatedHistory = true
            }
            if updatedHistory { persist(sync: false) }
            syncSystemSurfaces()
        }
    }

    private func recordTomorrowForecast() -> Bool {
        let calendar = Calendar.current
        guard journal.reports.count + (journal.energyCorrections?.count ?? 0) >= 3,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              !(journal.forecastHistory ?? []).contains(where: { $0.day == tomorrow || $0.isForDay(tomorrow, calendar: calendar) }),
              let forecast = DayAheadForecast(from: energyTimeline, calendar: calendar) else { return false }
        journal.forecastHistory = Array(((journal.forecastHistory ?? []) + [forecast]).sorted { $0.day < $1.day }.suffix(120))
        return true
    }
    var next: (PlanTask, Block)? {
        for b in blocks {
            if case .task(let id) = b.kind, let t = offeredTasks.first(where: { $0.id == id }) {
                return (t, b)
            }
        }
        return nil
    }
    /// Try the selected task first against the same reservations as the daily plan.
    /// A held thought is eligible for this session only. Ending early keeps it in Inbox.
    @discardableResult
    func quickStartTask(_ id: UUID, at requestedDate: Date? = nil) async -> Bool {
        if let active = journal.active {
            if active.taskID == id { return true }
            notice = "Finish the current focus session before starting another task."
            return false
        }
        guard ready, !restoring else { return false }
        let epoch = journalEpoch
        await refreshLiveCalendar()
        guard !Task.isCancelled, ready, !restoring, epoch == journalEpoch else { return false }
        guard calendarReadyForStart else {
            notice = "Your calendar is still loading. Try Start again in a moment."
            return false
        }
        guard journal.active == nil, let task = journal.tasks.first(where: { $0.id == id && !$0.done && $0.archived != true }) else {
            notice = "This task is no longer available to start."
            return false
        }
        if let reason = completionObstacle(task) { notice = reason; return false }
        let clock = requestedDate ?? Date.now
        now = clock
        if isRestDay { notice = "Today is a rest day. Resume planning to start a task."; return false }
        if liveRecovery != nil { notice = "Finish your break before starting a task."; return false }
        let effective = task.planningCopy(with: planningEvents, bufferMinutes: preferences.bufferMinutes)
        if effective.earliest > clock {
            notice = "This task is available " + effective.earliest.formatted(date: .abbreviated, time: .shortened) + "."
            return false
        }
        let ticket = generation
        let healthRevision = healthController.revision
        let snapshot = journal
        let options = preferences
        let events = planningEvents
        let job = Task.detached(priority: .userInitiated) { () -> Block? in
            guard var inputs = DayScheduleInputs(journal: snapshot, events: events, tasks: snapshot.tasks,
                                                 at: clock, active: nil),
                  let index = inputs.tasks.firstIndex(where: { $0.id == id }) else { return nil }
            inputs.tasks[index].inboxOnly = nil
            return Planner.schedule(at: clock, tasks: inputs.tasks, commitments: inputs.events, reports: snapshot.reports,
                                    dailyLimit: snapshot.limit, usedMinutes: inputs.used, breaks: snapshot.breaks,
                                    recovery: snapshot.recovery, nextTaskID: id, preferences: options)
                .first { $0.kind == .task(id) && $0.start.timeIntervalSince(clock) < 60 && $0.end > clock }
        }
        let block = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard !Task.isCancelled, epoch == journalEpoch else { return false }
        guard ticket == generation, healthRevision == healthController.revision else {
            notice = "Your plan changed. Tap Start again."
            return false
        }
        if let block {
            let startDate = requestedDate ?? Date.now
            now = startDate
            start(task, block: block, at: startDate, selectedFromList: true)
            if journal.active?.taskID == id { return true }
        }
        notice = "There’s no room to start this task now. Choose another time in Plan."
        return false
    }

    func canStart(_ block: Block, includingHeld: Bool = false) -> Bool {
        guard calendarReadyForStart, liveRecovery == nil, case .task(let id) = block.kind,
            let task = offeredTasks.first(where: { $0.id == id }),
            !task.done, (includingHeld || !task.isInboxOnly), block.end > now, now < preferences.workEnd(on: now),
            block.start.timeIntervalSince(now) < 60
        else { return false }
        let planned = task.planningCopy(with: planningEvents, bufferMinutes: preferences.bufferMinutes)
        guard planned.earliest <= now, planned.permitsRoutineWork(at: now), planned.preparationCutoff(bufferMinutes: preferences.bufferMinutes).map({ now < $0 }) != false else { return false }
        if preferences.focusBoundary(for: task, at: now).map({ $0 <= now }) == true { return false }
        if let availability = task.availability, availability.interval(containing: now) == nil { return false }
        return !Planner.workExclusions(
            at: now, commitments: planningEvents, reports: journal.reports, preferences: preferences
        )
        .contains { $0.start <= now && now < $0.end }
    }
    /// Credit work already done, then cap only the remaining run at the earliest fixed boundary.
    /// Keeping the session identity and anchors lets notifications and the Live Activity follow the new end.
    @discardableResult
    func shortenFocusForCommitments(at date: Date = .now, tick: Double = SessionClock.tick,
                                    boot: String? = SessionClock.boot) -> Bool {
        guard var active = journal.active, active.wallAnchor != nil else { return false }
        let earned = active.elapsed(now: date, tick: tick, boot: boot)
        guard earned < active.target else { return false }
        // A saved import may still have an old clock while its connected calendar is loading.
        let events = calendarReadyForStart ? planningEvents : journal.events.filter { !liveCalendar.snapshotIDs.contains($0.id) }
        let buffer = journal.bufferMinutes ?? 0
        let originalEnd = date.addingTimeInterval(active.target - earned)
        var end = originalEnd
        if let task = journal.tasks.first(where: { $0.id == active.taskID && $0.preparation != nil }),
           let prep = task.planningCopy(with: events, bufferMinutes: buffer).preparationCutoff(bufferMinutes: buffer) {
            end = min(end, prep)
        }
        let calendar = Calendar.current
        var cursor = date
        let options = preferences
        if let task = journal.tasks.first(where: { $0.id == active.taskID }), !task.fitsDedicatedFocus || task.assignedFocusBlockID != nil, let boundary = options.focusBoundary(for: task, at: date) {
            end = min(end, boundary)
        }
        while cursor < end && (!events.isEmpty || !options.timeBlocks.isEmpty) {
            let fixed = Planner.workExclusions(at: cursor, commitments: events, bufferMinutes: buffer, calendar: calendar)
            let weekly = options.weeklyBlocks(on: cursor, commitments: events, reports: journal.reports, calendar: calendar).compactMap { block -> DateInterval? in
                guard case .timeBlock(_, let role) = block.kind, role != .focus else { return nil }
                return DateInterval(start: block.start, end: block.end)
            }
            if let first = (fixed + weekly).filter({ $0.end > date }).min(by: { $0.start < $1.start }) {
                end = min(end, first.start)
                break
            }
            guard let nextDay = calendar.dateInterval(of: .day, for: cursor)?.end else { break }
            cursor = nextDay
        }
        guard end < originalEnd else { return false }
        let target = max(0.001, earned + max(0, end.timeIntervalSince(date)))
        guard target < active.target else { return false }
        active.target = target
        journal.active = active
        return true
    }

    private func availableFocusSeconds(for task: PlanTask, at start: Date, until end: Date,
                                       day: DateInterval, activeSecondsToday: Double = 0) -> Double {
        let events = planningEvents
        let options = preferences
        let intervals = Planner.workExclusions(
            at: start, commitments: events, reports: journal.reports, preferences: options)

        guard !intervals.contains(where: { $0.start <= start && start < $0.end }) else {
            return 0
        }
        guard task.permitsRoutineWork(at: start) else { return 0 }
        let nextCommitment = intervals.first { $0.start > start }?.start ?? day.end
        var boundary = min(nextCommitment, end, options.workEnd(on: start), options.focusBoundary(for: task, at: start) ?? end)
        if task.preparation != nil {
            let refreshed = task.planningCopy(with: events, bufferMinutes: options.bufferMinutes)
            if let cutoff = refreshed.preparationCutoff(bufferMinutes: options.bufferMinutes) {
                boundary = min(boundary, cutoff)
            }
        }
        if let availability = task.availability {
            guard let window = availability.interval(containing: start) else { return 0 }
            boundary = min(boundary, window.end)
        }
        let completed = Set(journal.tasks.lazy.filter(\.done).map(\.id))
        for candidate in offeredTasks where candidate.id != task.id && !candidate.done && candidate.plannedStart != nil {
            let other = candidate.planningCopy(with: events, bufferMinutes: options.bufferMinutes)
            guard let pin = other.plannedStart, other.earliest <= pin,
                  other.dependency.map(completed.contains) ?? true else { continue }
            guard other.permitsRoutineWork(at: pin) else { continue }
            if let window = other.availability, window.interval(containing: pin) == nil { continue }
            if journal.active?.taskID == task.id, other.pinStarts(at: start), !task.pinStarts(at: start) { return 0 }
            if pin > start { boundary = min(boundary, pin) }
        }
        let used = journal.sessions.reduce(activeSecondsToday) { $0 + $1.seconds(in: day) }
        let limit = Capacity.workloadLimit(
            userLimit: journal.limit, reports: journal.reports, at: start, calendar: .current)
        let actualLimit = tuning.minimumDay ? min(5, limit) : limit
        let cap = task.blockMinutes(at: start, capacity: capacity, limit: actualLimit, calendar: .current)
        return min(
            boundary.timeIntervalSince(start), Double(actualLimit) * 60 - used, Double(cap) * 60)
    }

    func start(_ task: PlanTask, block: Block, minutes: Int? = nil, step: TaskStep? = nil, at start: Date = .now, selectedFromList: Bool = false) {
        guard journal.active == nil, !isRestDay,
            let current = offeredTasks.first(where: { $0.id == task.id }),
            !current.done, block.kind == .task(task.id), canStart(block, includingHeld: selectedFromList),
            current.dependency.map({ id in journal.tasks.contains { $0.id == id && $0.done } }) ?? true,
            let day = Calendar.current.dateInterval(of: .day, for: start)
        else { return }
        let availableSeconds = availableFocusSeconds(for: current, at: start, until: block.end, day: day)

        guard availableSeconds >= 1 else {
            now = start
            return
        }
        change { j in
            j.recovery = nil
            if j.nextTaskID == task.id { j.nextTaskID = nil }
            var session = ActiveSession(
                task: current, minutes: min(block.minutes, max(1, minutes ?? block.minutes)), now: start,
                tick: SessionClock.tick, boot: SessionClock.boot)
            session.target = min(session.target, availableSeconds)
            if let step {
                if let i = j.tasks.firstIndex(where: { $0.id == task.id }),
                    j.tasks[i].steps?.contains(where: { $0.id == step.id }) != true
                {
                    var steps = j.tasks[i].steps ?? []
                    steps.insert(step, at: 0)
                    if steps.count == 1 { steps.append(TaskStep(step.title == task.title ? "Continue this task" : task.title)) }
                    j.tasks[i].steps = steps
                }
                session.stepID = step.id
                session.title = step.title
            }
            j.beginLocalSession(session)
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    func elapsed(_ session: ActiveSession) -> Double {
        session.elapsed(now: .now, tick: SessionClock.tick, boot: SessionClock.boot)
    }
    func toggleTimer(at date: Date = .now) {
        guard let active = journal.active else { return }
        let tick = SessionClock.tick
        if active.wallAnchor != nil {
            change { $0.active?.pause(now: date, tick: tick, boot: SessionClock.boot) }
            return
        }
        now = date
        let available = continuationSeconds(for: active, at: date)
        let remaining = min(available, active.target - active.accumulated)
        guard remaining > 0, available >= 1 else {
            notice = "Your session is paused. There’s no focus time available right now."
            return
        }
        change {
            $0.active?.target = active.accumulated + remaining
            $0.active?.resume(now: date, tick: tick, boot: SessionClock.boot)
        }
    }
    private func continuationSeconds(for active: ActiveSession, at date: Date) -> Double {
        if active.isOpenSprint { return openSprintRoom(at: date, active: active, verifySchedule: true) }
        guard ready, !restoring, calendarReadyForStart, !isRestDay, liveRecovery == nil,
              let task = journal.tasks.first(where: { $0.id == active.taskID && !$0.done && $0.archived != true }),
              task.planningCopy(with: planningEvents, bufferMinutes: preferences.bufferMinutes).earliest <= date,
              task.dependency.map({ id in journal.tasks.contains { $0.id == id && $0.done } }) ?? true,
              let day = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        let record = active.record(now: date, tick: SessionClock.tick, boot: SessionClock.boot)
        let available = availableFocusSeconds(for: task, at: date, until: day.end, day: day,
                                              activeSecondsToday: record.seconds(in: day))
        return max(0, min(available, task.remainingSeconds - record.seconds))
    }

    /// A finished sprint stays stopped until the person chooses another interval.
    func sprintExtensionSeconds(at date: Date) -> Double {
        guard let active = journal.active,
              active.elapsed(now: date, tick: SessionClock.tick, boot: SessionClock.boot) >= active.target else { return 0 }
        if active.isOpenSprint {
            let room = openSprintRoom(at: date, active: active, verifySchedule: false)
            return max(0, floor(min(room, 86_400 - active.target) / 60) * 60)
        }
        guard active.stepID != nil, let task = journal.tasks.first(where: { $0.id == active.taskID }) else { return 0 }
        let blockLimit = Capacity.block(minutes: task.minutes, capacity: capacity, limit: journal.limit)
        return max(0, min(300, continuationSeconds(for: active, at: date), Double(blockLimit) * 60 - active.target))
    }

    func extendSprint(at date: Date = .now) {
        now = date
        var extra = sprintExtensionSeconds(at: date)
        if let active = journal.active, active.isOpenSprint, extra >= 60 {
            let room = openSprintRoom(at: date, active: active, verifySchedule: true)
            extra = floor(min(room, 86_400 - active.target) / 60) * 60
            guard extra >= 60 else { return }
        }
        guard extra >= 1 else { return }
        let tick = SessionClock.tick
        change { journal in
            // Close the old interval before increasing its target. Time spent
            // deciding after the bell belongs to neither interval.
            journal.active?.pause(now: date, tick: tick, boot: SessionClock.boot)
            journal.active?.target += extra
            journal.active?.resume(now: date, tick: tick, boot: SessionClock.boot)
        }
    }

    func finish(done: Bool, leavingResumeNote note: String? = nil, pickUpAt nextStepID: UUID? = nil, photo: JournalPhoto? = nil) {
        guard let a = journal.active else { return }
        if let photo {
            guard !a.isOpenSprint, photo.taskID == a.taskID, photo.isSafeImage,
                  JournalPhoto.fits(photo.jpeg, in: journal) else {
                notice = "This photo couldn’t be added. Choose another photo or free up space in the picture log."
                return
            }
        }
        if done, needsCompletionPhoto(for: a), photo?.completion != true {
            pendingCompletionProof = CompletionProofRequest(taskID: a.taskID, epoch: journalEpoch, session: a)
            return
        }
        change(celebrateCompletion: done) { journal in
            journal.recordFinishedSession(a, done: done, at: .now, note: note, nextStepID: nextStepID, photo: photo)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    func deferTask(_ task: PlanTask, to date: Date) {
        change { j in
            if let i = j.tasks.firstIndex(where: { $0.id == task.id }) { j.tasks[i].deferOccurrence(until: date) }
        }
    }
    func syncReminder() { if !isDemo { syncSystemSurfaces() } }
}

/// Ordinary scheduling and interactive moves reserve exactly the same time and workload.
struct DayScheduleInputs: Sendable {
    var tasks: [PlanTask]
    var events: [Commitment]
    var used: Int

    init?(journal: Journal, events: [Commitment], tasks: [PlanTask], at now: Date, active: SessionRecord?, calendar: Calendar = .current) {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return nil }
        self.tasks = tasks
        self.events = events
        var seconds = journal.sessions.reduce(0.0) { $0 + $1.seconds(in: day) }
        seconds += active?.seconds(in: day) ?? 0
        if let focus = journal.active {
            self.tasks.removeAll { $0.id == focus.taskID }
            let remaining = max(0, focus.target - (active?.seconds ?? 0))
            if remaining > 0, focus.wallAnchor != nil {
                seconds += remaining
                var hold = Commitment(focus.title, start: now, end: now.addingTimeInterval(remaining))
                hold.id = focus.taskID
                self.events.append(hold)
            }
        }
        used = Int(ceil(seconds / 60))
    }
}
