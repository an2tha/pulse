import AppIntents
import Foundation
import PulseEngine
import SwiftUI

extension Workspace {
    static let live = Workspace()
    @MainActor static func forShortcut() async throws -> Workspace {
        let store = Workspace.live
        await store.load()
        for _ in 0..<100 where !store.ready && store.loadFailure == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard store.ready else { throw ShortcutIssue.unavailable }
        return store
    }
    func taskForReminder(_ id: UUID, original: Double) -> PlanTask? {
        guard !isDemo, ready, !restoring, systemPreferences.enabled, systemPreferences.taskAlerts,
              let task = journal.tasks.first(where: { $0.id == id && !$0.done && $0.archived != true }),
              let current = task.reminder ?? task.due,
              max(current, task.after ?? .distantPast).timeIntervalSince1970 == original else { return nil }
        return task
    }

    func snoozeSystemReminder(_ id: UUID, original: Double) {
        guard taskForReminder(id, original: original) != nil else { return }
        change { journal in
            if let index = journal.tasks.firstIndex(where: { $0.id == id }) {
                journal.tasks[index].reminder = Date.now.addingTimeInterval(15 * 60)
            }
        }
    }
}

private enum ShortcutIssue: LocalizedError {
    case unavailable, empty, noBlock
    var errorDescription: String? {
        switch self {
        case .unavailable: "Open Pulse to load your journal, then try again."
        case .empty: "Enter a task name."
        case .noBlock: "There is no focus block available now."
        }
    }
}

struct CapturePulseTask: AppIntent {
    static let title: LocalizedStringResource = "Capture a task"
    static let description = IntentDescription("Add a task to your Pulse inbox on this device.")
    static let openAppWhenRun = true
    @Parameter(title: "Task") var task: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await Workspace.forShortcut()
        guard let draft = InboxCaptureDraft(task, at: .now, commitments: store.planningEvents),
              store.captureTask(draft.task) != nil else { throw ShortcutIssue.empty }
        try await store.saveForShortcut()
        if let timing = draft.task.captureTiming {
            return .result(dialog: "Added to your Pulse inbox. \(timing)")
        }
        if draft.unresolved { return .result(dialog: "Added as written, without a time.") }
        return .result(dialog: "Added to your Pulse inbox.")
    }
}

struct StartPulseFocus: AppIntent {
    static let title: LocalizedStringResource = "Start next focus block"
    static let description = IntentDescription("Start the next eligible task or a short open sprint when there is room.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await Workspace.forShortcut()
        if store.journal.active == nil {
            await store.refreshLiveCalendar()
            store.regenerate()
            await store.waitForCurrentPlan()
            if let (task, block) = store.next, store.canStart(block) {
                store.start(task, block: block)
            } else {
                store.startOpenSprint()
            }
            guard store.journal.active != nil else { throw ShortcutIssue.noBlock }
        }
        PulseSystemRouter.shared.send(.focus)
        return .result(dialog: "Your focus session is ready.")
    }
}

struct CaptureFocusThought: AppIntent {
    static let title: LocalizedStringResource = "Capture a distraction"
    static let description = IntentDescription("Save a thought to your inbox and link it to the current sprint.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Thought") var thought: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await Workspace.forShortcut()
        guard let draft = InboxCaptureDraft(thought, at: .now, commitments: store.planningEvents, distraction: true) else {
            throw ShortcutIssue.empty
        }
        let session = store.journal.active
        guard store.captureTask(draft.task, focusSession: session, distraction: true) != nil else { throw ShortcutIssue.unavailable }
        try await store.saveForShortcut()
        if let timing = draft.task.captureTiming ?? draft.task.captureRecurrence() {
            if session != nil { return .result(dialog: "Saved with your sprint. \(timing)") }
            return .result(dialog: "Added to your plan. \(timing)")
        }
        if session != nil { return .result(dialog: "Saved to your inbox with this sprint.") }
        return .result(dialog: "Saved to your Pulse inbox.")
    }
}

struct OpenPulseCheckIn: AppIntent {
    static let title: LocalizedStringResource = "Open check-in"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        PulseSystemRouter.shared.send(.checkIn)
        return .result()
    }
}

struct PulseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CapturePulseTask(),
            phrases: ["Capture a task in \(.applicationName)", "Add a task to \(.applicationName)"],
            shortTitle: "Capture task", systemImageName: "tray.and.arrow.down")
        AppShortcut(
            intent: StartSmallIntent(), phrases: ["Start small in \(.applicationName)"], shortTitle: "Start small",
            systemImageName: "figure.walk")
        AppShortcut(
            intent: CaptureFocusThought(), phrases: ["Capture a distraction in \(.applicationName)", "Park a thought in \(.applicationName)"],
            shortTitle: "Capture distraction", systemImageName: "tray.and.arrow.down")
        AppShortcut(
            intent: StartPulseFocus(), phrases: ["Start focus in \(.applicationName)"], shortTitle: "Start focus",
            systemImageName: "hourglass")
        AppShortcut(
            intent: OpenPulseCheckIn(), phrases: ["Check in with \(.applicationName)"], shortTitle: "Check in",
            systemImageName: "sun.horizon")
    }
}
