import Foundation

public enum Stimulant: String, Codable, CaseIterable, Identifiable, Sendable {
    case caffeine = "Caffeine", nicotine = "Nicotine", theobromine = "Theobromine", paraxanthine = "Paraxanthine", cotinine = "Cotinine", other = "Other nonprescription"
    public var id: Self { self }

    public var sources: [String] {
        switch self {
        case .caffeine:
            ["Coffee", "Espresso", "Cold brew", "Black tea", "Green tea", "Matcha", "White tea", "Oolong",
             "Yerba mate", "Guayusa", "Guarana", "Kola nut", "Cola", "Energy drink", "Cocoa", "Chocolate",
             "Caffeinated gum", "Caffeinated mint", "Sports gel", "Labeled caffeine supplement"]
        case .nicotine: ["Nicotine gum", "Nicotine lozenge", "Nicotine patch", "Cigarette", "Nicotine vape"]
        case .theobromine: ["Cocoa", "Dark chocolate", "Milk chocolate", "Cacao nibs", "Cacao drink"]
        case .paraxanthine, .cotinine: []
        case .other: ["Labeled nonprescription product"]
        }
    }

    // Population estimates for an illustrative post-absorption scenario.
    public var halfLifeHours: Double? {
        switch self {
        case .caffeine: 4
        case .nicotine: 2
        case .theobromine: 6.1
        case .paraxanthine: 3.1
        case .cotinine: 16
        case .other: nil
        }
    }
}

public enum PerceivedStimulantEffect: String, CaseIterable, Codable, Sendable {
    case weaker = "Weaker than usual", usual = "Usual", stronger = "Stronger than usual"
}

public enum StimulantLabelUnit: String, Codable, Sendable {
    case milligrams = "mg", liquid = "mg/mL", patch16 = "mg/16 h", patch24 = "mg/24 h"
}

public struct StimulantIntake: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var substance: Stimulant
    public var source: String
    public var date: Date
    /// Labeled ingredient amount. Nil represents an unknown quantity.
    public var milligrams: Double?
    public var labelUnit: StimulantLabelUnit?
    public var liquidVolumeML: Double?
    public var ended: Date?
    public var productName: String?
    public var notes: String
    public var coUseNote: String?
    public var perceivedEffect: PerceivedStimulantEffect?
    public var baselineEnergy: Int?
    public var responseEnergy: Int?
    public var responseTime: Date?

    public init(id: UUID = UUID(), substance: Stimulant, source: String, date: Date, milligrams: Double? = nil,
                ended: Date? = nil, notes: String = "", baselineEnergy: Int? = nil) {
        self.id = id
        self.substance = substance
        self.source = source
        self.date = date
        self.milligrams = milligrams
        labelUnit = source == "Nicotine vape" ? .liquid : source == "Nicotine patch" ? .patch24 : nil
        self.ended = ended
        self.notes = notes
        self.baselineEnergy = baselineEnergy
    }
    public var unit: StimulantLabelUnit { labelUnit ?? .milligrams }
    public var comparableAmount: Double? {
        guard let milligrams, milligrams > 0, !isPatch else { return nil }
        if unit == .milligrams { return milligrams }
        guard unit == .liquid, let liquidVolumeML, liquidVolumeML > 0 else { return nil }
        let total = milligrams * liquidVolumeML
        return total.isFinite ? total : nil
    }
    public var supportedUnits: [StimulantLabelUnit] {
        switch source {
        case "Nicotine vape": [.liquid, .milligrams]
        case "Nicotine patch": [.patch24, .patch16, .milligrams]
        default: [.milligrams]
        }
    }
    public var displayName: String { productName.flatMap { $0.isEmpty ? nil : $0 } ?? source }
    public var isPatch: Bool { substance == .nicotine && source == "Nicotine patch" }
    public var isValid: Bool {
        (substance != .other || productName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) &&
        substance.sources.contains(source) && supportedUnits.contains(unit) &&
        (liquidVolumeML.map { unit == .liquid && $0.isFinite && $0 > 0 } ?? true) && date.timeIntervalSinceReferenceDate.isFinite &&
        (milligrams.map { $0.isFinite && $0 > 0 } ?? true) &&
        (ended.map { isPatch && $0 >= date && $0.timeIntervalSinceReferenceDate.isFinite } ?? true) &&
        (baselineEnergy.map { (0...10).contains($0) } ?? true) &&
        (responseEnergy.map { (0...10).contains($0) } ?? true) &&
        ((responseTime == nil && responseEnergy == nil) ||
         (baselineEnergy != nil && responseEnergy != nil && responseTime.map { $0 > date && $0.timeIntervalSinceReferenceDate.isFinite } == true))
    }
}

public struct StimulantBloodSample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var substance: Stimulant
    public var date: Date
    public var nanogramsPerML: Double
    public var postAbsorption: Bool

    public init(id: UUID = UUID(), substance: Stimulant, date: Date, nanogramsPerML: Double, postAbsorption: Bool) {
        self.id = id
        self.substance = substance
        self.date = date
        self.nanogramsPerML = nanogramsPerML
        self.postAbsorption = postAbsorption
    }
    public var isValid: Bool { substance != .other && date.timeIntervalSinceReferenceDate.isFinite && nanogramsPerML.isFinite && nanogramsPerML >= 0 }
}

