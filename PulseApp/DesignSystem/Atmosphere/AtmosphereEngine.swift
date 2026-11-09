import SwiftUI
import UIKit

struct Ink: Equatable {
    var r: Double, g: Double, b: Double
    init(_ hex: Int) {
        r = Double(hex >> 16 & 255) / 255
        g = Double(hex >> 8 & 255) / 255
        b = Double(hex & 255) / 255
    }
    func mixed(_ other: Self, _ t: Double) -> Self {
        var value = self
        value.r += (other.r - r) * t
        value.g += (other.g - g) * t
        value.b += (other.b - b) * t
        return value
    }
    var color: Color { Color(red: r, green: g, blue: b) }
}

enum Atmosphere: String, CaseIterable, Identifiable, Codable {
    case dawn = "Dawn"
    case day = "Daylight"
    case golden = "Golden hour"
    case evening = "Evening"
    case night = "Night"
    var id: Self { self }
    var icon: String {
        switch self {
        case .dawn: "sunrise"
        case .day: "sun.max"
        case .golden: "sun.horizon"
        case .evening: "moon.haze"
        case .night: "moon.stars"
        }
    }
    // Sky, horizon, back range, sunlit rock, shaded rock, distant trees,
    // water, meadow, nearby trees, snow, sun, sky detail.
    var pigments: [Ink] {
        let hex: [Int] =
            switch self {
            case .dawn:
                [
                    0xFCC7B8, 0xF8D7B4, 0xB5ADBC, 0xC7A899, 0x858AA1, 0x809995, 0xA4BBB4, 0xC1B584, 0x385F5C, 0xFFF0D8,
                    0xFFECB9, 0xF9E4D6,
                ]
            case .day:
                [
                    0x97EAE5, 0xF7EBBF, 0xA1BBC0, 0xA6B3A4, 0x648394, 0x709A91, 0x85BCB3, 0xC5C785, 0x254F4F, 0xFFF5DE,
                    0xFFEFAD, 0xF9F2D9,
                ]
            case .golden:
                [
                    0xFED873, 0xFFE4AE, 0xC1A399, 0xD6AA82, 0x8C8991, 0x909E8B, 0x9CB4AA, 0xD8B277, 0x355B55, 0xFFF0CA,
                    0xFFF1BB, 0xFFE4C1,
                ]
            case .evening:
                [
                    0x2C1D45, 0xF4C6AE, 0xAB9EAF, 0xBC9C9F, 0x747E98, 0x7B8F96, 0x97A9BA, 0xBAA28D, 0x384F65, 0xF5DDCE,
                    0xFFEDCD, 0xECD8D8,
                ]
            case .night:
                [
                    0x00152F, 0x829AC3, 0x979AB4, 0x9B9EB6, 0x667594, 0x748598, 0x8B9FB6, 0x939CAE, 0x354861, 0xE0E4F1,
                    0xFFF1D7, 0xCCCADD,
                ]
            }
        return hex.map(Ink.init)
    }
}

struct Sky: Equatable {
    let phase: Atmosphere
    let precedingPhase: Atmosphere
    let phaseBlend: Double
    let pigments: [Ink]
    let orbY: Double
    let moon: Double
    var interfaceScheme: ColorScheme { phase == .night || phase == .evening ? .dark : .light }
    var usesLightHeaderInk: Bool {
        let ink = pigments[0]
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(ink.r) + 0.7152 * linear(ink.g) + 0.0722 * linear(ink.b) < 0.23
    }
    subscript(_ i: Int) -> Color { pigments[i].color }
}

enum AtmosphereEngine {
    static func sky(at date: Date, override: Atmosphere? = nil, calendar: Calendar = .current) -> Sky {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60
        let phases = Atmosphere.allCases
        let starts = [5.0, 9, 16, 19, 22]
        let heights = [65.0, 43, 72, 56, 47]
        let i = override.flatMap { phases.firstIndex(of: $0) } ?? (starts.lastIndex(where: { $0 <= hour }) ?? 4)
        let previous = (i + 4) % 5
        let t = override == nil ? min(1, ((hour - starts[i] + 24).truncatingRemainder(dividingBy: 24)) / 0.5) : 1
        let a = phases[previous].pigments
        let b = phases[i].pigments
        let night: (Int) -> Double = { $0 >= 3 ? 1 : 0 }
        return Sky(
            phase: phases[i], precedingPhase: phases[previous], phaseBlend: t, pigments: zip(a, b).map { $0.mixed($1, t) },
            orbY: heights[previous] + (heights[i] - heights[previous]) * t,
            moon: night(previous) + (night(i) - night(previous)) * t)
    }
}

extension Color {
    private static func journalColor(_ day: Int, _ night: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let ink = Ink(traits.userInterfaceStyle == .dark ? night : day)
            return UIColor(red: ink.r, green: ink.g, blue: ink.b, alpha: 1)
        })
    }

    static let paper = journalColor(0xFBF8F0, 0x10171D)
    static let journalInk = journalColor(0x273F39, 0xF5F2E9)
    static let journalAccent = journalColor(0x273F39, 0xFFD187)
    static let surface = Ink(0xFFFDF7).color
    static let pine = Ink(0x273F39).color
    static let moss = journalColor(0x52655A, 0xB9C7BE)
    static let clay = journalColor(0x9C4A30, 0xFFB094)
    static let apricot = Ink(0xF5E6D7).color
    static let rule = journalColor(0xDEDCD0, 0x475058)
}
