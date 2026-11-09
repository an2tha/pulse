import EventKit
import Foundation
import PulseEngine
import Testing

@testable import Pulse

@Suite @MainActor struct LiveReminderTests {
    private func item(_ id: String, title: String = "Buy fruit", list: String = "A", external: String? = nil,
                      due: Date? = nil, completed: Bool = false) -> ReminderCandidate {
        ReminderCandidate(id: CalendarBridge.stableID(list + (external ?? id)), title: title, list: list,
                          listID: list, itemID: id, accountKey: external.map(CalendarBridge.stableID), due: due, completed: completed)
    }

    @Test func newRemindersFollowTheirDueDatesAndKeepLocalEdits() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        var journal = Journal()
        let early = [item("1"), item("2", list: "B", due: due)]
        let imported = journal.importReminders(early)
        #expect(imported)
        #expect(journal.tasks.map(\.isInboxOnly) == [true, false])
        let reimported = journal.importReminders(early)
        #expect(!reimported)
        journal.tasks[1].due = due.addingTimeInterval(900)
        journal.tasks[1].title = "My title"
        journal.tasks[1].notes = "Keep this"
        journal.tasks[1].plannedStart = due.addingTimeInterval(-3600)
        let later = [item("1", title: "Apples", due: due), item("2", title: "Pears", list: "B")]
        let updated = journal.importReminders(later)
        #expect(updated)
        #expect(journal.tasks[0].title == "Apples" && !journal.tasks[0].isInboxOnly && journal.tasks[0].due == due)
        #expect(journal.tasks[1].title == "My title" && journal.tasks[1].due == due.addingTimeInterval(900))
        #expect(journal.tasks[1].notes == "Keep this" && journal.tasks[1].plannedStart == due.addingTimeInterval(-3600))
        journal.importReminders([item("1", title: "Apples")])
        #expect(journal.tasks[0].isInboxOnly)
    }

    @Test func movesDeletionsAndDuplicateExternalIDs() throws {
        var journal = Journal()
        let first = item("1", external: "cloud")
        journal.importReminders([first])
        let moved = item("1b", list: "B", external: "cloud")
        journal.importReminders([moved])
        #expect(journal.tasks.map(\.id) == [first.id])
        journal.tasks = []
        let restored = try JournalArchive.readDatabase(JournalArchive.database(journal))
        journal = restored
        let resurrected = journal.importReminders([moved])
        #expect(!resurrected)
        #expect(journal.tasks.isEmpty)
        journal.importReminders([moved], manual: true)
        #expect(journal.tasks.map(\.id) == [first.id])
        #expect(try JournalArchive.decodeBackup(JournalArchive.backup(journal)).reminderImports == nil)
        var collisions = Journal()
        let pair = [item("a", external: "same"), item("b", external: "same")]
        collisions.importReminders(pair)
        #expect(Set(collisions.tasks.map(\.id)).count == 2)
        let duplicated = collisions.importReminders(pair.reversed())
        #expect(!duplicated)
    }

    @Test func previouslyImportedTasksKeepTheirManualChanges() {
        let reminder = item("legacy")
        var task = PlanTask("Changed in Pulse", minutes: 35, category: .focus, id: reminder.id)
        task.notes = "Personal edits"
        var journal = Journal()
        journal.tasks = [task]
        journal.importReminders([reminder])
        journal.importReminders([item("legacy", title: "Changed in Reminders")])
        #expect(journal.tasks == [task])
        #expect(journal.reminderImports?[task.id]?.itemID == reminder.itemID)
    }

    @Test func chosenListsAreOptInAndPersistOnThisDevice() throws {
        let name = "reminder-selection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LiveReminderSelection(defaults: defaults)
        #expect(settings.sources.isEmpty)
        settings.sources = ["one", "two"]
        #expect(LiveReminderSelection(defaults: defaults).sources == ["one", "two"])
        settings.sources.remove("one")
        #expect(LiveReminderSelection(defaults: defaults).sources == ["two"])
    }

    @Test func sourceCompletionRespectsEditsActiveFocusAndDeletion() {
        var journal = Journal()
        journal.importReminders(["1", "2", "3", "4"].map { item($0) })
        journal.tasks[1].minutes = 22
        journal.active = ActiveSession(task: journal.tasks[2], minutes: 2, now: .now, tick: 10, boot: nil)
        let completed = ["1", "2", "3"].map { item($0, completed: true) }
        journal.importReminders(completed, missing: ["4"])
        #expect(journal.tasks.map(\.done) == [true, false, false, false])
        journal.tasks[0].done = false
        journal.active = nil
        journal.importReminders(completed)
        #expect(journal.tasks.map(\.done) == [false, false, true, false])
    }

    @Test func dateOnlyAndFloatingRemindersUseLocalTimeAcrossSpringForward() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var day = DateComponents(year: 2026, month: 3, day: 29)
        let end = try #require(CalendarBridge.reminderDue(day, local: calendar))
        #expect(calendar.component(.hour, from: end) == 23)
        #expect(calendar.component(.second, from: end) == 59)
        day.hour = 9
        let morning = try #require(CalendarBridge.reminderDue(day, local: calendar))
        #expect(calendar.component(.hour, from: morning) == 9)
        day.timeZone = .gmt
        let utc = try #require(CalendarBridge.reminderDue(day, local: calendar))
        #expect(utc.timeIntervalSince(morning) == 7200)
    }
}
