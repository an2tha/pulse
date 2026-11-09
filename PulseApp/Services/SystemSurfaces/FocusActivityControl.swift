import AppIntents
import Foundation
import PulseEngine

extension SetFocusTimerIntent {
    @MainActor func perform() async throws -> some IntentResult {
        let store = try await Workspace.forShortcut()
        guard store.matchesFocusControl(session: session, revision: revision, resuming: resuming) else {
            return .result()
        }
        if resuming {
            guard await store.refreshLiveCalendar() else {
                if store.matchesFocusControl(session: session, revision: revision, resuming: true) {
                    await store.publishFocusControlResult(declinedResume: (session, revision))
                }
                return .result()
            }
        }
        if store.applyFocusControl(session: session, revision: revision, resuming: resuming) {
            try await store.saveForShortcut()
            await store.publishFocusControlResult()
        } else if resuming, store.matchesFocusControl(session: session, revision: revision, resuming: true) {
            await store.publishFocusControlResult(declinedResume: (session, revision))
        }
        return .result()
    }
}

extension Workspace {
    func matchesFocusControl(session: String, revision: Int, resuming: Bool, at date: Date = .now) -> Bool {
        guard ready, !restoring, !isDemo, systemPreferences.liveTimer, let active = journal.active else { return false }
        return SurfaceData.focusID(task: active.taskID, started: active.started) == session
            && (active.timerRevision ?? 0) == revision
            && (active.wallAnchor == nil) == resuming
            && active.elapsed(now: date, tick: SessionClock.tick, boot: SessionClock.boot) < active.target
    }

    func applyFocusControl(session: String, revision: Int, resuming: Bool, at date: Date = .now) -> Bool {
        guard matchesFocusControl(session: session, revision: revision, resuming: resuming, at: date) else { return false }
        toggleTimer(at: date)
        guard let active = journal.active else { return false }
        return (active.timerRevision ?? 0) != revision
    }
}
