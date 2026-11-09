import ActivityKit
import Foundation
import PulseEngine
import UIKit
import WidgetKit

extension Workspace {
    var systemPreferences: ReminderPreferences {
        if let prefs = journal.reminderPreferences { return prefs }
        var prefs = ReminderPreferences()
        prefs.enabled = journal.notifications
        return prefs
    }

    func recheckSystemSurfacesOnActivation() {
        guard ready, !isDemo else { return }
        SystemSurfaces.shared.invalidate()
        now = .now
    }

    func publishFocusControlResult(declinedResume: (session: String, revision: Int)? = nil) async {
        SystemSurfaces.shared.declinedResume = declinedResume
        syncSystemSurfaces()
        await SystemSurfaces.shared.waitForUpdate()
    }

    func syncSystemSurfaces() {
        guard ready, !isDemo else { return }
        let preferences = systemPreferences
        let snapshot: DayWidgetSnapshot?
        if preferences.widgetDetails {
            let items = blocks.lazy.compactMap { block -> DayWidgetEntry? in
                guard case .task = block.kind else { return nil }
                return DayWidgetEntry(title: block.title, start: block.start, end: block.end, minutes: block.minutes)
            }
            snapshot = DayWidgetSnapshot(day: Calendar.current.startOfDay(for: now), entries: Array(items.prefix(12)), rest: isRestDay)
        } else {
            snapshot = nil
        }
        let timer = journal.active.map { session in
            let remaining = max(0, session.target - elapsed(session))
            let deadline = session.wallAnchor.flatMap { _ in
                remaining > 0
                    ? Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + remaining).rounded(.up)) : nil
            }
            return SurfaceTimer(
                task: session.taskID, started: session.started, title: preferences.showTitles ? session.title : "Focus",
                secondsLeft: deadline == nil ? Int(ceil(remaining)) : Int(ceil(session.target)), deadline: deadline,
                timerRevision: session.timerRevision ?? 0)
        }
        let reminders = preferences.enabled && preferences.taskAlerts ? journal.tasks.compactMap { task -> TaskAlert? in
            guard !task.done, task.archived != true, let time = task.reminder ?? task.due else { return nil }
            return TaskAlert(
                id: task.id, title: preferences.showTitles ? task.title : "A task is ready to review.",
                date: max(time, task.after ?? .distantPast), explicit: task.reminder != nil)
        } : []
        let recovery: Date?
        if preferences.enabled, preferences.recoveryPrompt, !isRestDay, journal.active == nil,
           let day = Calendar.current.dateInterval(of: .day, for: now),
           !journal.sessions.contains(where: { day.start <= $0.start && $0.start < day.end || $0.seconds(in: day) > 0 }) {
            recovery = next?.1.start
        } else {
            recovery = nil
        }
        SystemSurfaces.shared.update(
            snapshot: snapshot, timer: timer, preferences: preferences, focusAlert: journal.notifications,
            tasks: reminders, recovery: recovery, now: now)
    }
}

struct SurfaceTimer: Equatable, Sendable {
    let task: UUID
    let started: Date
    let title: String
    let secondsLeft: Int
    let deadline: Date?
    var timerRevision: Int = 0
    var resumeDeclined = false
    var identity: String { SurfaceData.focusID(task: task, started: started) }
}

struct TaskAlert: Equatable, Sendable {
    let id: UUID
    let title: String
    let date: Date
    let explicit: Bool

    func nextDate(after now: Date, heldUntil: Date?, preferences: ReminderPreferences) -> Date? {
        guard let allowed = preferences.nextAllowed(date) else { return nil }
        if allowed > now { return allowed }
        guard let heldUntil, let held = preferences.nextAllowed(heldUntil), held > now else { return nil }
        return held
    }
}

@MainActor
private final class SystemSurfaces {
    static let shared = SystemSurfaces()
    private var cycle: Task<Void, Never>?
    private var previousWidget: DayWidgetSnapshot?
    private var loadedWidget = false
    var declinedResume: (session: String, revision: Int)?
    private var lastActivityTimer: SurfaceTimer?
    private var activityChecked = false
    private var clearedDisabledReminders = false
    private var lastActivityFailure: String?

