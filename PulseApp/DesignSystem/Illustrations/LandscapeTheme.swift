import SwiftUI

enum LandscapeTheme: String, CaseIterable, Identifiable {
    case pastelPainting = "pastel-painting"
    case calm
    case mellow
    case lowPoly = "low-poly"

    var id: Self { self }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .pastelPainting
    }

    var title: String {
        switch self {
        case .pastelPainting: "Pastel Painting"
        case .calm: "Calm"
        case .mellow: "Mellow"
        case .lowPoly: "Low Poly"
        }
    }

    var detail: String {
        switch self {
        case .pastelPainting: "Soft brushwork, alpine peaks and a quiet lake."
        case .calm: "Open skies and still water in cool, gentle tones."
        case .mellow: "Warm earth, rolling hills and a softer horizon."
        case .lowPoly: "Angular peaks and water shaped from color facets."
        }
    }
}

/// Resolution-independent companion scenes. Every pack uses the live sky palette,
/// so phase transitions and the surrounding journal remain in the same light.
struct ThemeLandscape: View {
    let sky: Sky
    let energy: Double
    let theme: LandscapeTheme
    var isLake = false

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 500, y: size.height / 400)
            let bounds = Path(CGRect(x: 0, y: 0, width: 500, height: 400))
            context.fill(bounds, with: .linearGradient(
                Gradient(colors: [sky.upperSky, sky[1]]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: 260)))

            // Check-in supplies its own responsive sun, mist and reflections.
            if !isLake {
                let radius = 15.0 + min(10, max(0, energy)) * 0.35
                context.fill(Path(ellipseIn: CGRect(x: 342 - radius, y: 92 - radius,
                                                   width: radius * 2, height: radius * 2)),
                             with: .color(sky[10].opacity(0.90)))
            }

            switch theme {
            case .calm: calm(in: &context)
            case .mellow: mellow(in: &context)
            case .lowPoly: lowPoly(in: &context)
            case .pastelPainting: break
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func calm(in context: inout GraphicsContext) {
        fill(&context, color: sky.pigments[2].mixed(sky.pigments[6], 0.40).color) { path in
            path.move(to: CGPoint(x: 0, y: 185))
            path.addCurve(to: CGPoint(x: 500, y: 187), control1: CGPoint(x: 175, y: 127), control2: CGPoint(x: 310, y: 211))
            closeGround(&path)
        }
        fill(&context, color: sky[5]) { path in
            path.move(to: CGPoint(x: 0, y: 211))
            path.addCurve(to: CGPoint(x: 500, y: 198), control1: CGPoint(x: 195, y: 176), control2: CGPoint(x: 305, y: 193))
            closeGround(&path)
        }
        water(in: &context, color: sky.pigments[6].mixed(sky.pigments[0], 0.22).color)
        for index in 0..<12 {
            let y = 217.0 + Double(index) * 11
            let width = 18.0 + Double(index) * 3
            var line = Path()
            line.move(to: CGPoint(x: 340 - width, y: y))
            line.addLine(to: CGPoint(x: 340 + width, y: y))
            context.stroke(line, with: .color(sky[10].opacity(0.22)), lineWidth: 1)
        }
        shore(in: &context, color: sky[8], leftHeight: 292, rightHeight: 335)
    }

    private func mellow(in context: inout GraphicsContext) {
        let warm = sky.pigments[3].mixed(sky.pigments[7], 0.50)
        fill(&context, color: warm.mixed(sky.pigments[1], 0.28).color) { path in
            path.move(to: CGPoint(x: 0, y: 174))
            path.addCurve(to: CGPoint(x: 500, y: 190), control1: CGPoint(x: 210, y: 84), control2: CGPoint(x: 280, y: 256))
            closeGround(&path)
        }
        fill(&context, color: warm.color) { path in
            path.move(to: CGPoint(x: 0, y: 221))
            path.addCurve(to: CGPoint(x: 500, y: 168), control1: CGPoint(x: 190, y: 238), control2: CGPoint(x: 300, y: 129))
            closeGround(&path)
        }
        water(in: &context, color: sky.pigments[6].mixed(warm, 0.22).color)
        shore(in: &context, color: warm.mixed(sky.pigments[8], 0.32).color, leftHeight: 271, rightHeight: 315)
        shore(in: &context, color: sky[8], leftHeight: 359, rightHeight: 389)
    }

    private func lowPoly(in context: inout GraphicsContext) {
        polygon(&context, [[0, 207], [75, 123], [123, 167], [217, 76], [315, 177], [391, 113], [500, 208]], sky[2], ground: true)
        polygon(&context, [[123, 167], [217, 76], [191, 205]], sky[3])
        polygon(&context, [[217, 76], [315, 177], [191, 205]], sky[4])
        polygon(&context, [[315, 177], [391, 113], [378, 211]], sky[3])
        polygon(&context, [[391, 113], [500, 208], [378, 211]], sky[4])
        polygon(&context, [[193, 106], [217, 76], [247, 108], [220, 99], [210, 113]], sky[9])
        water(in: &context, color: sky[6])
        polygon(&context, [[0, 207], [191, 205], [260, 325]], sky[2].opacity(0.27))
        polygon(&context, [[191, 205], [315, 207], [260, 325]], sky[4].opacity(0.20))
        polygon(&context, [[315, 207], [500, 207], [410, 293]], sky[3].opacity(0.25))
        polygon(&context, [[0, 264], [87, 300], [211, 400], [0, 400]], sky[5])
        polygon(&context, [[0, 264], [87, 300], [0, 400]], sky[8])
        polygon(&context, [[500, 291], [397, 336], [336, 400], [500, 400]], sky[8])
        polygon(&context, [[500, 291], [397, 336], [500, 368]], sky[5])
    }

    private func water(in context: inout GraphicsContext, color: Color) {
        context.fill(Path(CGRect(x: 0, y: 207, width: 500, height: 193)), with: .linearGradient(
            Gradient(colors: [color, sky[8]]),
            startPoint: CGPoint(x: 0, y: 207), endPoint: CGPoint(x: 0, y: 470)))
    }

    private func shore(in context: inout GraphicsContext, color: Color, leftHeight: Double, rightHeight: Double) {
        fill(&context, color: color) { path in
            path.move(to: CGPoint(x: 0, y: leftHeight))
            path.addCurve(to: CGPoint(x: 500, y: rightHeight),
                          control1: CGPoint(x: 190, y: leftHeight + 12),
                          control2: CGPoint(x: 260, y: rightHeight + 108))
            closeGround(&path)
        }
    }

    private func fill(_ context: inout GraphicsContext, color: Color, drawing: (inout Path) -> Void) {
        var path = Path()
        drawing(&path)
        context.fill(path, with: .color(color))
    }

    private func closeGround(_ path: inout Path) {
        path.addLine(to: CGPoint(x: 500, y: 400))
        path.addLine(to: CGPoint(x: 0, y: 400))
        path.closeSubpath()
    }

    private func polygon(_ context: inout GraphicsContext, _ points: [[Double]], _ color: Color, ground: Bool = false) {
        var path = Path()
        for (index, point) in points.enumerated() {
            let vertex = CGPoint(x: point[0], y: point[1])
            if index == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        if ground { closeGround(&path) } else { path.closeSubpath() }
        context.fill(path, with: .color(color))
    }
}
