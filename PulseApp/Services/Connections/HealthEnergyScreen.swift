import PulseEngine
import SwiftUI

struct HealthEnergyScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.dynamicTypeSize) private var type
    @State private var date: Date?
    @State private var datePicker = false
    @State private var checkIn = false
    @State private var planning = false
    @State private var correction = false
    @State private var outlookEdit: ForecastEditSelection?
    @State private var editTime = Date.now
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 52
    @State private var period: EnergyRange = .hourly
    @State private var heartWeek = false
    @State private var heartCursor: Date?
    @State private var energyCursor: Date?
    @State private var showHours = false
    @State private var showingSources = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar = Calendar.current

    private enum Chapter: String, CaseIterable {
        case energy = "Energy", checkIns = "Check-ins", skips = "Skipped tasks", hrv = "HRV", activities = "Activities", stimulants = "Stimulants", connections = "Connections"
    }

    private func chapterLinks(_ reader: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(Chapter.allCases, id: \.rawValue) { chapter in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            reader.scrollTo(chapter, anchor: .top)
                        }
                    } label: {
                        Text(chapter.rawValue).font(.subheadline.weight(.medium))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityHint("Scroll to section")
                    .accessibilityIdentifier("health-jump-" + chapter.rawValue.lowercased())
                }
            }.padding(.horizontal, 26)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Color.surface)
        .frame(maxWidth: 672, alignment: .leading)
    }

    private var sectionRule: some View {
        Divider().overlay(Color.surface.opacity(0.28)).padding(.vertical, 20)
    }

    private enum EnergyRange: String, CaseIterable {
        case hourly = "Hours"
        case history = "History"
        case forecast = "Forecast"
    }
    private var controller: HealthEnergyController { store.healthController }
    private var today: Date { calendar.startOfDay(for: store.now) }
    private var selected: Date { calendar.startOfDay(for: date ?? today) }
    private var day: DateInterval { calendar.dateInterval(of: .day, for: selected)! }
    private var locked: Bool { store.isDemo || privacy.lockConnections }
    private var isToday: Bool { selected == today }
    private var isFuture: Bool { selected > today }
    private var bounds: ClosedRange<Date> {
        let earliest =
            [
                store.journal.reports.map(\.date).min(), store.journal.energyCorrections?.map(\.date).min(),
                controller.days.map(\.date).min(), store.journal.sessions.map(\.start).min(), store.journal.taskSkips?.map(\.skippedAt).min(),
                store.journal.tasks.compactMap(\.completedAt).min(), store.journal.planHistory?.map(\.day).min(), shift(today, -27),
            ].compactMap { $0 }.min() ?? today
        return calendar.startOfDay(for: earliest)...shift(today, EnergyTimeline.forecastDays)
    }
    private func shift(_ d: Date, _ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: d) ?? d }
    private func formatted(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0...1))) }
    private var dayLabel: String {
        selected.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    private var dayReadings: HealthEnergyDay? {
        controller.days.first { calendar.isDate($0.date, inSameDayAs: selected) }
    }
    private func reason(_ point: EnergyPoint) -> String {
        switch point.source {
        case .rhythm: return "Estimated from your sleep schedule"
        case .corrected: return "Your updated estimate"
        case .reported: return "From your check-ins"
        case .estimated:
            if point.sleepBased { return "Sleep-based estimate · \(point.supportDays) recorded nights" }
            return point.supportDays > 1
                ? "Estimated from \(point.supportDays) comparable days" : "From a recent check-in"
        case .forecast: return "Forecast from \(point.supportDays) recorded days"
        case .expected: return "Your expected energy"
        }
    }
    private func refresh() {
        Task { await controller.refresh(requestPermission: true, force: true) }
    }
    var body: some View {
        let timeline = store.energyTimeline
        let score = isToday ? timeline.estimate(at: store.now) : timeline.daily(on: selected)
        let hours = timeline.hours(on: selected)
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    JournalHeader(
                        dateLabel: { dateMenu },
                        actionTitle: "Check in", actionIcon: "waveform.path", action: { checkIn = true },
                        settings: { planning = true })
                    if !isFuture { chapterLinks(reader) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(isFuture ? "Energy forecast" : "Energy").font(.largeTitle.weight(.regular))
                            .accessibilityAddTraits(.isHeader).id(Chapter.energy)
                        let scoreLayout = type.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                        scoreLayout {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(score.map { formatted($0.score) } ?? "–")
                                    .font(.system(size: scoreSize, weight: .light, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(Color.trailAmber)
                                Text("/ 10").foregroundStyle(Color.surface.opacity(0.7))
                            }
                            if !type.isAccessibilitySize { Spacer() }
                            if !isFuture {
                                Button {
                                    editTime = min(store.now, day.end.addingTimeInterval(-1))
                                    correction = true
                                } label: {
                                    Label("Update", systemImage: "pencil").font(.subheadline)
                                        .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Update energy estimate")
                            } else {
                                Button { outlookEdit = ForecastEditSelection(date: selected, scope: .day) } label: {
                                    Label("Adjust", systemImage: "pencil").font(.subheadline)
                                        .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
                                }.accessibilityLabel("Adjust expected energy")
                            }
                        }
                        if let score, score.source == .forecast || (score.source == .estimated && !score.sleepBased && score.supportDays >= 3) {
                            Button { showingSources = true } label: {
                                HStack(spacing: 5) {
                                    Text(reason(score))
                                    Image(systemName: "chevron.right").font(.caption2)
                                }.font(.caption).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .accessibilityHint("View the days used to estimate energy")
                            .accessibilityIdentifier("show-energy-sources")
                        } else if isToday, score == nil, let count = timeline.comparableDays(at: store.now), count < 3 {
                            Text("\(count) of 3 comparable days with an energy rating")
                                .font(.caption).foregroundStyle(Color.surface.opacity(0.75))
                        } else {
                            Text(score.map(reason) ?? (isFuture ? "More history needed for a forecast."
                                : isToday ? "No current estimate" : "No estimate for this day."))
                                .font(.caption).foregroundStyle(Color.surface.opacity(0.75))
                        }
                        if isToday, score == nil,
                            let report = store.journal.reports.filter({
                                calendar.isDate($0.date, inSameDayAs: selected) && $0.date <= store.now
                            }).max(by: { $0.date < $1.date })
                        {
                            Text(
                                "Last check-in · " + formatted(report.energy) + "/10 at "
                                    + report.date.formatted(date: .omitted, time: .shortened)
                            )
                            .font(.caption).padding(.top, 4)
                        }
                        Divider().overlay(Color.surface.opacity(0.24)).padding(.vertical, 18)
                        if !isFuture {
                            heartSection
                            sectionRule
                        }
                        energySection(timeline, hours: hours)
                        if isToday {
                            Toggle("Automatic plan adjustments", isOn: automaticPlanning)
                                .font(.subheadline).environment(\.colorScheme, .dark)
                                .disabled(locked).padding(.top, 14)
                        }
                        if !isFuture {
                            readings
                            sectionRule
                            CheckInTrends(endingDay: selected).id(Chapter.checkIns)
                            sectionRule
                            HealthSkipPatternsSection(day: selected).id(Chapter.skips)
                            sectionRule
                            HealthHRVSection(date: min(store.now, day.end.addingTimeInterval(-1))).id(Chapter.hrv)
                            sectionRule
                            HealthActivitiesSection(date: selected).id(Chapter.activities)
                            sectionRule
                            HealthStimulantsSection(date: selected).id(Chapter.stimulants)
                            sectionRule
                            HealthConnectionsSection(date: selected).id(Chapter.connections)
                        }
                    }.padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 26)
                        .frame(maxWidth: 620).frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Color.surface).tint(.trailAmber)
        .background(JournalGround(sky: store.sky))
        .task(id: locked) {
            guard store.ready, !store.restoring, !locked else { return }
            await controller.refresh()
        }
        .sheet(isPresented: $checkIn) {
            NavigationStack { CheckInScreen() }
                .presentationDragIndicator(.visible).preferredColorScheme(store.sky.interfaceScheme)
        }
        .sheet(isPresented: $showingSources) {
            NavigationStack {
                Group {
                    if let basis = store.energyTimeline.modelBasis(at: isToday ? store.now : selected, daily: !isToday) {
                        EnergyEstimateSources(basis: basis) { day in
                            showingSources = false
                            select(day)
                        }
                    } else {
                        ContentUnavailableView("Estimate updated", systemImage: "waveform.path.ecg")
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button { showingSources = false } label: {
                        Image(systemName: "checkmark").font(.headline).frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }.accessibilityLabel("Done")
                } }
            }
        }
        .sheet(isPresented: $datePicker) {
            NavigationStack {
                DatePicker(
                    "View day",
                    selection: Binding(
                        get: { selected },
                        set: {
                            select($0)
                            datePicker = false
                        }),
                    in: bounds, displayedComponents: .date
                )
                .datePickerStyle(.graphical).padding().navigationTitle("View day")
                .toolbar { Button("Done") { datePicker = false } }
            }.presentationDetents([.medium, .large]).tint(.journalAccent)
        }
        .sheet(item: $outlookEdit) { ForecastExpectationEditor(selection: $0) }
        .sheet(isPresented: $correction) {
            HealthCorrectionSheet(day: selected, time: editTime, initial: score?.score ?? 5).environment(store)
                .tint(.journalAccent)
        }
        .sheet(isPresented: $planning) { planningSheet }

    }

    private var dateMenu: some View {
        Menu {
            Button("Previous day", systemImage: "chevron.backward") { select(shift(selected, -1)) }
                .disabled(selected <= bounds.lowerBound)
            Button("Next day", systemImage: "chevron.forward") { select(shift(selected, 1)) }
                .disabled(selected >= bounds.upperBound)
            Button("Choose date", systemImage: "calendar") { datePicker = true }
            if !isToday { Button("Back to today", systemImage: "arrow.uturn.backward") { select(today) } }
        } label: {
            HStack(spacing: 5) {
                Text(dayLabel)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .frame(minHeight: 44)
        }.accessibilityLabel("Browse Health dates").accessibilityValue(dayLabel)
    }
    private func select(_ value: Date) {
        let target = calendar.startOfDay(for: value)
        date = target == today ? nil : target
        heartCursor = nil
        energyCursor = nil
        period = .hourly
    }
    @ViewBuilder private var heartSection: some View {
        let interval = DateInterval(start: heartWeek ? shift(selected, -6) : selected, end: day.end)
        let hourly = controller.heartRates.filter { $0.date >= interval.start && $0.date < interval.end }
        let points: [HealthTracePoint] =
            heartWeek
            ? Dictionary(grouping: hourly, by: { calendar.startOfDay(for: $0.date) }).map { date, samples in
                HealthTracePoint(date, samples.reduce(0) { $0 + $1.bpm } / Double(samples.count))
            }.sorted { $0.date < $1.date }
            : hourly.map { HealthTracePoint($0.date, $0.bpm) }
        let picked = nearest(heartCursor, points)
        let pulse = picked?.value ?? (heartWeek ? points.last?.value : dayReadings?.pulse)
        let pulseDate = picked?.date ?? (heartWeek ? points.last?.date : dayReadings?.pulseTime)
        let header = type >= .xLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout())
        header {
            Text("Heart rate").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
            if type < .xLarge { Spacer() }
            heartPeriod
        }
        if let pulse {
            let readingLayout = type.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            readingLayout {
                Text("\(Int(pulse.rounded())) bpm").font(.title3.monospacedDigit())
                if let pulseDate {
                    Text(
                        (heartWeek ? "Mean of recorded hours · " : picked == nil ? "Latest · " : "Hourly mean · ")
                            + pulseDate.formatted(
                                date: heartWeek ? .abbreviated : .omitted, time: heartWeek ? .omitted : .shortened)
                    )
                    .font(.caption).foregroundStyle(Color.surface.opacity(0.72))
                }
            }
        }
        if !points.isEmpty {
            let lo = max(0, (points.map(\.value).min() ?? 0) - 5)
            let hi = (points.map(\.value).max() ?? 0) + 5
            HealthTrace(
                title: "Heart rate chart", points: points, interval: interval, range: lo...hi, maximumGap: heartWeek ? 90_100 : 3_700,
                tint: Color(red: 1, green: 0.67, blue: 0.53), daily: heartWeek, unit: "bpm", inspected: $heartCursor
            )
            .frame(height: 112).padding(.top, 7)
        } else {
            Text(
                isFuture
                    ? "Heart rate is available after it is measured."
                    : locked
                        ? (store.isDemo
                            ? "Open your journal to connect Apple Health." : "External connections are off.")
                        : controller.refreshedAt == nil
                            ? "Read your pulse, resting heart rate, HRV, sleep and steps."
                            : "No heart rate readings for this period."
            )
            .font(.subheadline).foregroundStyle(Color.surface.opacity(0.8)).padding(.top, 6)
            if !locked && !isFuture && controller.refreshedAt == nil {
                Button(action: refresh) {
                    Text("Read Apple Health").frame(minHeight: 48).contentShape(Rectangle())
                }.disabled(controller.loading)
            }
        }
        if let failure = controller.failure { Text(failure).font(.caption).padding(.top, 4) }
    }
    private var heartPeriod: some View {
        HStack(spacing: 4) {
            periodButton("Day", active: !heartWeek) {
                heartWeek = false
                heartCursor = nil
            }
            periodButton("7 days", active: heartWeek) {
                heartWeek = true
                heartCursor = nil
            }
        }
    }
    private func periodButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(active ? .bold : .medium)).foregroundStyle(
                active ? Color.trailAmber : Color.surface
            )
            .padding(.horizontal, 5).frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? Color.trailAmber : .clear).frame(height: 2).padding(.bottom, 5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }
    private func nearest(_ date: Date?, _ points: [HealthTracePoint]) -> HealthTracePoint? {
        date.flatMap { target in
            points.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
        }
    }
    @ViewBuilder private func energySection(_ timeline: EnergyTimeline, hours: [EnergyPoint]) -> some View {
        let interval: DateInterval =
            switch period {
            case .hourly: day
            case .history: DateInterval(start: shift(min(selected, today), -13), end: shift(min(selected, today), 1))
            case .forecast: DateInterval(start: shift(today, 1), end: shift(today, EnergyTimeline.forecastDays + 1))
            }
        let data =
            period == .hourly
            ? hours
            : (0..<(period == .history ? 14 : EnergyTimeline.forecastDays)).compactMap { offset in
                timeline.daily(on: shift(interval.start, offset))
            }
        let points = data.map { HealthTracePoint($0.date, $0.score, predicted: $0.source == .forecast || $0.source == .expected) }
        Text("Energy trend").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
        let periodLayout = type >= .accessibility3
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout())
        periodLayout {
            ForEach(EnergyRange.allCases, id: \.rawValue) { range in
                periodButton(range.rawValue, active: range == period) {
                    period = range
                    energyCursor = nil
                }
            }
        }
        if points.isEmpty {
            Text(
                period == .forecast
                    ? "More check-in history is needed for a forecast."
                    : "No energy readings for this period."
            )
            .font(.subheadline).foregroundStyle(Color.surface.opacity(0.8)).padding(.vertical, 8)
        } else {
            HealthTrace(
                title: "Energy chart", points: points, interval: interval, range: 0...10, maximumGap: period == .hourly ? 3_700 : 90_100,
                tint: .trailAmber, daily: period != .hourly, unit: "out of 10", inspected: $energyCursor
            )
            .frame(height: 132).padding(.top, 4)
            if period == .hourly, data.contains(where: { $0.source == .forecast }) {
                Label("Dashed line · forecast", systemImage: "line.diagonal")
                    .font(.caption).foregroundStyle(Color.surface.opacity(0.76))
            }
            if let point = nearest(energyCursor, points), let info = data.first(where: { $0.date == point.date }) {
                HStack {
                    Text("\(formatted(point.value))/10 · " + reason(info))
                    Spacer()
                    if period != .hourly {
                        Button(point.date.formatted(.dateTime.month(.abbreviated).day()) + " ›") { select(point.date) }
                    } else {
                        Text(point.date, style: .time)
                    }
                }.font(.caption).frame(minHeight: 44)
            }
        }
        if period == .hourly {
            DisclosureGroup("Hourly breakdown", isExpanded: $showHours) {
                let byDate = Dictionary(grouping: hours, by: \.date)
                ForEach(hourStarts, id: \.self) { date in
                    let p = byDate[date]?.first
                    let row = HStack(alignment: .firstTextBaseline) {
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        if let p {
                            Text(reason(p)).font(.caption).foregroundStyle(Color.surface.opacity(0.75))
                            Text(formatted(p.score) + "/10").font(.subheadline.monospacedDigit())
                        } else {
                            Text("No estimate").font(.caption).foregroundStyle(Color.surface.opacity(0.65))
                        }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                    if date <= store.now {
                        Button {
                            editTime = min(store.now, date.addingTimeInterval(3599))
                            correction = true
                        } label: {
                            row
                        }
                        .buttonStyle(.plain).accessibilityHint("Update this hour’s energy")
                    } else {
                        Button { outlookEdit = ForecastEditSelection(date: date, scope: .hour) } label: { row }
                            .buttonStyle(.plain).accessibilityHint("Adjust the energy you expect in this hour")
                    }
                }
            }.padding(.top, 12)
        } else if period == .forecast {
            ForEach(data, id: \.date) { prediction in
                Button {
                    select(prediction.date)
                } label: {
                    HStack {
                        Text(prediction.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        Spacer()
                        Text(formatted(prediction.score) + "/10").monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption2)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
            }
        }
        if period == .history || period == .forecast {
            NavigationLink {
                ForecastHistoryScreen()
            } label: {
                Label("Past forecasts", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
        }
    }
    private var hourStarts: [Date] {
        Array(stride(from: day.start.timeIntervalSince1970, to: day.end.timeIntervalSince1970, by: 3600))
            .map(Date.init(timeIntervalSince1970:))
    }
    @ViewBuilder private var readings: some View {
        if let d = dayReadings, !isFuture {
            Divider().overlay(Color.surface.opacity(0.24)).padding(.vertical, 16)
            DisclosureGroup {
                ForEach(
                    [
                        ("Resting heart rate", d.resting, "bpm"), ("Heart rate variability", d.variability, "ms"),
                        ("Sleep", d.sleepHours, "h"), ("Steps", d.steps.map(Double.init), ""),
                    ], id: \.0
                ) { item in
                    HStack {
                        Text(item.0)
                        Spacer()
                        Text(item.1.map { formatted($0) + (item.2.isEmpty ? "" : " " + item.2) } ?? "No reading")
                    }.font(.subheadline).padding(.vertical, 6).accessibilityElement(children: .combine)
                }
            } label: {
                Text("Health readings").foregroundStyle(Color.surface)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
        }
    }
    private var automaticPlanning: Binding<Bool> {
        Binding(get: { privacy.automaticHealthPlanning && !locked }, set: {
            privacy.automaticHealthPlanning = $0
            if $0 { refresh() }
        })
    }
    private var planningSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        "Automatic plan adjustments",
                        isOn: automaticPlanning
                    )
                    .disabled(locked)
                } footer: {
                    Text(
                        locked
                            ? "Automatic Health planning is available in your journal with external connections enabled."
                            : "Pulse refreshes available Health estimates when you use the app and adjusts flexible work. Your manual capacity setting takes priority."
                    )
                }
                if !privacy.automaticHealthPlanning && !locked {
                    Toggle(
                        "Use for today’s plan",
                        isOn: Binding(
                            get: { store.healthPlanningToday },
                            set: { store.useHealthForToday($0) })
                    )
                    .disabled(!store.healthPlanningToday && store.energyTimeline.estimate(at: store.now) == nil)
                }
                if !locked {
                    Button("Refresh Apple Health", action: refresh).disabled(controller.loading)
                    Button("Clear Health readings", role: .destructive) {
                        privacy.sleepConnected = false
                        privacy.automaticHealthPlanning = false
                        store.useHealthForToday(false)
                        controller.clear()
                    }
                }
            }.formPaper().navigationTitle("Health planning").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { planning = false } }
        }.presentationDetents([.medium, .large]).tint(.journalAccent)
    }
}

