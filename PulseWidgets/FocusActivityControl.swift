import AppIntents
import Foundation

extension SetFocusTimerIntent {
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        // ActivityKit dispatches LiveActivityIntent to Pulse, which owns the private journal.
        throw CocoaError(.featureUnsupported)
    }
}
