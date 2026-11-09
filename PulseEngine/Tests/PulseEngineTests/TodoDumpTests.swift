import Foundation
import Testing
@testable import PulseEngine

@Suite struct TodoDumpTests {
    @Test func oneLineIsOneTaskAndKeepsUnknownPhrasing() throws {
        let tasks = TodoDump.tasks(from: "  • Study maps for 20 minutes\n\n2. Water the garden for 5 minutes\nCall at 25:90")
        #expect(tasks.count == 3)
        #expect(tasks[0].minutes == 20)
        #expect(tasks[1].minutes == 5)
        #expect(tasks[2].title == "Call at 25:90")
        #expect(tasks[0].energyDemand > tasks[1].energyDemand)
    }

    @Test func availabilityChangesRelativeCostAndRanking() throws {
        var light = PlanTask("Light", minutes: 10)
        var demanding = PlanTask("Demanding", minutes: 10)
        light.energyOverride = 2
        demanding.energyOverride = 8
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        #expect(demanding.energyCost(at: 2) > demanding.energyCost(at: 8))
        #expect(Capacity.priority(light, capacity: 2, at: date) > Capacity.priority(demanding, capacity: 2, at: date))
        #expect(Capacity.priority(light, capacity: 9, at: date) < Capacity.priority(demanding, capacity: 9, at: date))
        let restored = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(demanding))
        #expect(restored.energyOverride == 8 && restored.duplicate().energyOverride == 8)
    }
}
