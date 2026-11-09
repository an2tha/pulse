import PulseEngine
import SwiftUI

/// A full-day view above the zoomed time ruler. The outlined interval is exactly
/// what is visible below. Distant hours are reachable with a single touch or drop.
struct DayForecastNavigator: View {
    let day: DateInterval
    let hours: [Date]
    let energy: [EnergyPoint]
    let blocks: [Block]
    let leadingHours: CGFloat
    let unit: CGFloat
    var showsViewport = true
    var currentTime: Date?
    let jump: (Date) -> Void
    let drop: ([String], Date) -> Bool
    @State private var dropTarget = false
    @State private var lastScrub: Int?
    @ScaledMetric(relativeTo: .caption2) private var timeLabelHeight: CGFloat = 17

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let count = max(1, CGFloat(hours.count))
            let bin = width / count
            let visible = min(count, width / unit)
            let tickHours = hours.filter { Calendar.current.component(.hour, from: $0).isMultiple(of: 6) }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let base: CGFloat = 28
                    let accent = Color.trailAmber
                    // Separate hour samples leave unsupported intervals visibly empty.
                    var last: CGPoint?
                    for (i, hour) in hours.enumerated() {
                        guard let point = energy.first(where: { $0.date >= hour && $0.date < hour.addingTimeInterval(3600) }) else {
                            last = nil
                            continue
                        }
                        let y = base - 2 - CGFloat(point.score / 10) * (base - 6)
                        let start = CGPoint(x: CGFloat(i) * bin, y: y)
                        let end = CGPoint(x: CGFloat(i + 1) * bin, y: y)
                        var path = Path()
                        path.move(to: last ?? start)
                        path.addLine(to: start)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1.4, dash: point.source == .forecast ? [3, 2] : []))
                        context.fill(Path(CGRect(x: start.x, y: y, width: bin, height: base - y)), with: .color(accent.opacity(0.13)))
                        last = end
                    }
                    context.fill(Path(CGRect(x: 0, y: base, width: size.width, height: 0.6)), with: .color(.surface.opacity(0.24)))
                    for block in blocks {
                        let tint: Color
                        switch block.kind {
                        case .fixed, .timeBlock(_, .protected): tint = .surface
                        case .timeBlock, .task: tint = .trailAmber
                        default: continue
                        }
                        let start = max(0, CGFloat(block.start.timeIntervalSince(day.start) / day.duration) * width)
                        let end = min(width, CGFloat(block.end.timeIntervalSince(day.start) / day.duration) * width)
                        if end > start {
                            context.fill(Path(CGRect(x: start, y: base + 2, width: max(2, end - start), height: 2)),
                                         with: .color(tint.opacity(0.65)))
                        }
                    }
                    if let now = currentTime, now >= day.start && now < day.end {
                        let x = CGFloat(now.timeIntervalSince(day.start) / day.duration) * width
                        context.fill(Path(CGRect(x: x, y: base - 9, width: 1.4, height: 13)), with: .color(.surface))
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: base - 11, width: 5, height: 5)), with: .color(.surface))
                    }
                    guard showsViewport else { return }
                    let x = min(max(0, leadingHours), count - visible) * bin
                    let window = CGRect(x: x + 0.6, y: 0.7, width: max(1, visible * bin - 1.2), height: base + 4)
                    let frame = Path(roundedRect: window, cornerRadius: 4)
                    context.fill(frame, with: .color(.surface.opacity(0.08)))
                    context.stroke(frame, with: .color(dropTarget ? accent : .surface.opacity(0.7)), lineWidth: 1)
                }
                ForEach(tickHours, id: \.self) { date in
                    Text(date.formatted(.dateTime.hour()))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Color.surface.opacity(0.68))
                        .offset(x: CGFloat(date.timeIntervalSince(day.start) / day.duration) * width, y: 34)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard !hours.isEmpty else { return }
                    let index = min(hours.count - 1, max(0, Int(gesture.location.x / bin)))
                    if lastScrub != index { lastScrub = index; jump(hours[index]) }
                }
                .onEnded { _ in lastScrub = nil })
            .dropDestination(for: String.self) { values, location in
                guard !hours.isEmpty else { return false }
                return drop(values, hours[min(hours.count - 1, max(0, Int(location.x / bin)))])
            } isTargeted: { dropTarget = $0 }
            .accessibilityRepresentation {
                let last = max(1, Int(ceil(count - visible)))
                Slider(value: Binding(get: { Double(min(CGFloat(last), max(0, leadingHours.rounded()))) },
                                      set: { if !hours.isEmpty { jump(hours[min(hours.count - 1, max(0, Int($0.rounded())))]) } }),
                       in: 0...Double(last), step: 1) {
                    Text("Browse forecast hours")
                }
                .accessibilityLabel("Browse forecast hours, " + accessibleRange(visible: visible))
                .accessibilityValue(accessibleRange(visible: visible))
                .accessibilityIdentifier("forecast-day-navigator")
            }
        }.frame(height: 34 + timeLabelHeight)
    }

    private func accessibleRange(visible: CGFloat) -> String {
        let from = day.start.addingTimeInterval(Double(leadingHours) * 3600)
        let to = min(day.end, from.addingTimeInterval(Double(visible) * 3600))
        return from.formatted(date: .omitted, time: .shortened) + " to " + to.formatted(date: .omitted, time: .shortened)
    }
}
