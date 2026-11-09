import SwiftUI

extension Sky {
    var ground: Color { pigments[8].mixed(Ink(0x101E28), 0.74).color }
    var canvasBackground: LinearGradient {
        LinearGradient(
            stops: [.init(color: upperSky, location: 0.18), .init(color: ground, location: 0.78)],
            startPoint: .top, endPoint: .bottom)
    }
    var upperSky: Color { pigments[0].color }
}

private extension Atmosphere {
    var printAsset: String {
        switch self {
        case .dawn: "AlpineDawn"
        case .day: "AlpineDay"
        case .golden: "AlpineGolden"
        case .evening: "AlpineEvening"
        case .night: "AlpineNight"
        }
    }
}

/// The five registered color plates share a single drawing. During the half-hour
/// between phases only the preceding and current plates participate in the blend.
struct LookoutLandscape: View, Equatable {
    var sky: Sky
    var energy: Double
    var theme: LandscapeTheme = .pastelPainting

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let aspect = 1122.0 / 1402.0
            let width = max(size.width, size.height * aspect)
            let height = width / aspect
            let isFrieze = size.width > size.height * 2
            let crop = isFrieze ? max(0, height * 0.18 - size.height * 0.30) : (height - size.height) * 0.11
            ZStack(alignment: .topLeading) {
                if theme == .pastelPainting {
                    paintedLandscape
                        .frame(width: width, height: height)
                        .position(x: size.width / 2, y: height / 2 - crop)
                } else {
                    ThemeLandscape(sky: sky, energy: energy, theme: theme)
                        .frame(width: size.width, height: size.height)
                }

                // The lake's high air moves even on the resting screen. Reduced
                // Motion leaves the flock at its final position in the print.
                if !isFrieze { MountainBirds(sky: sky, energy: energy) }
                VStack(spacing: 0) {
                    LinearGradient(colors: [sky.upperSky, sky.upperSky.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: isFrieze ? size.height * 0.64 : min(44, size.height * 0.17))
                    Spacer(minLength: 0)
                    LinearGradient(
                        stops: [
                            .init(color: sky.ground.opacity(0), location: 0),
                            .init(color: sky.ground.opacity(0.40), location: 0.46),
                            .init(color: sky.ground, location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: size.height * (isFrieze ? 0.14 : 0.16))
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var paintedLandscape: some View {
        ZStack {
            if sky.phaseBlend < 1 {
                Image(decorative: sky.precedingPhase.printAsset).resizable()
            }
            Image(decorative: sky.phase.printAsset).resizable().opacity(sky.phaseBlend)
        }
        .saturation(0.91 + min(10, max(0, energy)) * 0.018)
    }
}

private struct MountainBirds: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var settled = false
    let sky: Sky
    let energy: Double

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width * 0.62, y: size.height * 0.19)
            let ink = sky.usesLightHeaderInk ? Color.surface.opacity(0.64) : Color.pine.opacity(0.86)
            let wings: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 1), (13, -3, 0.8), (23, 1, 0.6)]
            for (x, y, scale) in wings {
                var plate = context
                plate.translateBy(x: origin.x + x, y: origin.y + y)
                plate.scaleBy(x: scale, y: scale)
                var path = Path()
                path.move(to: CGPoint(x: -4, y: -1))
                path.addQuadCurve(to: CGPoint(x: 0, y: 1.4), control: CGPoint(x: -2, y: -1))
                path.addQuadCurve(to: CGPoint(x: 4, y: -2), control: CGPoint(x: 1.3, y: -2.1))
                plate.stroke(path, with: .color(ink), lineWidth: 1.1)
            }
        }
        .offset(x: reduced || settled ? 0 : -min(24, energy + 12), y: reduced || settled ? 0 : 5)
        .onAppear { withAnimation(reduced ? nil : .easeOut(duration: 1.4)) { settled = true } }
    }
}

struct DawnLandscape: View {
    var body: some View { LookoutLandscape(sky: AtmosphereEngine.sky(at: .now, override: .dawn), energy: 5) }
}
struct DayLandscape: View {
    var body: some View { LookoutLandscape(sky: AtmosphereEngine.sky(at: .now, override: .day), energy: 5) }
}
struct GoldenHourLandscape: View {
    var body: some View { LookoutLandscape(sky: AtmosphereEngine.sky(at: .now, override: .golden), energy: 5) }
}
struct EveningLandscape: View {
    var body: some View { LookoutLandscape(sky: AtmosphereEngine.sky(at: .now, override: .evening), energy: 5) }
}
struct NightLandscape: View {
    var body: some View { LookoutLandscape(sky: AtmosphereEngine.sky(at: .now, override: .night), energy: 5) }
}
