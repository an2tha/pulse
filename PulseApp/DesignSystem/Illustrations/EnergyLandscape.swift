import SwiftUI

/// Lake and sky share a coordinate system so the light on the water stays in
/// register with its source as the sheet changes size or the user checks in.
struct EnergyLandscape: View, Equatable {
    let sky: Sky
    var energy: Double = 5
    var conditions: LakeConditions? = nil
    var theme: LandscapeTheme = .pastelPainting

    var body: some View {
        GeometryReader { bounds in
            let size = bounds.size
            let aspect = 1402.0 / 1122.0
            let width = max(size.width, size.height * aspect)
            let height = width / aspect
            // Keep the far shore and the red boat in the crop on short sheets.
            let top = min(height - size.height, max(0, height * 0.72 - size.height))
            ZStack {
                ZStack {
                    if theme != .pastelPainting {
                        ThemeLandscape(sky: sky, energy: energy, theme: theme, isLake: true)
                    } else {
                        if sky.phaseBlend < 1 {
                            Image(decorative: sky.precedingPhase.lakeAsset).resizable()
                        }
                        Image(decorative: sky.phase.lakeAsset).resizable().opacity(sky.phaseBlend)
                    }
                }
                .saturation(0.62 + 0.043 * (conditions?.interest ?? 5))
                .contrast(0.95 + 0.012 * (conditions?.clarity ?? 5))
                Canvas { context, size in
                    var print = LakeWeather(context: context, sky: sky)
                    print.context.scaleBy(x: size.width / 500, y: size.height / 400)
                    print.paint(energy: energy, conditions: conditions)
                }
            }
            .frame(width: width, height: height)
            .position(x: size.width / 2, y: height / 2 - top)
        }
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private extension Atmosphere {
    var lakeAsset: String {
        switch self {
        case .dawn: "LakeDawn"
        case .day: "LakeDay"
        case .golden: "LakeGolden"
        case .evening: "LakeEvening"
        case .night: "LakeNight"
        }
    }
}

private struct LakeWeather {
    var context: GraphicsContext
    let sky: Sky
    private let bounds = Path(CGRect(x: 0, y: 0, width: 500, height: 400))

    func paint(energy: Double, conditions: LakeConditions?) {
        let strength = min(1, max(0, energy / 10))
        let clarity = (conditions?.clarity ?? 5) / 10
        let interest = (conditions?.interest ?? 5) / 10
        let steady = conditions?.reduceMotion ?? true
        let orb = CGPoint(x: 342, y: steady ? 104 : 116 - strength * 46)
        let light = sky.usesLightHeaderInk ? Ink(0xD8EBE0).color : Ink(0xFFEFBD).color

        context.fill(bounds, with: .radialGradient(
            Gradient(colors: [light.opacity(0.10 + 0.24 * strength), .clear]), center: orb,
            startRadius: 3, endRadius: 49 + strength * 20))
        let radius = 12.0 + 4 * strength
        let disc = CGRect(x: orb.x - radius, y: orb.y - radius, width: 2 * radius, height: 2 * radius)
        context.drawLayer { layer in
            layer.fill(Path(ellipseIn: disc), with: .color(light.opacity(0.80 + strength * 0.17)))
            if sky.moon > 0 {
                layer.blendMode = .destinationOut
                layer.fill(Path(ellipseIn: disc.offsetBy(dx: radius * 0.52, dy: -radius * 0.29)),
                           with: .color(.black.opacity(sky.moon)))
            }
        }

        let mist = sky.usesLightHeaderInk ? Ink(0x788BA6).color : Ink(0xF6E9C5).color
        let haze = (1 - clarity) * (sky.usesLightHeaderInk ? 0.42 : 0.57)
        context.fill(bounds, with: .linearGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: mist.opacity(haze * 0.55), location: 0.26),
                .init(color: mist.opacity(haze), location: 0.63),
                .init(color: .clear, location: 1)
            ]), startPoint: CGPoint(x: 0, y: 110), endPoint: CGPoint(x: 8, y: 222)))

        var water = context
        water.clip(to: Path(CGRect(x: 125, y: 196, width: 262, height: 160)))
        for index in 0..<37 {
            let depth = Double(index) / 36
            let y = 199 + 151 * depth
            // A widening trail on the water breaks into individual cuts of ink.
            let x = 345 + (sin(Double(index) * 5.77) * 0.66 + cos(Double(index) * 3.41) * 0.34)
                * (6 + depth * 58)
            // Exclude the rowboat, its tether, and their original reflections.
            if (252...303).contains(y) && (260...368).contains(x) { continue }
            let length = (3 + 9 * depth + 4 * sin(Double(index) * 0.77)) * (0.55 + 1.4 * strength)
            var cut = Path()
            cut.move(to: CGPoint(x: x - length, y: y))
            cut.addQuadCurve(to: CGPoint(x: x + length * 0.7, y: y - 0.45), control: CGPoint(x: x, y: y + 1.3))
            cut.addLine(to: CGPoint(x: x + length * 0.12, y: y + 1.05))
            cut.closeSubpath()
            water.fill(cut, with: .color(light.opacity(0.12 + 0.66 * strength)))
        }

        let silhouette = sky.usesLightHeaderInk ? Color.surface : Ink(0x294845).color
        for (index, point) in Self.flock.enumerated() {
            let opacity = min(1, max(0, interest * 7 - Double(index)))
            guard opacity > 0 else { continue }
            let x = point.x + (steady ? 0 : 17 * (interest - 0.5))
            let y = point.y - (steady ? 0 : 5 * interest)
            if sky.phase == .night {
                let radius = index.isMultiple(of: 2) ? 1.15 : 0.76
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                             with: .color(silhouette.opacity(opacity * 0.85)))
            } else {
                let span = 4.2 - Double(index % 3) * 0.75
                var wings = Path()
                wings.move(to: CGPoint(x: x - span, y: y - 1.2))
                wings.addQuadCurve(to: CGPoint(x: x, y: y + 1.5), control: CGPoint(x: x - 1.4, y: y - 1.1))
                wings.addQuadCurve(to: CGPoint(x: x + span, y: y - 1.7), control: CGPoint(x: x + 1.0, y: y - 1.3))
                context.stroke(wings, with: .color(silhouette.opacity(opacity * 0.9)), lineWidth: 1.1)
            }
        }

        if let sleep = conditions?.sleep {
            context.fill(bounds, with: .linearGradient(
                Gradient(colors: [light.opacity(0.04 + sleep * 0.018), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 60, y: 156)))
        }
        if let workload = conditions?.workload {
            context.fill(bounds, with: .linearGradient(
                Gradient(colors: [.clear, sky.ground.opacity(workload * 0.026)]),
                startPoint: CGPoint(x: 0, y: 208), endPoint: CGPoint(x: 0, y: 388)))
        }
    }

    private static let flock: [CGPoint] = [
        .init(x: 196, y: 100), .init(x: 208, y: 96), .init(x: 219, y: 101),
        .init(x: 189, y: 105), .init(x: 230, y: 103), .init(x: 205, y: 112), .init(x: 238, y: 108)
    ]
}
