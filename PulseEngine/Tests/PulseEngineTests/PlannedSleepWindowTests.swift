import Foundation
import Testing
@testable import PulseEngine

struct PlannedSleepWindowTests {
    @Test func movingBedtimeKeepsDurationUntilWakeTimeIsSet() throws {
        let initial = PlannedSleepWindow(wake: 420, targetMinutes: 480)
        let shifted = initial.moving(.bedtime, to: 0).moving(.bedtime, to: 15)
        #expect(shifted.wake == 495)
        #expect(shifted.minutes == 480)
        let shorter = shifted.moving(.wake, to: 450)
        #expect(shorter.independent)
        #expect(shorter.bedtime == 15)
        #expect(shorter.minutes == 435)
        let reloaded = try JSONDecoder().decode(PlannedSleepWindow.self, from: JSONEncoder().encode(shorter))
        #expect(reloaded.moving(.bedtime, to: 30).wake == 450)
    }

    @Test func movingWakeFirstWorksAcrossMidnight() {
        let earlier = PlannedSleepWindow(wake: 420, targetMinutes: 480).moving(.wake, to: 390)
        #expect(earlier.bedtime == 1350)
        #expect(!earlier.moving(.bedtime, to: 1350).independent)
        #expect(earlier.moving(.bedtime, to: 1380).minutes == 450)
    }
}
