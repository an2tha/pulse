import UIKit
import UserNotifications

struct FocusDestination: Equatable {
    let task: UUID
    let started: Double
}

extension Workspace {
    func matchesFinishedFocus(task: UUID?, started: Double?) -> Bool {
        guard ready, !restoring, !isDemo, systemPreferences.enabled, journal.notifications,
              let active = journal.active, let started, active.taskID == task else { return false }
        return abs(active.started.timeIntervalSince1970 - started) < 0.001 && elapsed(active) >= active.target
    }
}

@MainActor
final class ReminderDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var destination: FocusDestination?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PlanningNotifications.register(in: UNUserNotificationCenter.current())
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = QuickActionSceneDelegate.self }
        return configuration
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let request = response.notification.request
        var requested: FocusDestination?
        let action = response.actionIdentifier
        let opens = action == UNNotificationDefaultActionIdentifier || action == PlanningNotifications.open
        if opens,
            request.identifier == FocusReminder.id,
            let raw = request.content.userInfo["task"] as? String, let task = UUID(uuidString: raw),
            let started = request.content.userInfo["started"] as? Double
        {
            requested = FocusDestination(task: task, started: started)
        }
        var route: SurfaceDestination?
        if request.identifier.hasPrefix(PlanningNotifications.taskPrefix),
            let raw = request.content.userInfo["task"] as? String, let task = UUID(uuidString: raw),
            request.identifier == PlanningNotifications.taskPrefix + task.uuidString,
            let original = request.content.userInfo["original"] as? Double, original.isFinite,
            opens || action == PlanningNotifications.snooze
        {
            route = .taskReminder(task, original: original, snooze: action == PlanningNotifications.snooze)
        } else if opens && request.identifier == PlanningNotifications.morning {
            route = .checkIn
        } else if opens && request.identifier.hasPrefix(PlanningNotifications.recovery) {
            route = .plan
        }
        // UIKit snapshots the restored scene when this completion is called.
        Task { @MainActor [requested, route] in
            if let requested { destination = requested }
            if let route { PulseSystemRouter.shared.send(route) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let id = notification.request.identifier
        let data = notification.request.content.userInfo
        let task = (data["task"] as? String).flatMap(UUID.init(uuidString:))
        let original = data["original"] as? Double
        let started = data["started"] as? Double
        Task { @MainActor in
            let store = Workspace.live
            let preferences = store.systemPreferences
            guard store.ready, !store.restoring, preferences.enabled, !preferences.isQuiet(.now) else {
                completionHandler([])
                return
            }
            let valid: Bool
            if id == FocusReminder.id {
                valid = store.matchesFinishedFocus(task: task, started: started)
            } else if id.hasPrefix(PlanningNotifications.taskPrefix) {
                if let task, let original {
                    valid = store.taskForReminder(task, original: original) != nil
                } else { valid = false }
            } else if id == PlanningNotifications.morning {
                valid = preferences.morningCheckIn
            } else {
                valid = preferences.recoveryPrompt && store.journal.active == nil && !store.isRestDay
            }
            completionHandler(valid ? [.banner, .sound] : [])
        }
    }

}

enum FocusReminder {
    static let id = "pulse.focus.end"
    static func authorize() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
