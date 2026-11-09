import Foundation
import PulseEngine

struct PersonalGoal: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var milestones: [TaskStep] = []
}

extension Workspace {
    var tuning: PlanTuning {
        guard let tuning = journal.tuning, Calendar.current.isDate(tuning.date, inSameDayAs: now) else {
            return PlanTuning(date: now)
        }
        return tuning
    }
    var energyTimeline: EnergyTimeline {
        let corrections = journal.energyCorrections ?? []
        let expectations = journal.energyExpectations ?? []
        if let cache = energyCache, cache.date == now, cache.revision == healthController.revision,
           cache.sleepTarget == journal.sleepTarget, cache.reports == journal.reports, cache.corrections == corrections, cache.expectations == expectations { return cache.timeline }
        let timeline = EnergyTimeline(signals: healthController.signals, checkIns: journal.reports,
                                      corrections: corrections, now: now, expectations: expectations,
                                      sleepNights: healthController.nights, sleepTarget: journal.sleepTarget)
        energyCache = (now, healthController.revision, journal.sleepTarget, journal.reports, corrections, expectations, timeline)
        return timeline
    }

    func updateEnergyCorrection(at date: Date, score: Double?) {
        guard date <= Date.now, let interval = Calendar.current.dateInterval(of: .hour, for: date),
              score?.isFinite != false else { return }
        change { journal in
            var corrections = journal.energyCorrections ?? []
            corrections.removeAll { $0.date >= interval.start && $0.date < interval.end }
            if let score { corrections.append(EnergyCorrection(date: date, score: Capacity.scale(score))) }
            journal.energyCorrections = corrections.sorted { $0.date < $1.date }
        }
    }

    var preferences: PlannerPreferences {
        var result = PlannerPreferences(tuning: tuning, order: journal.taskOrder ?? [], votes: journal.votes ?? [],
                                        bufferMinutes: journal.bufferMinutes ?? 0, wrapUpMinute: journal.wrapUpMinute)
        result.timeBlocks = journal.timeBlocks ?? []
        if !result.timeBlocks.isEmpty {
            result = result.respectingBoostPins(journal.tasks)
            result.timeBlockBoosts = Dictionary(uniqueKeysWithValues: energyActivities.filter { $0.kind == .boost }.map { ($0.id, $0) })
        }
        result.corrections = journal.energyCorrections ?? []
        result.expectations = journal.energyExpectations ?? []
        if (automaticallyPlanEnergy || healthPlanningToday) && !isDemo && !PrivacySession.connectionsLocked {
            result.energyTimeline = energyTimeline
            result.energyAsOf = now
            result.energyOnlyToday = !automaticallyPlanEnergy
        }
        return result
    }
    var capacity: Double { preferences.capacity(at: now, reports: journal.reports, calendar: .current) }
    var capacityLabel: String {
        if tuning.manualCapacity != nil { return "Your capacity" }
        if let hour = Calendar.current.dateInterval(of: .hour, for: now),
           journal.energyCorrections?.contains(where: { $0.date >= hour.start && $0.date <= now }) == true { return "Your energy update" }
        if preferences.energyTimeline?.estimate(at: now) != nil { return "Energy estimate" }
        return "Estimated capacity"
    }
    var canNameIntention: Bool {
        guard journal.active == nil, let first = journal.tasks.first(where: { $0.id == Self.starter.id }) else { return false }
        let intentionSessions = Set(journal.sessions.lazy.filter { $0.taskID == first.id }.map(\.id))
        guard journal.tasks.allSatisfy({ task in
            task.id == first.id || task.capturedDuringSessionID.map(intentionSessions.contains) == true
        }) else { return false }
        return first.id == Self.starter.id && first.title == Self.starter.title && !first.done && first.archived != true
            && first.steps?.map(\.title) == Self.starter.steps?.map(\.title) && first.steps?.first?.done == true
    }

    /// A preexisting timer can be opened before its journal has a stable session identity.
    func captureSessionID(for source: ActiveSession) -> UUID? {
        guard ready, !restoring else { return nil }
        if let active = journal.active, active.taskID == source.taskID, active.started == source.started,
           source.sessionID == nil || source.sessionID == active.sessionID {
            if let id = active.sessionID { return id }
            let id = UUID()
            change { $0.active?.sessionID = id }
            return id
        }
        return journal.sessions.last {
            $0.taskID == source.taskID && $0.start == source.started && (source.sessionID == nil || source.sessionID == $0.id)
        }?.id
    }

