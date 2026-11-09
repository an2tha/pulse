import Foundation
import PulseEngine
import UserNotifications

enum PlanningNotifications {
    static let taskPrefix = "pulse.task."
    static let morning = "pulse.check-in"
    static let recovery = "pulse.recovery."
    static let taskCategory = "pulse.task.actions"
    static let checkCategory = "pulse.check.actions"
    static let planCategory = "pulse.plan.actions"
    static let focusCategory = "pulse.focus.actions"
    static let snooze = "pulse.action.snooze"
    static let open = "pulse.action.open"

    static func register(in center: UNUserNotificationCenter) {
        let visit = UNNotificationAction(
            identifier: open, title: "View task", options: [.foreground, .authenticationRequired])
        let later = UNNotificationAction(
            identifier: snooze, title: "Snooze 15 min", options: [.foreground, .authenticationRequired])
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }
        func action(_ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: open, title: title, options: [.foreground, .authenticationRequired])
        }
        center.setNotificationCategories([
            category(taskCategory, [visit, later]), category(checkCategory, [action("Check in")]),
            category(planCategory, [action("View plan")]), category(focusCategory, [action("Open focus")]),
        ])
    }

    @MainActor static func reconcile(
        preferences: ReminderPreferences, focusAlert: Bool, timer: SurfaceTimer?,
        tasks: [TaskAlert], recovery candidate: Date?, now: Date
    ) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("pulse.") }
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix("pulse.") }
        guard !Task.isCancelled else { return }
        guard preferences.enabled else {
            UserDefaults.standard.removeObject(forKey: "pulse.recovery.scheduled")
            if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)) }
            if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }) }
            return
        }
        let status = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status), !Task.isCancelled else { return }
        let calendar = Calendar.current
        var desired: [String: UNNotificationRequest] = [:]
        var occupied = delivered.filter { $0.request.identifier != FocusReminder.id }.map(\.date)
        if let minute = preferences.morningDeliveryMinute {
            // Repeat at the chosen local clock time even if the next day has a missing hour.
            let time = DateComponents(hour: minute / 60, minute: minute % 60)
            let content = message("Morning check-in", "How are you feeling?", category: checkCategory)
            desired[morning] = UNNotificationRequest(
                identifier: morning, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true))
            let days = Set(
                ([now] + tasks.compactMap { preferences.nextAllowed($0.date) } + [candidate].compactMap { $0 }).map
                { calendar.startOfDay(for: $0) })
            for day in days {
                if let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) {
                    occupied.append(date)
                }
            }
        }
        var explicit: [PlanningAlert] = []
        var candidates: [PlanningAlert] = []
        var payloads: [String: UNMutableNotificationContent] = [:]
        if preferences.taskAlerts {
            for task in tasks {
                let id = taskPrefix + task.id.uuidString
                let original = task.date.timeIntervalSince1970
                if delivered.contains(where: {
                    $0.request.identifier == id && $0.request.content.userInfo["original"] as? Double == original
                }) { continue }
                let content = message("Task reminder", task.title, category: taskCategory)
                content.userInfo["task"] = task.id.uuidString
                let held = pending.first {
                    $0.identifier == id
                        && ($0.content.userInfo["original"] as? Double) == original
                }
                let heldUntil = (held?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                guard let date = task.nextDate(after: now, heldUntil: heldUntil, preferences: preferences) else {
                    if let held, held.content.body == task.title, let instant = fireDate(held), instant <= now,
                       !preferences.isQuiet(instant) {
                        desired[id] = held
                    }
                    continue
                }
                content.userInfo["original"] = original
                payloads[id] = content
                if task.explicit {
                    explicit.append(.init(id: id, date: date))
                } else {
                    candidates.append(.init(id: id, date: date))
                }
            }
        }
        if preferences.recoveryPrompt, let candidate {
            let day = calendar.startOfDay(for: now)
            let id = recovery + String(Int(day.timeIntervalSince1970))
            // Retain the first appointment while automatic replanning moves an unfinished task.
            let prior = pending.first { $0.identifier == id }
            let date =
                (prior?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? candidate.addingTimeInterval(3600)
            let last = UserDefaults.standard.object(forKey: "pulse.recovery.scheduled") as? Date
            if !delivered.contains(where: { $0.request.identifier == id }),
                prior != nil || last.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true,
                calendar.isDate(date, inSameDayAs: now)
            {
                payloads[id] = message(
                    "Time to revisit your plan?", "Move a task, shorten a block or leave today open.",
                    category: planCategory)
                candidates.append(.init(id: id, date: date))
            }
        }
        if focusAlert, let timer {
            if let deadline = timer.deadline, deadline > now, !preferences.isQuiet(deadline) {
                let content = message(
                    "Your focus block is complete", "Take a moment to decide what feels right next.",
                    category: focusCategory)
                content.userInfo = ["task": timer.task.uuidString, "started": timer.started.timeIntervalSince1970]
                desired[FocusReminder.id] = oneTime(FocusReminder.id, content, at: deadline)
                occupied.append(deadline)
            } else if let queued = pending.first(where: { isDueFocusAlert($0, timer: timer, now: now, preferences: preferences) }) {
                desired[FocusReminder.id] = queued
            }
        }
        let requested = explicit.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(48)
        for item in requested {
            guard let content = payloads[item.id] else { continue }
            desired[item.id] = oneTime(item.id, content, at: item.date)
            occupied.append(item.date)
        }
        for reminder in ReminderPolicy.schedule(candidates, after: now, preferences: preferences, occupied: occupied) {
            guard desired.count < 60, let content = payloads[reminder.id] else { continue }
            if reminder.id.hasPrefix(recovery), !calendar.isDate(reminder.date, inSameDayAs: now) { continue }
            desired[reminder.id] = oneTime(reminder.id, content, at: reminder.date)
        }
        guard !Task.isCancelled else { return }
        let cancelled = pending.filter { desired[$0.identifier] == nil }.map(\.identifier)
        if !cancelled.isEmpty { center.removePendingNotificationRequests(withIdentifiers: cancelled) }
        let activeTasks = Dictionary(uniqueKeysWithValues: tasks.map { (taskPrefix + $0.id.uuidString, $0) })
        let obsolete = delivered.filter { note in
            let id = note.request.identifier
            if id.hasPrefix(taskPrefix) {
                guard preferences.taskAlerts, let task = activeTasks[id] else { return true }
                return note.request.content.body != task.title
                    || (note.request.content.userInfo["original"] as? Double) != task.date.timeIntervalSince1970
            }
            if id == FocusReminder.id {
                return !focusAlert || timer?.secondsLeft != 0
                    || note.request.content.userInfo["task"] as? String != timer?.task.uuidString
                    || (note.request.content.userInfo["started"] as? Double) != timer?.started.timeIntervalSince1970
            }
            if id == morning { return !preferences.morningCheckIn }
            if id.hasPrefix(recovery) {
                let today = recovery + String(Int(calendar.startOfDay(for: now).timeIntervalSince1970))
                return !preferences.recoveryPrompt || candidate == nil || id != today
            }
            return false
        }
        if !obsolete.isEmpty { center.removeDeliveredNotifications(withIdentifiers: obsolete.map { $0.request.identifier }) }
        for (id, request) in desired {
            guard !Task.isCancelled else { return }
            if let old = pending.first(where: { $0.identifier == id }), old.content.isEqual(request.content),
                old.trigger?.isEqual(request.trigger) == true
            {
                continue
            }
            do {
                try await center.add(request)
                if id.hasPrefix(recovery) { UserDefaults.standard.set(now, forKey: "pulse.recovery.scheduled") }
            } catch {
                if !Task.isCancelled {
                    Workspace.live.notice = "A reminder couldn’t be scheduled. Review Notifications in Settings."
                }
                return
            }
        }
    }

    private static func message(_ title: String, _ body: String, category: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        return content
    }

    static func isDueFocusAlert(_ request: UNNotificationRequest, timer: SurfaceTimer,
                                now: Date, preferences: ReminderPreferences) -> Bool {
        guard timer.secondsLeft == 0, request.identifier == FocusReminder.id,
              request.content.userInfo["task"] as? String == timer.task.uuidString,
              request.content.userInfo["started"] as? Double == timer.started.timeIntervalSince1970,
              let instant = fireDate(request), !preferences.isQuiet(instant) else { return false }
        // The scheduled deadline rounds up to a whole second. Let an already-due alert finish
        // delivery, but remove a superseded alert for a timer that ended early.
        return instant.timeIntervalSince(now) <= 1
    }

    private static func fireDate(_ request: UNNotificationRequest) -> Date? {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
        let components = trigger.dateComponents
        var calendar = components.calendar ?? .current
        if let zone = components.timeZone { calendar.timeZone = zone }
        return calendar.date(from: components)
    }
    static func oneTime(_ id: String, _ content: UNMutableNotificationContent, at date: Date) -> UNNotificationRequest {
        // A repeated local hour has two instants. UTC components retain the selected one.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        var parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        parts.calendar = utc
        parts.timeZone = utc.timeZone
        return UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
}
