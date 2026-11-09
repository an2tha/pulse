import Foundation
import Testing
@testable import PulseEngine

struct StimulantTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    @Test func labeledDosesAccumulateAndUnknownAmountsStayUnknown() {
        let first = StimulantIntake(substance: .caffeine, source: "Coffee", date: base, milligrams: 100)
        var second = StimulantIntake(substance: .caffeine, source: "Matcha", date: base.addingTimeInterval(14400), milligrams: 25)
        #expect(StimulantHistory.modeledAmount(.caffeine, entries: [first, second], at: second.date) == 75)
        second.milligrams = nil
        #expect(StimulantHistory.modeledAmount(.caffeine, entries: [first, second], at: second.date) == nil)
        #expect(StimulantHistory.modeledAmount(.nicotine, entries: [], at: base) == nil)
    }
    @Test func labScenarioRequiresConfirmedMeasurementAndStopsAtOtherExposures() {
        var lab = StimulantBloodSample(substance: .nicotine, date: base, nanogramsPerML: 10, postAbsorption: false)
        let later = base.addingTimeInterval(7200)
        #expect(StimulantHistory.projectedBlood(lab, at: later, samples: [lab], entries: []) == nil)
        lab.postAbsorption = true
        #expect(StimulantHistory.projectedBlood(lab, at: later, samples: [lab], entries: []) == 5)
        let patch = StimulantIntake(substance: .nicotine, source: "Nicotine patch", date: base.addingTimeInterval(-3600))
        #expect(StimulantHistory.projectedBlood(lab, at: later, samples: [lab], entries: [patch]) == nil)
        let other = StimulantBloodSample(substance: .nicotine, date: later, nanogramsPerML: 8, postAbsorption: false)
        #expect(StimulantHistory.projectedBlood(lab, at: later, samples: [lab, other], entries: []) == nil)
    }
    @Test func personalForecastUsesOnlyComparableObservedResponses() {
        var rows: [StimulantIntake] = []
        for i in 0..<4 {
            let date = base.addingTimeInterval(Double(i) * 86400)
            var row = StimulantIntake(substance: .caffeine, source: "Coffee", date: date, milligrams: 90, baselineEnergy: 4)
            if i < 3 { row.responseTime = date.addingTimeInterval(3600); row.responseEnergy = 6 }
            rows.append(row)
        }
        let latest = rows[3]
        let matches = StimulantHistory.comparableResponses(to: latest, entries: rows, after: 1, asOf: latest.date)
        #expect(StimulantHistory.medianChange(matches) == 2)
        rows.append(.init(substance: .nicotine, source: "Nicotine gum", date: latest.date))
        #expect(StimulantHistory.comparableResponses(to: latest, entries: rows, after: 1, asOf: latest.date).isEmpty)
        #expect(StimulantHistory.alongside(latest, entries: rows).count == 1)
    }
}
