import Foundation
import PulseEngine

extension Journal {
    mutating func importSharedCaptures(_ captures: [SharedCapture]) {
        var known = Set(tasks.map(\.id)).union(importedShares ?? [])
        for item in captures where known.insert(item.id).inserted {
            if let jpeg = item.jpeg, !JournalPhoto.fits(jpeg, in: self) { continue }
            let lines = item.text.split(separator: "\n", maxSplits: 1)
            let first = lines.first.map(String.init) ?? item.text
            var task = PlanTask(String(first.prefix(140)), minutes: 10, category: .personal, id: item.id)
            if first.count > 140 {
                task.notes = item.text
            } else if lines.count > 1 {
                task.notes = String(lines[1])
            }
            if item.distraction == true {
                task.inboxOnly = true
                task.capturedDuringSessionID = localSprint(at: item.created)
                if let caption = item.timingCaption { applyShareTiming(caption, from: item, to: &task) }
            }
            task.sourceURL = item.url
            task.createdAt = item.created
            if let jpeg = item.jpeg {
                task.done = item.alreadyCompleted == true
                task.completedAt = task.done ? item.created : nil
                let photo = JournalPhoto(id: item.id, date: item.created, taskID: task.id, title: task.title,
                                         completion: task.done, jpeg: jpeg)
                if photos == nil { photos = [] }
                photos?.append(photo)
            }
            tasks.append(task)
            if importedShares == nil { importedShares = [] }
            importedShares?.insert(item.id)
            starterAvailable = false
        }
    }

    mutating func beginLocalSession(_ session: ActiveSession) {
        active = session
        observeLocalSession(at: session.started)
    }

    /// Restoring a timer establishes local ownership only from this instant.
    @discardableResult
    mutating func observeLocalSession(at observed: Date) -> Bool {
        guard var session = active else { return false }
        let id = session.sessionID ?? UUID()
        guard localSprintStarts?[id] == nil else { return false }
        session.sessionID = id
        active = session
        if localSprintStarts == nil { localSprintStarts = [:] }
        localSprintStarts?[id] = max(observed, session.started)
        return true
    }

    private func localSprint(at date: Date) -> UUID? {
        var matches = Set<UUID>()
        guard let localSprintStarts else { return nil }
        if let active, let id = active.sessionID, let observed = localSprintStarts[id], observed <= date {
            matches.insert(id)
        }
        for session in sessions where session.start <= date {
            if let observed = localSprintStarts[session.id], observed <= date, let finish = session.finishedAt, date < finish {
                matches.insert(session.id)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func applyShareTiming(_ caption: String, from item: SharedCapture, to task: inout PlanTask) {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = item.timeZoneID.flatMap(TimeZone.init(identifier:)) else { return }
        calendar.timeZone = zone
        // The source title, text, link and image are never passed to the timing parser.
        let anchor = "Shared item"
        let result = LocalDayInput.parse(anchor + " " + caption, at: item.created, calendar: calendar,
                                         commitments: events, singleTimesAreTaskPins: true)
        if result.tasks.count == 1, result.unrecognized.isEmpty, result.commitments.isEmpty,
           let timing = result.tasks.first, timing.title == anchor {
            task.minutes = timing.minutes
            task.originalMinutes = timing.originalMinutes
            task.plannedStart = timing.plannedStart
            task.due = timing.due
            task.after = timing.after
            task.repeated = timing.repeated
            task.repeatDays = timing.repeatDays
            task.routineAnchor = timing.routineAnchor
            task.availability = timing.availability
            if !task.hasSchedulingInstruction, caption.range(of: #"(?i)\btoday\b"#, options: .regularExpression) != nil {
                task.after = calendar.startOfDay(for: item.created)
            }
            task.inboxOnly = task.hasSchedulingInstruction ? nil : true
        } else {
            task.notes = [task.notes, caption].compactMap { $0 }.joined(separator: "\n")
        }
    }
}
