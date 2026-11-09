import Foundation
import PulseEngine
import Testing
@testable import Pulse

struct StimulantPersistenceTests {
    @Test func portableBackupRetainsEntriesAndPrivateSyncLeavesThemLocal() throws {
        var journal = Journal()
        var intake = StimulantIntake(substance: .nicotine, source: "Nicotine vape", date: Date(timeIntervalSince1970: 1_700_000_000), milligrams: 5)
        intake.liquidVolumeML = 0.5
        intake.productName = "Personal sample product"
        journal.stimulantIntakes = [intake]
        journal.stimulantBloodSamples = [StimulantBloodSample(substance: .cotinine, date: intake.date, nanogramsPerML: 57, postAbsorption: false)]
        let restored = try JournalArchive.decodeBackup(JournalArchive.backup(journal))
        #expect(restored.stimulantIntakes == journal.stimulantIntakes)
        #expect(restored.stimulantBloodSamples == journal.stimulantBloodSamples)
        #expect(intake.comparableAmount == 2.5)
        #expect(!String(decoding: try SharedJournal(journal).encoded(), as: UTF8.self).contains("Personal sample product"))
        #expect(try SharedJournal(Journal()).applying(to: journal).stimulantIntakes == journal.stimulantIntakes)
        var invalid = journal
        invalid.stimulantIntakes?[0].milligrams = -1
        #expect(throws: Error.self) { try JournalArchive.validate(invalid) }
    }
}
