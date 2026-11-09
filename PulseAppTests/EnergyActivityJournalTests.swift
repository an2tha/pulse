import Foundation
import PulseEngine
import Testing
@testable import Pulse

@Suite @MainActor struct EnergyActivityJournalTests {
    @Test func activityEntriesSurviveRenamingDeletionAndPortableRestores() throws {
        let store = Workspace()
        store.ready = true
        store.isDemo = true
        var custom = EnergyActivity(title: "Play piano", minutes: 10, kind: .boost)
        #expect(store.saveEnergyActivity(custom))
        let time = Date(timeIntervalSince1970: 1_740_000_000)
        let entry = EnergyActivityLog(activity: custom, started: time, before: 3)
        #expect(store.recordEnergyActivity(entry, at: time))
        #expect(!store.recordEnergyActivity(entry, at: time))
        #expect(!store.finishEnergyActivity(entry.id, after: 6, at: time.addingTimeInterval(-10)))
        #expect(store.finishEnergyActivity(entry.id, after: 7, at: time.addingTimeInterval(600)))
        #expect(!store.finishEnergyActivity(entry.id, after: 9, at: time.addingTimeInterval(610)))
        custom.title = "Piano practice"
        #expect(store.saveEnergyActivity(custom))
        let bytes = try JournalArchive.backup(store.journal)
        let restored = try JournalArchive.decodeBackup(bytes)
        #expect(restored.customEnergyActivities == [custom] && restored.energyActivityLogs?.first?.activity.title == "Play piano")
        let hours = try #require(TaskAvailability(weekdays: [2], startMinute: 600, endMinute: 660))
        store.journal.timeBlocks = [.init(kind: .focus, hours: hours, boostActivityID: custom.id)]
        #expect(!store.deleteEnergyActivity(custom.id))
        let shared = try SharedJournal(store.journal).applying(to: Journal())
        #expect(shared.customEnergyActivities == [custom] && shared.timeBlocks == store.journal.timeBlocks)
        #expect(shared.energyActivityLogs?.first?.change == 4)
        var legacy = try #require(JSONSerialization.jsonObject(with: SharedJournal(Journal()).encoded()) as? [String: Any])
        legacy["fieldVersion"] = 5
        let incoming = try JSONDecoder().decode(SharedJournal.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(try incoming.applying(to: shared).customEnergyActivities == [custom])
        #expect(try incoming.applying(to: shared).timeBlocks == shared.timeBlocks)
        store.journal.timeBlocks = nil
        #expect(store.deleteEnergyActivity(custom.id))
        #expect(store.journal.energyActivityLogs?.first?.activity.title == "Play piano")
    }
}
