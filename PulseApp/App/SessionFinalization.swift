import Foundation
import PulseEngine

extension Journal {
    /// Apply the session record and its task progress in the caller's journal transaction.
    mutating func recordFinishedSession(_ a: ActiveSession, done: Bool, at end: Date,
                                        note: String? = nil, nextStepID: UUID? = nil, photo: JournalPhoto? = nil) {
        var record = a.record(now: end, tick: SessionClock.tick, boot: SessionClock.boot, completed: done)
        let seconds = record.seconds
        if !a.isOpenSprint, let i = tasks.firstIndex(where: { $0.id == a.taskID }) {
            if let note { tasks[i].setResumeNote(note) }
            if !done, let returnStep = nextStepID ?? a.stepID {
                tasks[i].rememberStep(returnStep)
            }
            var completed = done
            if let step = a.stepID {
                if done, let index = tasks[i].steps?.firstIndex(where: { $0.id == step }) {
                    tasks[i].steps?[index].done = true
                    completed = tasks[i].steps?.allSatisfy(\.done) == true
                } else {
                    completed = false
                }
            } else if done, let steps = tasks[i].steps {
                tasks[i].steps = steps.map {
                    var step = $0
                    step.done = true
                    return step
                }
            }
            tasks[i].recordFocus(seconds: seconds, completed: completed)
            if tasks[i].resumeStep == nil { tasks[i].rememberStep(nil) }
            record.completedTask = completed
            if !completed, continueTask == true { nextTaskID = a.taskID }
        }
        if var photo {
            photo.completion = photo.completion && record.completedTask == true
            photos = (photos ?? []) + [photo]
        }
        record.finishedAt = end
        sessions.append(record)
        if breaks, (!a.isOpenSprint && done) || seconds >= a.target, tasks.contains(where: { !$0.done }) {
            recovery = Planner.recoveryInterval(
                DateInterval(start: end, duration: 300), at: end, commitments: events)
        }
        active = nil
    }
}
