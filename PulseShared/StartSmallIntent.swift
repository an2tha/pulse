import AppIntents
import Combine
import Foundation

enum SurfaceDestination: Equatable {
    case today, plan, focus, checkIn, startSmall
    case focusSession(String)
    case captureDistraction(String)
    case taskReminder(UUID, original: Double, snooze: Bool)
}

@MainActor
final class PulseSystemRouter: ObservableObject {
    static let shared = PulseSystemRouter()
    @Published private(set) var request: UUID?
    private var destination: SurfaceDestination?
    func send(_ destination: SurfaceDestination) {
        self.destination = destination
        request = UUID()
    }
    func take(inDemo: Bool = false) -> SurfaceDestination? {
        guard !inDemo || destination == .startSmall else { return nil }
        defer { destination = nil }
        return destination
    }
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "pulseplanner" else { return }
        switch url.host?.lowercased() {
        case "today": send(.today)
        case "plan": send(.plan)
        case "focus":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            if url.path == "/capture" {
                let sessions = items?.filter { $0.name == "session" } ?? []
                if sessions.count == 1, let value = sessions[0].value, !value.isEmpty {
                    send(.captureDistraction(value))
                }
                return
            }
            if let parameter = items?.first(where: { $0.name == "session" }) {
                if let value = parameter.value, !value.isEmpty { send(.focusSession(value)) }
            } else {
                send(.focus)
            }
        case "check-in": send(.checkIn)
        default: break
        }
    }
}

enum SmallFocusDestination: String, AppEnum {
    case smallStep

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.smallStep: "Start small"]
}

struct StartSmallIntent: OpenIntent {
    static let title: LocalizedStringResource = "Start small"
    static let description = IntentDescription("Start a two-minute step or return to your current focus session.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Focus", default: .smallStep) var target: SmallFocusDestination

    @MainActor func perform() async throws -> some IntentResult {
        PulseSystemRouter.shared.send(.startSmall)
        return .result()
    }
}

/// The extension renders the button. ActivityKit runs its action in the app process.
struct SetFocusTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Change focus timer"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "Session") var session: String
    @Parameter(title: "Timer revision") var revision: Int
    @Parameter(title: "Resume") var resuming: Bool

    init() {}
    init(session: String, revision: Int, resuming: Bool) {
        self.session = session
        self.revision = revision
        self.resuming = resuming
    }
}