    @discardableResult func captureTask(_ task: PlanTask, namingIntention: Bool = false,
                                        focusSession: ActiveSession? = nil, distraction: Bool = false, completing slot: CaptureDraftSlot? = nil) -> UUID? {
        guard ready, !restoring else { return nil }
        let sourceID: UUID?
        if case .sprint(let id) = slot {
            guard journal.active?.sessionID == id || captureDrafts.sprints?[id] != nil
                    || journal.sessions.contains(where: { $0.id == id }) else { return nil }
            sourceID = id
        } else {
            sourceID = focusSession.flatMap { captureSessionID(for: $0) }
        }
        if let slot { captureDrafts.clear(slot) }
        if journal.tasks.contains(where: { $0.id == task.id }) {
            flushCaptureDrafts()
            return task.id
        }
        let choseNext = namingIntention && canNameIntention
        change {
            if choseNext, let index = $0.tasks.firstIndex(where: { $0.id == Self.starter.id }) {
                $0.tasks[index].done = true
                $0.nextTaskID = task.id
            }
            var captured = task
            captured.capturedDuringSessionID = sourceID
            if (sourceID != nil || distraction) && !captured.hasSchedulingInstruction { captured.inboxOnly = true }
            $0.tasks.append(captured)
            $0.starterAvailable = false
        }
        return task.id
    }
    func recordVote(_ verdict: SuggestionVote.Verdict, task: PlanTask) {
        change { j in
            var votes = j.votes ?? []
            votes.append(SuggestionVote(verdict, category: task.category))
            j.votes = Array(votes.suffix(300))
            if verdict == .tooMuch { j.nextTaskID = task.id }
            if verdict == .tooMuch, let i = j.tasks.firstIndex(where: { $0.id == task.id }) {
                j.tasks[i].effort = min(10, j.tasks[i].effort + 1)
            }
        }
    }
    func reorder(_ id: UUID, toPositionOf target: UUID) {
        guard id != target else { return }
        var seen = Set<UUID>()
        var ids = blocks.compactMap { block -> UUID? in
            guard case .task(let taskID) = block.kind, seen.insert(taskID).inserted else { return nil }
            return taskID
        }
        guard let origin = ids.firstIndex(of: id), let destination = ids.firstIndex(of: target) else { return }
        ids.remove(at: origin)
        ids.insert(id, at: destination)
        change {
            $0.taskOrder = ids + ($0.taskOrder ?? []).filter { !seen.contains($0) }
            $0.nextTaskID = nil
        }
    }
    func markDone(_ task: PlanTask) {
        guard journal.active?.taskID != task.id,
              let current = journal.tasks.first(where: { $0.id == task.id && !$0.done }) else { return }
        if requestProofIfNeeded(for: current) { return }
        change(celebrateCompletion: true) { j in
            if let i = j.tasks.firstIndex(where: { $0.id == task.id }) {
                j.tasks[i].done = true
            }
            j.starterAvailable = false
        }
    }
    func scheduleExplanation(_ task: PlanTask, block: Block) -> String {
        if journal.nextTaskID == task.id {
            return "You chose this task to go first when time was available."
        }
        if tuning.minimumDay { return "Minimum day keeps one short block and your fixed commitments." }
        var reason = "\(block.minutes) minutes fits your remaining time and workload budget."
        if task.fitsDedicatedFocus || task.assignedFocusBlockID != nil, !(journal.timeBlocks ?? []).isEmpty,
           let window = preferences.weeklyBlocks(on: block.start, commitments: planningEvents, reports: journal.reports).first(where: {
               if case .timeBlock(let id, .focus) = $0.kind { return (task.fitsDedicatedFocus || id == task.assignedFocusBlockID) && $0.start <= block.start && block.start < $0.end }
               return false
           }) {
            reason = "This block fits your " + (window.title == "Focus time" ? "focus time." : "focus time, “" + window.title + "”.")
        }
        if let due = task.due {
            reason += " It is due " + due.formatted(date: .abbreviated, time: .shortened) + "."
        }
        if let dependency = task.dependency,
            let first = journal.tasks.first(where: { $0.id == dependency })
        {
            reason += " It follows “" + first.title + "”."
        }
        if task.importance >= 7 { reason += " You marked it as important." }
        if preferences.preference(for: task.category, at: now) > 0.1 {
            reason += " Similar suggestions have worked for you."
        }
        return reason
    }
}

extension Workspace {
    func spareMoments(minutes: Int, at date: Date, tasks: [PlanTask]? = nil) -> [Block] {
        let calendar = Calendar.current
        guard ready, !restoring, journal.active == nil,
            journal.restDate.map({ calendar.isDate($0, inSameDayAs: date) }) != true,
            let day = calendar.dateInterval(of: .day, for: date)
        else { return [] }
        let used = journal.sessions.reduce(0) { $0 + $1.seconds(in: day) }
        return Planner.spareMoments(
            at: date, minutes: minutes, tasks: tasks ?? schedulingTasks, commitments: planningEvents, reports: journal.reports,
            dailyLimit: journal.limit, usedMinutes: Int(ceil(used / 60)), recovery: journal.breaks ? journal.recovery : nil,
            preferences: preferences, calendar: calendar)
    }

    func startSpareMoment(_ id: UUID, minutes: Int, at date: Date = .now) -> Bool {
        now = date
        guard let block = spareMoments(minutes: minutes, at: now).first(where: { $0.kind == .task(id) }),
            let task = offeredTasks.first(where: { $0.id == id })
        else { return false }
        start(task, block: block, at: now)
        return journal.active?.taskID == id
    }
}
