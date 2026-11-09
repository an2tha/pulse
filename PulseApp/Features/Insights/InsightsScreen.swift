import Charts
import PulseEngine
import SwiftUI

private enum Metric: String, CaseIterable {
    case energy = "Energy"
    case clarity = "Clarity"
    case interest = "Interest"
    case load = "Workload"
    case comparison = "Energy & clarity"
    case stress = "Stress"
    func value(_ r: CheckIn) -> Double? {
        switch self {
        case .energy, .comparison: r.energy
        case .stress: r.stress
        case .clarity: r.clarity
        case .interest: r.interest
        case .load: r.workload
        }
    }
}
private struct Reading: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
    let low, high: Double
    let count: Int
    var run = 0
}

struct CheckInTrends: View {
    @Environment(Workspace.self) var store
    let endingDay: Date
    @State private var week = false
    @SceneStorage("pulse.insights.period.personal") private var personalPeriod = ""
    @SceneStorage("pulse.insights.period.demo") private var demoPeriod = ""
    @State private var metric = Metric.energy
    @State private var inspected: Date?
    @State private var detailsOpen = false
    @State private var reviewOpen = false
    @State private var captureSession: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var type
    @State private var historyOpen = false
    @ScaledMetric(relativeTo: .body) private var chartHeight = 238

