import PulseEngine
import SwiftUI

struct TimelineEnergyRibbon: View {
    let energy: [EnergyPoint]
    let start: Date
    let end: Date

    static let low = Color(red: 0.58, green: 0.62, blue: 0.94)
    static let middle = Color(red: 0.80, green: 0.58, blue: 0.88)
    static let high = Color(red: 0.98, green: 0.73, blue: 0.64)

    var body: some View {
        Canvas { context, size in
            let shown = energy.filter { $0.date >= start && $0.date < end }
            guard !shown.isEmpty else { return }
            // Scale against the entire day, including hidden hours. A minimum range
            // keeps small score changes from looking like large swings.
            let lo = energy.map(\.score).min() ?? 0
            let hi = energy.map(\.score).max() ?? 10
            let span = max(4.5, hi - lo)
            let floor = max(0, min(10 - span, (lo + hi - span) / 2))
            let inset = CGFloat(9)
            var points = shown.map { point in
                CGPoint(x: inset + (size.width - 2 * inset) * (point.score - floor) / span,
                        y: size.height * point.date.timeIntervalSince(start) / end.timeIntervalSince(start))
            }
            points.append(CGPoint(x: points.last!.x, y: size.height))
            var line = Path()
            line.move(to: points[0])
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                let dx = b.x - a.x
                func tangent(_ adjacent: CGFloat) -> CGFloat {
                    guard adjacent * dx > 0 else { return 0 }
                    return 2 * adjacent * dx / (adjacent + dx)
                }
                let left = index > 1 ? tangent(a.x - points[index - 2].x) : dx
                let right = index + 1 < points.count ? tangent(points[index + 1].x - b.x) : dx
                let dy = (b.y - a.y) / 3
                line.addCurve(to: b, control1: CGPoint(x: a.x + left / 3, y: a.y + dy),
                              control2: CGPoint(x: b.x - right / 3, y: b.y - dy))
            }
            var area = line
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: points[0].y))
            area.closeSubpath()
            func wash(_ opacity: Double) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: [Self.low, Self.middle, Self.high].map { $0.opacity(opacity) }),
                                startPoint: CGPoint(x: inset, y: 0), endPoint: CGPoint(x: size.width - inset, y: 0))
            }
            context.fill(area, with: wash(0.105))
            context.stroke(line, with: wash(0.045), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            context.stroke(line, with: wash(0.36), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
