import Foundation
import Testing
@testable import Pulse

struct LandscapeThemeTests {
    @Test func olderJournalsAndUnknownPacksUsePastelPainting() throws {
        let data = try JSONEncoder().encode(Journal())
        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "landscapeTheme")
        let legacy = try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(LandscapeTheme.resolve(legacy.landscapeTheme) == .pastelPainting)
        #expect(LandscapeTheme.resolve("future-pack") == .pastelPainting)
    }

    @Test(arguments: LandscapeTheme.allCases)
    func themeSurvivesJournalExport(theme: LandscapeTheme) throws {
        var journal = Journal()
        journal.landscapeTheme = theme.rawValue
        journal.atmosphere = Atmosphere.night.rawValue
        let restored = try JournalArchive.readDatabase(JournalArchive.database(journal))
        #expect(LandscapeTheme.resolve(restored.landscapeTheme) == theme)
        #expect(restored.atmosphere == Atmosphere.night.rawValue)
    }
}