    func waitForUpdate() async { await cycle?.value }

    func invalidate() {
        cycle?.cancel()
        activityChecked = false
        clearedDisabledReminders = false
        lastActivityFailure = nil
    }

    func update(
        snapshot: DayWidgetSnapshot?, timer: SurfaceTimer?, preferences: ReminderPreferences, focusAlert: Bool,
        tasks: [TaskAlert], recovery: Date?, now: Date
    ) {
        if preferences.enabled { clearedDisabledReminders = false }
        publish(snapshot, at: now)
        let previous = cycle
        previous?.cancel()
        cycle = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            var current = preferences.liveTimer ? timer : nil
            if let declinedResume, declinedResume.session == current?.identity,
               declinedResume.revision == current?.timerRevision, current?.deadline == nil {
                current?.resumeDeclined = true
            } else {
                declinedResume = nil
            }
            if current == nil { lastActivityFailure = nil }
            if !activityChecked || lastActivityTimer != current {
                let canCreate = UIApplication.shared.applicationState == .active && lastActivityFailure != current?.identity
                do { try await Self.updateActivity(current, canCreate: canCreate) } catch {
                    lastActivityFailure = current?.identity
                    Workspace.live.notice = "The Lock Screen timer couldn’t start. Your focus timer is running in Pulse."
                }
                guard !Task.isCancelled else { return }
                lastActivityTimer = current
                activityChecked = true
            }
            guard !Task.isCancelled, preferences.enabled || !clearedDisabledReminders else { return }
            await PlanningNotifications.reconcile(
                preferences: preferences, focusAlert: focusAlert, timer: timer, tasks: tasks, recovery: recovery,
                now: now)
            if !Task.isCancelled { clearedDisabledReminders = !preferences.enabled }
        }
    }

    private func publish(_ snapshot: DayWidgetSnapshot?, at now: Date) {
        guard let defaults = UserDefaults(suiteName: SurfaceData.suite) else { return }
        if !loadedWidget {
            loadedWidget = true
            if let old = defaults.data(forKey: SurfaceData.widgetKey) {
                previousWidget = try? JSONDecoder().decode(DayWidgetSnapshot.self, from: old)
                if previousWidget == nil && snapshot == nil {
                    defaults.removeObject(forKey: SurfaceData.widgetKey)
                    WidgetCenter.shared.reloadTimelines(ofKind: SurfaceData.widgetKind)
                }
            }
        }
        guard previousWidget != snapshot else { return }
        // Compare with the last published timeline, so one-minute drift adds up.
        if let previousWidget, let snapshot, previousWidget.canKeepTimeline(for: snapshot, at: now) { return }

        previousWidget = snapshot
        if let snapshot, let bytes = try? JSONEncoder().encode(snapshot) {
            defaults.set(bytes, forKey: SurfaceData.widgetKey)
        } else {
            defaults.removeObject(forKey: SurfaceData.widgetKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: SurfaceData.widgetKind)
    }

    private nonisolated static func updateActivity(_ timer: SurfaceTimer?, canCreate: Bool) async throws {
        let activities = Activity<FocusAttributes>.activities
        let matching = activities.first { $0.attributes.session == timer?.identity }
        for activity in activities where activity.id != matching?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let lastKey = "pulse.activity.last"
        guard let timer else {
            UserDefaults.standard.removeObject(forKey: lastKey)
            return
        }
        let state = FocusAttributes.ContentState(
            deadline: timer.deadline, secondsLeft: timer.secondsLeft, title: timer.title, timerRevision: timer.timerRevision,
            resumeDeclined: timer.resumeDeclined ? true : nil)
        let content = ActivityContent(state: state, staleDate: timer.deadline)
        if let matching {
            if matching.content.state != state { await matching.update(content) }
        } else if timer.secondsLeft > 0, ActivityAuthorizationInfo().areActivitiesEnabled, canCreate,
            UserDefaults.standard.string(forKey: lastKey) != timer.identity
        {
            _ = try Activity.request(
                attributes: FocusAttributes(session: timer.identity), content: content, pushType: nil)
            UserDefaults.standard.set(timer.identity, forKey: lastKey)
        }
    }
}
