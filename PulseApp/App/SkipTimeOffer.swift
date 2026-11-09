import Foundation
import PulseEngine

struct SkipTimeOffer: Equatable {
    let start: Date
    let minutes: Int
    let reason: String
    let forecastScore: Double?
    fileprivate let familyID: UUID
    fileprivate let task: PlanTask
    fileprivate let surveyIDs: [UUID]
    fileprivate let epoch: UUID
}

private enum SkipSuggestionError: LocalizedError {
    case changed, calendarUnavailable

    var errorDescription: String? {
        switch self {
        case .changed: "Your plan has changed. Check for a new time."
        case .calendarUnavailable: "Your calendar couldn’t update. Try again."
        }
    }
}

extension Workspace {
    func skipPatterns(through day: Date) -> [TaskSkipPattern] {
        TaskSkipPattern.repeated(in: journal.taskSkips ?? [], tasks: journal.tasks, through: day,
                                 now: .now, activeTaskID: journal.active?.taskID)
    }

    func skipTimeSuggestion(for pattern: TaskSkipPattern) async throws -> SkipTimeOffer? {
        guard ready, !restoring, let id = pattern.targetTaskID, let task = timingTask(id),
              journal.active?.taskID != id, !task.isInboxOnly,
              skipPatterns(through: .now).first(where: { $0.id == pattern.id }) == pattern
        else { throw SkipSuggestionError.changed }
        guard SkipTimingRecommendation.hasTimingEvidence(in: pattern.records) else { return nil }
        let epoch = journalEpoch
        if !calendarReadyForStart { _ = await refreshLiveCalendar() }
        try Task.checkCancellation()
        guard epoch == journalEpoch, task == timingTask(id) else { throw SkipSuggestionError.changed }
        guard calendarReadyForStart else { throw SkipSuggestionError.calendarUnavailable }

        let ticket = generation
        let revision = healthController.revision
        let options = await weekPlacements(for: id)
        try Task.checkCancellation()
        guard generation == ticket, revision == healthController.revision else { throw SkipSuggestionError.changed }
        guard !options.isEmpty else { return nil }
        let original = options.first?.originalStart ?? task.plannedStart.flatMap { $0 > Date.now ? $0 : nil }
        var baseline: TaskPlacement?
        if let original {
            baseline = options.first { $0.start == original }
            if baseline == nil {
                baseline = await weekPlacements(for: id, exactStart: original).first { $0.start == original }
            }
            guard baseline != nil else { return nil }
        }
        try Task.checkCancellation()
        guard epoch == journalEpoch, generation == ticket, healthController.revision == revision,
              calendarReadyForStart else { throw SkipSuggestionError.changed }
        let effective = task.planningCopy(with: planningEvents, bufferMinutes: preferences.bufferMinutes)
        guard let suggestion = SkipTimingRecommendation.find(in: options, current: baseline, for: effective) else { return nil }
        let slot = suggestion.placement
        return SkipTimeOffer(start: slot.start, minutes: slot.minutes, reason: suggestion.reason,
                             forecastScore: slot.forecastScore, familyID: pattern.id, task: task,
                             surveyIDs: pattern.records.map(\.id), epoch: epoch)
    }

    func applySkipTimeSuggestion(_ offer: SkipTimeOffer) async throws {
        guard offer.epoch == journalEpoch, offer.task == timingTask(offer.task.id),
              let pattern = skipPatterns(through: .now).first(where: { $0.id == offer.familyID }),
              pattern.targetTaskID == offer.task.id, pattern.records.map(\.id) == offer.surveyIDs,
              let refreshed = try await skipTimeSuggestion(for: pattern),
              refreshed == offer else { throw SkipSuggestionError.changed }

        // Commit the specific time the person reviewed, rechecking live conflicts at that instant.
        guard await moveWeekTask(offer.task.id, day: offer.start, hour: offer.start, exactStart: true)
        else { throw SkipSuggestionError.changed }
    }
}