private struct HealthCorrectionSheet: View {
    @Environment(Workspace.self) var store
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var time: Date
    @State private var score: Double
    init(day: Date, time: Date, initial: Double) {
        self.day = day
        _score = State(initialValue: initial.rounded())
        _time = State(initialValue: time)
    }
    private var previous: EnergyCorrection? {
        store.journal.energyCorrections?.last { Calendar.current.isDate($0.date, equalTo: time, toGranularity: .hour) }
    }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Time", selection: $time,
                    in:
                        day...min(
                            Date.now, Calendar.current.dateInterval(of: .day, for: day)!.end.addingTimeInterval(-1)),
                    displayedComponents: .hourAndMinute)
                Stepper("Energy · \(Int(score)) / 10", value: $score, in: 0...10)
                if previous != nil {
                    Button("Remove update", role: .destructive) {
                        store.updateEnergyCorrection(at: time, score: nil)
                        dismiss()
                    }
                }
            }
            .onAppear { loadScore() }
            .onChange(of: time) { loadScore() }
            .formPaper().navigationTitle("Update energy").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.updateEnergyCorrection(at: time, score: score)
                        dismiss()
                    }
                }
            }
        }.presentationDetents([.medium, .large])
    }
    private func loadScore() {
        score =
            (previous?.score ?? store.energyTimeline.estimate(at: time)?.score ?? store.energyTimeline.daily(on: day)?
            .score ?? 5).rounded()
    }
}