public enum StimulantHistory {
    public static func fractionRemaining(hours: Double, halfLife: Double) -> Double {
        guard hours.isFinite, hours >= 0, halfLife.isFinite, halfLife > 0 else { return 0 }
        return pow(0.5, hours / halfLife)
    }

    /// A dose-based clearance illustration for known dietary amounts. It cannot
    /// determine absorbed nicotine, missing amounts, blood levels or safe redosing.
    public static func modeledAmount(_ substance: Stimulant, entries: [StimulantIntake], at date: Date, halfLifeHours: Double? = nil) -> Double? {
        guard let halfLife = halfLifeHours ?? substance.halfLifeHours, (substance == .caffeine || substance == .theobromine), halfLife > 0, halfLife.isFinite else { return nil }
        let recent = entries.filter {
            $0.substance == substance && $0.date <= date && date.timeIntervalSince($0.date) <= 7 * 86400
        }
        guard !recent.isEmpty, recent.allSatisfy({ $0.isValid && $0.milligrams != nil }) else { return nil }
        let total = recent.reduce(0.0) { value, entry in
            value + (entry.milligrams ?? 0) * fractionRemaining(hours: date.timeIntervalSince(entry.date) / 3600, halfLife: halfLife)
        }
        return total.isFinite ? total : nil
    }

    public static func projectedBlood(_ sample: StimulantBloodSample, at date: Date,
                                      samples: [StimulantBloodSample], entries: [StimulantIntake]) -> Double? {
        guard let halfLife = sample.substance.halfLifeHours, sample.isValid, sample.postAbsorption, date >= sample.date,
              date.timeIntervalSince(sample.date) <= 24 * 3600,
              !samples.contains(where: { $0.substance == sample.substance && $0.date > sample.date && $0.date <= date }),
              !entries.contains(where: { entry in
                  let related = entry.substance == sample.substance ||
                    (entry.substance == .caffeine && [.theobromine, .paraxanthine].contains(sample.substance)) ||
                    (entry.substance == .nicotine && sample.substance == .cotinine)
                  return related && entry.date <= date &&
                    (entry.date >= sample.date || (entry.isPatch && (entry.ended ?? .distantFuture) >= sample.date))
              }) else { return nil }
        return sample.nanogramsPerML * fractionRemaining(hours: date.timeIntervalSince(sample.date) / 3600, halfLife: halfLife)
    }

    public static func alongside(_ entry: StimulantIntake, entries: [StimulantIntake]) -> [StimulantIntake] {
        func window(_ item: StimulantIntake) -> ClosedRange<Date> {
            let end = item.isPatch ? (item.ended ?? .distantFuture) : item.date.addingTimeInterval(2 * 3600)
            return item.date...max(item.date, end)
        }
        return entries.filter { $0.id != entry.id && ($0.substance != entry.substance || (entry.substance == .other && $0.displayName != entry.displayName)) && window($0).overlaps(window(entry)) }
            .sorted { $0.date < $1.date }
    }

    /// Match the same product, similar labeled amount and follow-up interval.
    /// Exclude co-use and repeated intake, which make a response difficult to attribute.
    public static func comparableResponses(to entry: StimulantIntake, entries: [StimulantIntake],
                                           after hours: Double, asOf now: Date) -> [StimulantIntake] {
        guard let mg = entry.comparableAmount, hours > 0,
              !entries.contains(where: { other in
                  other.id != entry.id && other.date <= min(now, entry.date.addingTimeInterval(hours * 3600)) &&
                    (other.date >= entry.date.addingTimeInterval(-2 * 3600) ||
                     (other.isPatch && (other.ended ?? .distantFuture) >= entry.date))
              }) else { return [] }
        return entries.filter { prior in
            guard prior.id != entry.id, prior.isValid, prior.source == entry.source, prior.unit == entry.unit, prior.productName == entry.productName, prior.substance == entry.substance,
                  prior.date < entry.date, let amount = prior.comparableAmount, abs(amount - mg) <= mg * 0.2,
                  let response = prior.responseTime, response <= min(now,entry.date), prior.responseEnergy != nil,
                  abs(response.timeIntervalSince(prior.date) / 3600 - hours) <= 0.5 else { return false }
            return !entries.contains { other in
                other.id != prior.id && other.date <= response &&
                (other.date >= prior.date.addingTimeInterval(-2 * 3600) ||
                 (other.isPatch && (other.ended ?? .distantFuture) >= prior.date))
            }
        }.sorted { $0.date < $1.date }
    }

    public static func medianChange(_ entries: [StimulantIntake]) -> Double? {
        let changes = entries.compactMap { entry -> Double? in
            guard let before = entry.baselineEnergy, let after = entry.responseEnergy else { return nil }
            return Double(after - before)
        }.sorted()
        guard changes.count >= 3 else { return nil }
        return (changes[(changes.count - 1) / 2] + changes[changes.count / 2]) / 2
    }
}