    private var interval: DateInterval {
        let calendar = Calendar.current
        let today = endingDay
        return DateInterval(
            start: week ? calendar.date(byAdding: .day, value: -6, to: today)! : today,
            end: calendar.date(byAdding: .day, value: 1, to: today)!)
    }
    private var reports: [CheckIn] {
        store.journal.reports.filter { $0.date >= interval.start && $0.date < interval.end }
    }
    private func readings(for metric: Metric) -> [Reading] {
        var points = reports.compactMap { report -> Reading? in
            guard let value = metric.value(report) else { return nil }
            return Reading(id: report.id, date: report.date, value: value, low: value, high: value, count: 1)
        }.sorted { $0.date < $1.date }
        guard week else {
            // Long breaks and simultaneous reports start a new trace.
            for index in points.indices.dropFirst() {
                let gap = points[index].date.timeIntervalSince(points[index - 1].date)
                points[index].run = points[index - 1].run + (gap > 7200 || gap == 0 ? 1 : 0)
            }
            return points
        }
        var daily = Dictionary(grouping: points, by: { Calendar.current.startOfDay(for: $0.date) }).compactMap {
            date, list -> Reading? in
            guard let first = list.first else { return nil }
            let values = list.map(\.value)
            return Reading(
                id: first.id, date: Calendar.current.date(byAdding: .hour, value: 12, to: date)!,
                value: values.reduce(0, +) / Double(list.count), low: values.min()!, high: values.max()!,
                count: list.count)
        }.sorted { $0.date < $1.date }
        for i in daily.indices.dropFirst() {
            let previous = daily[i - 1]
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: previous.date)
            let adjacent = nextDay.map { Calendar.current.isDate($0, inSameDayAs: daily[i].date) } ?? false
            daily[i].run = previous.run + (adjacent ? 0 : 1)
        }
        return daily
    }

    var body: some View {
        let values = readings(for: metric)
        let selected = selection(in: values)
        let clarity = metric == .comparison ? readings(for: .clarity) : []
        VStack(alignment: .leading, spacing: 0) {
            Text("Check-ins").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
            JournalHeadingLayout(stack: type.isAccessibilitySize) {
                metricMenu
                periodPicker
            }
            if values.isEmpty {
                Text(metric == .load || metric == .stress
                     ? "No \(metric.rawValue.lowercased()) ratings" : "No check-ins in this period")
                    .font(.subheadline).foregroundStyle(Color.surface.opacity(0.8))
                    .padding(.vertical, 8)
            } else {
                chart(values, clarity: clarity, selected: selected)
                    .frame(height: min(chartHeight, 300)).padding(.top, 8)
            }
            if let selected {
                if let paired = clarity.first(where: { $0.id == selected.id }) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { comparisonValues(energy: selected, clarity: paired) }
                        VStack(alignment: .leading, spacing: 8) {
                            comparisonValues(energy: selected, clarity: paired)
                        }
                    }
                    .padding(.top, 18)
                    Text(readingDate(selected)).font(.caption.monospacedDigit()).foregroundStyle(
                        .white.opacity(0.76))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(number(selected.value)) / 10")
                            .font(.title.weight(.regular))
                            .monospacedDigit()
                            .foregroundStyle(Color.trailAmber)
                        Spacer()
                        Text(readingDate(selected))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.76))
                    }.padding(.top, 18)
                }
                if week {
                    Text(weekDetail(selected)).font(.caption).foregroundStyle(.white.opacity(0.74)).padding(
                        .top, 4)
                }
            } else if let inspected, week, !values.isEmpty {
                Text("No report · \(inspected.formatted(.dateTime.weekday(.abbreviated).day()))")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.76)).padding(.top, 18)
            }
            if week {
                Button("Weekly review") { reviewOpen = true }.foregroundStyle(Color.surface).frame(
                    minHeight: 44)
            }
            details(hasReadings: !values.isEmpty).padding(.top, 24)
        }
        .navigationDestination(item: $captureSession) { id in SprintCapturesScreen(sessionID: id) }
        .sheet(isPresented: $reviewOpen) {
            NavigationStack { WeeklyReview(interval: interval) }.foregroundStyle(Color.journalInk).tint(.journalAccent)
        }
        .onAppear { restorePeriod() }
        .onChange(of: endingDay) { inspected = nil }
        .onChange(of: week) { inspected = nil }.onChange(of: metric) { inspected = nil }
    }

    private func restorePeriod() {
        let saved = store.isDemo ? demoPeriod : personalPeriod
        if !saved.isEmpty {
            week = saved == "week"
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: store.now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return }
        let recent = store.journal.reports.filter { $0.date >= start && $0.date <= store.now }
        let days = Set(recent.map { calendar.startOfDay(for: $0.date) })
        week = days.count > 1 && recent.filter { $0.date >= today }.count < 2
    }

    private func readingDate(_ selected: Reading) -> String {
        week
            ? selected.date.formatted(.dateTime.weekday(.abbreviated).day())
            : selected.date.formatted(date: .omitted, time: .shortened)
    }
    @ViewBuilder private func comparisonValues(energy: Reading, clarity: Reading) -> some View {
        Label {
            Text("Energy \(number(energy.value))")
        } icon: {
            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(Color.trailAmber)
        }
        Label {
            Text("Clarity \(number(clarity.value))")
        } icon: {
            Image(systemName: "diamond.fill").font(.caption2).foregroundStyle(store.sky[6])
        }
    }
    private var metricMenu: some View {
        Menu {
            Picker("Measure", selection: $metric) { ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        } label: {
            Label(metric.rawValue, systemImage: "chevron.down")
                .labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }.accessibilityLabel("Measure").accessibilityValue(metric.rawValue).accessibilityIdentifier("measure")
    }
    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { weekly in
                Button {
                    let period = weekly ? "week" : "day"
                    if store.isDemo { demoPeriod = period } else { personalPeriod = period }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { week = weekly }
                } label: {
                    Text(weekly ? "Week" : "Day").font(.subheadline.weight(week == weekly ? .semibold : .regular))
                        .foregroundStyle(week == weekly ? Color.trailAmber : Color.surface.opacity(0.76))
                        .frame(minWidth: 44, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(week == weekly ? Color.trailAmber : Color.surface.opacity(0.2))
                                .frame(height: week == weekly ? 2 : 0.7).padding(.bottom, 5)
                        }
                }
                .accessibilityLabel(
                    Calendar.current.isDate(endingDay, inSameDayAs: store.now) ? (weekly ? "Last 7 days" : "Today") : (weekly ? "Week" : "Day")
                )
                .accessibilityAddTraits(week == weekly ? .isSelected : [])
                .buttonStyle(PressStyle())
            }
        }
    }
    private func selection(in values: [Reading]) -> Reading? {
        guard let inspected else { return values.last }
        if week { return values.first { Calendar.current.isDate($0.date, inSameDayAs: inspected) } }
        return values.min { abs($0.date.timeIntervalSince(inspected)) < abs($1.date.timeIntervalSince(inspected)) }
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    private func weekDetail(_ r: Reading) -> String {
        if r.count == 1 { return "1 check-in" }
        return "\(r.count) check-ins · daily mean · range \(number(r.low))–\(number(r.high))"
    }
    private func chart(_ values: [Reading], clarity: [Reading], selected: Reading?) -> some View {
        let glow = Color.trailAmber
        let grid = Color.surface.opacity(0.16)
        let label = Color.white.opacity(0.72)
        return Chart {
            ForEach(values) { point in
                if week {
                    RuleMark(
                        x: .value("Day", point.date), yStart: .value("Lowest", point.low),
                        yEnd: .value("Highest", point.high)
                    )
                    .foregroundStyle(glow.opacity(0.65)).lineStyle(.init(lineWidth: 5, lineCap: .round))
                    .accessibilityHidden(true)
                }
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value(metric == .comparison ? "Energy" : metric.rawValue, point.value),
                    series: .value("Nearby reports", point.run), stacking: .unstacked
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [glow.opacity(0.37), glow.opacity(0.035)], startPoint: .top, endPoint: .bottom)
                )
                .accessibilityHidden(true)
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(metric == .comparison ? "Energy" : metric.rawValue, point.value),
                    series: .value("Nearby reports", point.run)
                )
                .interpolationMethod(.monotone).lineStyle(.init(lineWidth: 2.4, lineCap: .round))
                .foregroundStyle(glow).accessibilityHidden(true)
                if point.id == selected?.id {
                    RuleMark(
                        x: .value("Selected", point.date),
                        yStart: .value("Zero", 0), yEnd: .value("Rating", point.value)
                    )
                    .foregroundStyle(glow.opacity(0.68))
                    .lineStyle(.init(lineWidth: 1, dash: [2, 3])).accessibilityHidden(true)
                }
                PointMark(
                    x: .value("Time", point.date),
                    y: .value(metric == .comparison ? "Energy" : metric.rawValue, point.value)
                )
                .foregroundStyle(glow)
                .symbol {
                    if point.id == selected?.id {
                        ZStack {
                            Circle().fill(store.sky.ground)
                            Circle().strokeBorder(glow, lineWidth: 2)
                            Circle().fill(glow).padding(5)
                        }.frame(width: 17, height: 17)
                    } else {
                        Circle().fill(glow).frame(width: 6, height: 6)
                    }
                }
                .accessibilityLabel(
                    (metric == .comparison ? "Energy, " : "") + readingDate(point)
                )
                .accessibilityValue("\(number(point.value)) out of 10" + (week ? ", " + weekDetail(point) : ""))
            }
            if metric == .comparison {
                ForEach(clarity) { point in
                    PointMark(x: .value("Time", point.date), y: .value("Mental clarity", point.value))
                        .symbol(.diamond).symbolSize(62).foregroundStyle(store.sky[6])
                        .accessibilityLabel("Mental clarity, " + readingDate(point)).accessibilityValue(
                            "\(number(point.value)) out of ten")
                }
            }
            if let cursor = inspected, selected == nil, !values.isEmpty {
                RuleMark(x: .value("Inspection", cursor)).foregroundStyle(.white.opacity(0.45))
                    .lineStyle(.init(lineWidth: 1, dash: [3, 4])).accessibilityHidden(true)
            }
        }
        .chartYScale(domain: 0...10, range: .plotDimension(startPadding: 6, endPadding: 6))
        .chartXScale(domain: interval.start...interval.end, range: .plotDimension(startPadding: 5, endPadding: 5))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 2.5, 5, 7.5, 10]) { tick in
                AxisGridLine(stroke: .init(lineWidth: 0.65)).foregroundStyle(grid)
                if let v = tick.as(Double.self), [0, 5, 10].contains(v) {
                    AxisValueLabel { Text(number(v)).font(.system(.caption2, design: .monospaced)) }.foregroundStyle(
                        label)
                }
            }
        }
        .chartXAxis {
            if week {
                AxisMarks(
                    values: (0..<7).compactMap {
                        Calendar.current.date(
                            byAdding: .hour, value: 12,
                            to: Calendar.current.date(byAdding: .day, value: $0, to: interval.start)!)
                    }
                ) { tick in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(label)
                }
            } else {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisValueLabel(format: .dateTime.hour()).foregroundStyle(label)
                }
            }
        }
        .chartXSelection(value: $inspected)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { tap in
                proxy.selectXValue(at: tap.location.x)
            }
            .simultaneously(
                with: DragGesture(minimumDistance: 8).onChanged { drag in
                    if abs(drag.translation.width) >= abs(drag.translation.height) {
                        proxy.selectXValue(at: drag.location.x)
                    }
                })
        }
    }

    private func duration(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }

    @ViewBuilder private func details(hasReadings: Bool) -> some View {
        let sessions = store.journal.sessions.filter {
            ($0.start >= interval.start && $0.start < interval.end) || $0.seconds(in: interval) > 0
        }.sorted { $0.start > $1.start }
        let history = store.journal.reports.filter { $0.date < interval.end }.sorted { $0.date < $1.date }
        let errors = Capacity.errors(history)
        let uncertainty = Capacity.uncertainty(errors)
        if hasReadings || !sessions.isEmpty || uncertainty != nil || metric == .load {
            Divider().overlay(.white.opacity(0.18))
            DisclosureGroup("Details", isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    if hasReadings {
                        Text(
                            week
                                ? "Dots show daily means. Lines connect consecutive reported days. Bars span the lowest and highest reports."
                                : "Dots mark check-ins. Lines join reports up to two hours apart.")
                    } else if metric == .load {
                        Text("Add a workload rating in check-in details.")
                    }
                    if !sessions.isEmpty {
                        DisclosureGroup(isExpanded: $historyOpen) {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(sessions) { session in
                                    VStack(alignment: .leading, spacing: 3) {
                                        LabeledContent(session.title, value: duration(session.seconds(in: interval)))
                                        let time = session.start.formatted(
                                            date: week ? .abbreviated : .omitted, time: .shortened)
                                        Text(
                                            time
                                                + (session.completedTask.map {
                                                    $0 ? " · Completed" : " · Progress saved"
                                                } ?? "")
                                        )
                                        .font(.caption).foregroundStyle(.white.opacity(0.72))
                                    }.accessibilityElement(children: .combine)
                                    SprintCapturesButton(sessionID: session.id) { captureSession = session.id }
                                }
                            }.padding(.top, 8)
                        } label: {
                            LabeledContent(
                                "Focus sessions", value: duration(sessions.reduce(0) { $0 + $1.seconds(in: interval) }))
                        }
                        .disclosureGroupStyle(HistoryDisclosureStyle())
                        let delays = Rhythms.firstActionDelays(reports: reports, sessions: sessions)
                        if !delays.isEmpty {
                            LabeledContent(
                                "Check-in to first action",
                                value: "\(Int((delays.map(\.1).reduce(0,+)/Double(delays.count)).rounded())) min avg")
                        }
                    }
                    if let uncertainty {
                        Text("Energy estimates · recent history").font(.headline)
                        if let base = Capacity.baseline(history.map(\.energy)),
                            let range = Capacity.usualRange(baseline: base, errors: errors)
                        {
                            LabeledContent(
                                "Typical estimate range",
                                value: "\(number(range.lowerBound))–\(number(range.upperBound)) / 10")
                        }
                        if let change = Capacity.unusualResidual(errors) {
                            LabeledContent(
                                "Latest report vs. baseline",
                                value: change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)))
                            )
                        }
                        LabeledContent("Prediction error (RMS)", value: "\(number(uncertainty)) points")
                    }
                }.font(.subheadline).foregroundStyle(.white.opacity(0.8)).padding(.vertical, 10)
            }
            .font(.subheadline.weight(.medium)).tint(.surface).padding(.top, 8)
            .environment(\.colorScheme, .dark)
            .disclosureGroupStyle(HistoryDisclosureStyle())
        }
    }
}

private struct HistoryDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduced ? nil : .easeOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(PressStyle()).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
