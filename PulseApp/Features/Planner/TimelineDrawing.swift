import PulseEngine
import SwiftUI

struct DrawnTimeBlock: Identifiable, Equatable {
    let id = UUID()
    var interval: DateInterval
    var kind: WeeklyTimeBlock.Kind
    var original: WeeklyTimeBlock?
    var displayedSlice: DateInterval?

    func hasHandle(_ edge: TimelineRangeEdge, calendar: Calendar = .current) -> Bool {
        guard let original, let displayedSlice else { return true }
        let date = edge == .start ? displayedSlice.start : displayedSlice.end
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute == (edge == .start ? original.hours.startMinute : original.hours.endMinute)
    }

    mutating func move(_ edge: TimelineRangeEdge, to date: Date, within day: DateInterval) {
        guard hasHandle(edge) else { return }
        switch edge {
        case .start:
            let start = max(day.start, min(date, interval.end.addingTimeInterval(-60)))
            interval = DateInterval(start: start, end: interval.end)
        case .end:
            let end = min(day.end, max(date, interval.start.addingTimeInterval(60)))
            interval = DateInterval(start: interval.start, end: end)
        }
    }

    func clockLabel(_ date: Date, day: DateInterval) -> String {
        var label = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        for offset in [-3600.0, 3600] {
            let other = date.addingTimeInterval(offset)
            if calendar.isDate(other, inSameDayAs: date),
               calendar.component(.hour, from: date) == calendar.component(.hour, from: other) {
                label += " " + (calendar.timeZone.abbreviation(for: date) ?? calendar.timeZone.identifier)
                break
            }
        }
        return date == day.end ? label + " next day" : label
    }
}

enum TimelineRangeEdge { case start, end }

struct TimelineDrawingLayer: View {
    let day: DateInterval
    let unit: CGFloat
    let height: CGFloat
    let viewport: CGFloat
    let offset: CGFloat
    let kind: WeeklyTimeBlock.Kind
    @Binding var selection: DrawnTimeBlock?
    let existingAt: (CGPoint) -> DrawnTimeBlock?
    let pan: (Int) -> Void

    @Namespace private var plot
    @State private var drag: Drag?
    @State private var finger: CGFloat = 0
    @State private var panDirection = 0

    private enum Drag {
        case new(Date)
        case edge(TimelineRangeEdge)
    }

    private var width: CGFloat { day.duration / 3600 * unit }
    private func x(_ date: Date) -> CGFloat { date.timeIntervalSince(day.start) / 3600 * unit }
    private func snapped(_ x: CGFloat) -> Date {
        let seconds = (x / unit * 4).rounded() * 900
        return day.start.addingTimeInterval(min(day.duration, max(0, seconds)))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(plot))
                    .onChanged { value in
                        guard abs(value.translation.width) >= 4 || drag != nil else { return }
                        if drag == nil { drag = .new(snapped(value.startLocation.x)) }
                        track(value.location.x)
                    }
                    .onEnded { value in
                        if drag == nil {
                            if let existing = existingAt(value.location) { selection = existing }
                            else { begin(at: snapped(value.location.x)) }
                        } else { update(at: value.location.x) }
                        stop()
                    })
                .accessibilityElement()
                .accessibilityLabel("Draw time block on timeline")
                .accessibilityHint("Use the time controls below to set a range.")
                .accessibilityIdentifier("timeline-draw-surface")
            if let selection {
                let start = x(selection.interval.start), end = x(selection.interval.end)
                let color: Color = selection.kind == .focus ? .trailAmber : .surface
                Rectangle().fill(color.opacity(0.14))
                    .overlay { Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 1.4) }
                    .frame(width: max(1, end - start), height: height)
                    .offset(x: start)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if selection.hasHandle(.start) { handle(.start, x: start, color: color, label: "Start") }
                if selection.hasHandle(.end) { handle(.end, x: end, color: color, label: "End") }
            }
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: plot)
        .onChange(of: offset) {
            if drag != nil, panDirection != 0 { update(at: offset + finger) }
        }
        .onDisappear { stop() }
        .task(id: panDirection) {
            let direction = panDirection
            guard direction != 0 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(270)) } catch { return }
                guard drag != nil else { return }
                pan(direction)
            }
        }
    }

    private func handle(_ edge: TimelineRangeEdge, x: CGFloat, color: Color, label: String) -> some View {
        let left = max(0, min(width - 44, x - 22))
        return ZStack {
            Capsule().fill(color).frame(width: 12, height: 28)
            Capsule().fill(Color.pine).frame(width: 2, height: 14)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(plot))
            .onChanged { value in drag = .edge(edge); track(value.location.x) }
            .onEnded { value in update(at: value.location.x); stop() })
        .accessibilityElement()
        .accessibilityLabel(label + " of block")
        .accessibilityValue(selection.map { $0.clockLabel(edge == .start ? $0.interval.start : $0.interval.end, day: day) } ?? "")
        .accessibilityAdjustableAction { direction in
            guard var draft = selection, direction == .increment || direction == .decrement else { return }
            let date = edge == .start ? draft.interval.start : draft.interval.end
            draft.move(edge, to: date.addingTimeInterval(direction == .increment ? 300 : -300), within: day)
            selection = draft
        }
        .accessibilityIdentifier(edge == .start ? "timeline-range-start" : "timeline-range-end")
        .offset(x: left, y: edge == .start ? 0 : min(46, height - 44))
    }

    private func track(_ location: CGFloat) {
        finger = location - offset
        panDirection = finger < 20 && offset > 1 ? -1 : (finger > viewport - 20 && offset + viewport < width - 1 ? 1 : 0)
        update(at: location)
    }

    private func begin(at date: Date) {
        let start = min(date, day.end.addingTimeInterval(-900))
        selection = DrawnTimeBlock(interval: DateInterval(start: start, end: min(day.end, start.addingTimeInterval(1800))), kind: kind)
    }

    private func update(at location: CGFloat) {
        let time = snapped(location)
        switch drag {
        case .new(let anchor):
            let lower = min(anchor, time), upper = max(anchor, time)
            let start = min(lower, day.end.addingTimeInterval(-900))
            let end = max(upper, min(day.end, start.addingTimeInterval(900)))
            if selection?.original != nil || selection == nil {
                selection = DrawnTimeBlock(interval: DateInterval(start: start, end: end), kind: kind)
            } else {
                selection?.interval = DateInterval(start: start, end: end)
            }
        case .edge(let edge): selection?.move(edge, to: time, within: day)
        case nil: break
        }
    }

    private func stop() { drag = nil; panDirection = 0 }
}
