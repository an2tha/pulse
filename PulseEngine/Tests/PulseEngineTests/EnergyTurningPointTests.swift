import Foundation
import Testing
@testable import PulseEngine

struct EnergyTurningPointTests {
    private func markers(_ scores: [Double]) -> [EnergyTurningPoint] {
        let points = scores.enumerated().map {
            EnergyPoint(date: Date(timeIntervalSince1970: Double($0.offset) * 3600),
                        score: $0.element, source: .rhythm, supportDays: 0)
        }
        return EnergyTurningPoint.find(in: points)
    }

    @Test func flatAndMonotonicDaysHaveNoInventedExtrema() {
        #expect(markers([6, 6, 6, 6]).isEmpty)
        #expect(markers([2, 3, 4, 5]).isEmpty)
        #expect(markers([5, 5.1, 5]).isEmpty)
    }

    @Test func plateauAndDipFollowThePlottedEstimates() {
        let result = markers([3, 6, 6, 6, 4, 3, 5])
        #expect(result.map(\.kind) == [.peak, .dip])
        #expect(result.map { $0.id.timeIntervalSince1970 } == [7200, 18000])
    }
}
