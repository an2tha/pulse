import Charts
import SwiftUI

struct HealthTracePoint: Identifiable {
    let date: Date
    let value: Double
    let predicted: Bool
    var id: Date { date }
    init(_ date: Date, _ value: Double, predicted: Bool = false) {
        self.date = date
        self.value = value
        self.predicted = predicted
    }
}

/// Break the trace at missing intervals and at the boundary between estimates and forecasts.
struct HealthTrace: View {
    let title: String
    let points: [HealthTracePoint]
    let interval: DateInterval
    let range: ClosedRange<Double>
    let maximumGap: TimeInterval
    let tint: Color
    let daily: Bool
    let unit: String
    @Binding var inspected: Date?
    @Environment(\.dynamicTypeSize) private var type
    @State private var tickOffsets: [Date: CGFloat] = [:]
    @ScaledMetric(relativeTo: .caption2) private var axisHeight: CGFloat = 18

    private struct Mark: Identifiable {
        let point: HealthTracePoint
        let run: Int
        var id: Date { point.id }
    }

    var body: some View {
        var run = 0
        let marks = points.enumerated().map { index, point in
            if index > 0 {
                let previous = points[index - 1]
                if point.predicted != previous.predicted || point.date.timeIntervalSince(previous.date) > maximumGap {
                    run += 1
                }
            }
            return Mark(point: point, run: run)
        }
        let chosen = inspected.flatMap { time in
            points.min { abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time)) }
        }
        return VStack(alignment: .leading, spacing: 2) {
            Chart {
                ForEach(marks) { mark in
                    let p = mark.point
                    LineMark(x: .value("Time", p.date), y: .value(unit, p.value), series: .value("Run", mark.run))
                        .interpolationMethod(.linear)
                        .lineStyle(.init(lineWidth: 2.1, lineCap: .round, dash: p.predicted ? [4, 4] : []))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    PointMark(x: .value("Time", p.date), y: .value(unit, p.value))
                        .symbolSize(chosen?.date == p.date ? 48 : 15).foregroundStyle(tint)
                        .accessibilityLabel(
                            p.date.formatted(date: daily ? .abbreviated : .omitted, time: daily ? .omitted : .shortened)
                        )
                        .accessibilityValue(
                            "\(p.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
                                + (p.predicted ? ", forecast" : ""))
                }
                if let chosen {
                    RuleMark(x: .value("Selected", chosen.date))
                        .lineStyle(.init(lineWidth: 1, dash: [2, 4])).foregroundStyle(tint.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .chartXScale(domain: interval.start...interval.end, range: .plotDimension(startPadding: 4, endPadding: 5))
            .chartYScale(domain: range, range: .plotDimension(startPadding: 4, endPadding: 5))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: .init(lineWidth: 0.6)).foregroundStyle(Color.surface.opacity(0.2))
                    AxisValueLabel().foregroundStyle(Color.surface.opacity(0.76))
                }
            }
            .chartXAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let origin = proxy.plotFrame.map { geometry[$0].minX } ?? 0
                    let positions = Dictionary(uniqueKeysWithValues: axisDates.compactMap { date in
                        proxy.position(forX: date).map { (date, origin + $0) }
                    })
                    Color.clear.onChange(of: positions, initial: true) { _, offsets in tickOffsets = offsets }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .chartXSelection(value: $inspected)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)

            timeAxis
        }
    }

    private var axisDates: [Date] {
        let calendar = Calendar.current
        let dayCount = max(1, calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
        let count = min(type.isAccessibilitySize ? 2 : 4, daily ? dayCount : 4)
        return (0..<count).compactMap { position in
            daily
                ? calendar.date(byAdding: .day, value: position * dayCount / count, to: interval.start)
                : calendar.date(bySettingHour: position * 24 / count, minute: 0, second: 0, of: interval.start)
        }
    }

    // Native labels share the chart's plot coordinates and remain readable by VoiceOver.
    private var timeAxis: some View {
        ZStack(alignment: .leading) {
            ForEach(axisDates, id: \.self) { date in
                let format: Date.FormatStyle = daily ? .dateTime.month(.abbreviated).day() : .dateTime.hour()
                Text(date, format: format)
                    .font(.caption2)
                    .foregroundStyle(Color.surface.opacity(0.76))
                    .fixedSize()
                    .offset(x: tickOffsets[date] ?? 0)
                    .accessibilityLabel(date.formatted(date: daily ? .abbreviated : .omitted,
                                                       time: daily ? .omitted : .shortened))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: axisHeight)
    }
}
