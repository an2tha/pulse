import Combine
import UIKit

/// UIKit delivers an icon shortcut to the scene that the user opened. Keeping
/// it on that scene lets onboarding finish before a specific journal handles it.
@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    enum Action: String {
        case startSmall = "app.pulseplanner.pulse.start-small"
        case capture = "app.pulseplanner.pulse.capture"
        case checkIn = "app.pulseplanner.pulse.check-in"
    }

    @Published private(set) var request: UUID?
    private var action: Action?

    private func receive(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard let action = Action(rawValue: shortcut.type) else { return false }
        self.action = action
        request = UUID()
        return true
    }

    func take(_ id: UUID) -> Action? {
        guard request == id else { return nil }
        defer { action = nil }
        return action
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let shortcut = options.shortcutItem { _ = receive(shortcut) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        receive(shortcutItem)
    }
}
