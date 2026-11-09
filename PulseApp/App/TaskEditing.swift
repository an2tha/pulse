import Foundation
import PulseEngine

extension PlanTask {
    /// Apply the fields the person edited over the current journal record. A
    /// reminder refresh, completed focus period or separate schedule edit may
    /// have landed since the editor opened.
    func applyingEdits(from original: Self, to current: Self, at date: Date) -> Self {
        var saved = current
        func copy<Value: Equatable>(_ key: WritableKeyPath<Self, Value>) {
            if self[keyPath: key] != original[keyPath: key] { saved[keyPath: key] = self[keyPath: key] }
        }
        copy(\.title)
        copy(\.category)
        copy(\.icon)
        copy(\.requiresPhotoProof)
        copy(\.done)
        copy(\.due)
        copy(\.reminder)
        copy(\.plannedStart)
        copy(\.after)
        copy(\.availability)
        copy(\.preparation)
        copy(\.inboxOnly)
        copy(\.dependency)
        copy(\.project)
        copy(\.notes)
        copy(\.meaningful)
        copy(\.energyOverride)
        copy(\.importance)
        copy(\.effort)
        copy(\.overwhelm)
        copy(\.setup)
        if minutes != original.minutes {
            saved.timelineDurations = nil
            saved.minutes = minutes
            saved.originalMinutes = minutes
        }
        if resumeNote != original.resumeNote { saved.setResumeNote(resumeNote ?? "") }
        if steps != original.steps {
            let before = Dictionary(uniqueKeysWithValues: (original.steps ?? []).map { ($0.id, $0) })
            let drafts = Dictionary(uniqueKeysWithValues: (steps ?? []).map { ($0.id, $0) })
            var merged = (current.steps ?? []).compactMap { step -> TaskStep? in
                guard let old = before[step.id] else { return step }
                guard let draft = drafts[step.id] else { return nil }
                var updated = step
                if draft.title != old.title { updated.title = draft.title }
                if draft.done != old.done { updated.done = draft.done }
                return updated
            }
            let kept = Set(merged.map(\.id))
            merged += (steps ?? []).filter { !kept.contains($0.id) && before[$0.id] != $0 }
            saved.steps = merged
        }
        if repeated != original.repeated || repeatDays != original.repeatDays {
            if repeated != current.repeated { saved.routineExceptions = nil }
            saved.repeated = repeated
            saved.repeatDays = repeatDays
            if saved.repeatDays != current.repeatDays {
                saved.alignFirstRepeatDay(at: date)
                saved.pruneRepeatExceptions()
            }
        }
        return saved
    }
}
