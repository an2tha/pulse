import Charts
import PulseEngine
import SwiftUI

struct HealthStimulantsSection: View {
    let date: Date
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    @State private var substance = Stimulant.caffeine
    @State private var hasExplicitSelection = false
    @State private var intake: StimulantIntake?
    @State private var sample: StimulantBloodSample?
    @State private var horizon = 1.0
    @State private var cursor: Date?
    @State private var forecastEdit: ForecastEditSelection?
    @State private var showingInfo = false
    @State private var showAllEntries = false
    @State private var showAllLabs = false

    private let calendar = Calendar.current
    private let muted = Color.surface.opacity(0.76)
    private var day: DateInterval { calendar.dateInterval(of: .day, for: date)! }
    private var asOf: Date { min(store.now, day.end.addingTimeInterval(-1)) }
    private var isToday: Bool { calendar.isDate(store.now, inSameDayAs: date) }
    private var draftTime: Date {
        guard !isToday else { return .now }
        let now = calendar.dateComponents([.hour, .minute], from: .now)
        return calendar.date(bySettingHour: now.hour ?? 12, minute: now.minute ?? 0, second: 0, of: date) ?? date
    }
    private var entries: [StimulantIntake] {
        (store.journal.stimulantIntakes ?? []).filter { $0.date <= asOf }.sorted { $0.date > $1.date }
    }
    private func selectLatest() {
        guard !hasExplicitSelection else { return }
        let lastIntake = (store.journal.stimulantIntakes ?? []).filter { $0.date <= asOf }.max { $0.date < $1.date }
        let lastLab = (store.journal.stimulantBloodSamples ?? []).filter { $0.date <= asOf }.max { $0.date < $1.date }
        if let lastLab, lastLab.date > (lastIntake?.date ?? .distantPast) {
            substance = lastLab.substance
        } else {
            substance = lastIntake?.substance ?? .caffeine
        }
    }

    private var measurements: [StimulantBloodSample] {
        (store.journal.stimulantBloodSamples ?? []).filter { $0.date <= asOf && $0.substance == substance }.sorted { $0.date < $1.date }
    }
    private struct Projection: Identifiable {
        let date: Date
        let amount: Double
        let low, high: Double?
        var id: Date { date }
    }
    private var asOfTime: String { isToday ? "now" : "at day’s end" }

    var body: some View {
        let history = entries
        let matching = history.filter { $0.substance == substance }
        let today = matching.filter { $0.date >= day.start }
        let labs = measurements
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); substancePicker; infoButton }
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    HStack { substancePicker; infoButton }
                }
            }
            if let source = substance.sources.first {
                let points = projections(from: matching)
                if !points.isEmpty {
                    clearance(points)
                } else if let latest = today.first {
                    Text(latest.milligrams.map { $0.formatted() + " " + latest.unit.rawValue + " labeled" } ?? "Amount unknown")
                        .font(.title3.monospacedDigit())
                } else {
                    Text("No intake logged for this day.").font(.subheadline).foregroundStyle(muted)
                }
                if points.isEmpty && !today.isEmpty && (substance == .caffeine || substance == .theobromine) {
                    Text("An unknown amount in the past week leaves the estimate unavailable.")
                        .font(.caption).foregroundStyle(muted)
                }
                actions {
                    Button { intake = .init(substance: substance, source: source, date: draftTime) } label: {
                        Label("Log intake", systemImage: "plus").frame(minHeight: 44)
                    }.accessibilityIdentifier("health-log-intake")
                    if !matching.isEmpty { repeatMenu(matching) }
                    else if labs.isEmpty && substance != .other { addLabButton }
                }
                if let last = today.first {
                    let visible = showAllEntries ? today[...] : today.prefix(3)
                    ForEach(visible) { item in intakeRow(item, history: history) }
                    if today.count > 3 {
                        Button(showAllEntries ? "Show fewer entries" : "Show all \(today.count) entries") { showAllEntries.toggle() }
                            .frame(minHeight: 44)
                    }
                    response(last, history: history)
                }
                let recent = matching.filter { asOf.timeIntervalSince($0.date) <= 30 * 86_400 && $0.perceivedEffect != nil }
                if !recent.isEmpty {
                    Text("Reported effects · 30 days").font(.headline).padding(.top, 4)
                    let summary = PerceivedStimulantEffect.allCases.compactMap { effect -> String? in
                        let count = recent.count { $0.perceivedEffect == effect }
                        return count == 0 ? nil : "\(count) " + effect.rawValue.lowercased()
                    }
                    Text(summary.joined(separator: " · ")).font(.subheadline).foregroundStyle(muted)
                }
            }
            if substance != .other && (!matching.isEmpty || !labs.isEmpty || substance.sources.isEmpty) {
                bloodSection(labs, history: history)
            }
        }
        .onChange(of: substance) { resetSelection() }
        .onAppear { selectLatest() }
        .onChange(of: day.start) { resetSelection(); selectLatest() }
        .sheet(item: $intake) { entry in NavigationStack { StimulantIntakeEditor(entry: entry) }.tint(.journalAccent) }
        .sheet(item: $sample) { entry in NavigationStack { BloodSampleEditor(sample: entry) }.tint(.journalAccent) }
        .sheet(item: $forecastEdit) { ForecastExpectationEditor(selection: $0) }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                List { aboutEstimates }.formPaper().navigationTitle("About the estimates").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button { showingInfo = false } label: {
                            Image(systemName: "checkmark").font(.headline).foregroundStyle(Color.journalInk)
                                .frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Done")
                    } }
            }.tint(.journalAccent)
        }
    }

    private var heading: some View {
        Text("Stimulants").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("health-stimulants-heading")
    }

    private var infoButton: some View {
        Button { showingInfo = true } label: {
            Image(systemName: "info.circle").font(.subheadline).frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("About stimulant estimates").foregroundStyle(muted)
    }

    private var addLabButton: some View {
        Button { sample = .init(substance: substance, date: draftTime, nanogramsPerML: 0, postAbsorption: false) } label: {
            Label("Add lab result", systemImage: "drop").font(.subheadline).frame(minHeight: 44)
        }.accessibilityIdentifier("health-add-stimulant-lab")
    }

    private var substancePicker: some View {
        Menu {
            Picker("Substance", selection: Binding(get: { substance }, set: { hasExplicitSelection = true; substance = $0 })) {
                ForEach(Stimulant.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 5) { Text(substance.rawValue); Image(systemName: "chevron.down").font(.caption2) }
                .font(.subheadline).frame(minHeight: 44)
        }.accessibilityLabel("Substance").accessibilityValue(substance.rawValue)
    }

    private func actions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 16))
        return layout { content() }.font(.subheadline).foregroundStyle(Color.trailAmber)
    }

    private func repeatMenu(_ matching: [StimulantIntake]) -> some View {
        struct Product: Hashable { let name: String; let source: String; let amount: Double?; let unit: StimulantLabelUnit }
        var seen: Set<Product> = []
        let prior = matching.filter { seen.insert(Product(name: $0.displayName, source: $0.source, amount: $0.milligrams, unit: $0.unit)).inserted }
        return Menu {
            ForEach(prior) { recent in
                Button(recent.displayName + (recent.milligrams.map { " · " + $0.formatted() + " " + recent.unit.rawValue } ?? "")) {
                    var copy = StimulantIntake(substance: substance, source: recent.source, date: draftTime, milligrams: recent.milligrams)
                    copy.productName = recent.productName
                    copy.labelUnit = recent.labelUnit
                    intake = copy
                }
            }
        } label: {
            Label("Previous product", systemImage: "clock.arrow.circlepath").frame(minHeight: 44)
        }
    }

    private func resetSelection() {
        cursor = nil
        showAllEntries = false
        showAllLabs = false
        horizon = 1
    }

    private func projections(from history: [StimulantIntake]) -> [Projection] {
        guard substance == .caffeine || substance == .theobromine else { return [] }
        let recent = history.filter { asOf.timeIntervalSince($0.date) <= 7 * 86_400 }
        guard !recent.isEmpty else { return [] }
        if StimulantHistory.modeledAmount(substance, entries: recent, at: asOf) == nil { return [] }
        return (0...24).compactMap { hour in
            let time = asOf.addingTimeInterval(Double(hour) * 3600)
            guard let amount = StimulantHistory.modeledAmount(substance, entries: recent, at: time) else { return nil }
            return Projection(date: time, amount: amount,
                              low: substance == .caffeine ? StimulantHistory.modeledAmount(substance, entries: recent, at: time, halfLifeHours: 2) : nil,
                              high: substance == .caffeine ? StimulantHistory.modeledAmount(substance, entries: recent, at: time, halfLifeHours: 8) : nil)
        }
    }

    private func clearance(_ points: [Projection]) -> some View {
        let picked = cursor.flatMap { target in points.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) } } ?? points[0]
        return VStack(alignment: .leading, spacing: 4) {
            Text("Modeled amount remaining").font(.subheadline).foregroundStyle(muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(picked.amount.formatted(.number.precision(.fractionLength(0...1))) + " mg").font(.title3.monospacedDigit())
                Text(cursor == nil ? asOfTime : picked.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(muted)
            }
            Chart {
                ForEach(points) { point in
                    if let low = point.low, let high = point.high {
                        AreaMark(x: .value("Time", point.date), yStart: .value("Faster clearance", low), yEnd: .value("Slower clearance", high))
                            .foregroundStyle(Color.trailAmber.opacity(0.18))
                    }
                    LineMark(x: .value("Time", point.date), y: .value("Estimated mg", point.amount)).foregroundStyle(Color.trailAmber)
                }
                if cursor != nil {
                    RuleMark(x: .value("Selected time", picked.date)).foregroundStyle(muted)
                }
            }.chartXScale(domain: asOf...asOf.addingTimeInterval(86_400))
                .modifier(HealthStimulantChartAxes())
                .chartXSelection(value: $cursor)
                .frame(height: 105).accessibilityLabel("Estimated clearance over 24 hours")
            Text(substance == .caffeine ? "24 hours without further intake · shaded range uses 2–8 h half-lives" : "24 hours without further intake · population estimate")
                .font(.caption).foregroundStyle(muted)
        }
    }

    private func intakeRow(_ item: StimulantIntake, history: [StimulantIntake]) -> some View {
        Button { intake = item } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.displayName).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(item.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(muted)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(muted)
                }
                Text(item.milligrams.map { $0.formatted() + " " + item.unit.rawValue + " labeled" } ?? "Amount unknown")
                    .font(.caption).foregroundStyle(muted)
                if let before = item.baselineEnergy, let after = item.responseEnergy, (item.responseTime ?? .distantFuture) <= asOf {
                    Text("Energy \(before) → \(after)/10").font(.caption)
                }
                if item.isPatch {
                    Text(item.ended.flatMap { $0 <= asOf ? "Removed " + $0.formatted(date: .abbreviated, time: .shortened) : nil } ?? "Removal unlogged")
                        .font(.caption)
                }
                let alongside = StimulantHistory.alongside(item, entries: history)
                if !alongside.isEmpty {
                    Text("Logged alongside " + Set(alongside.map { $0.substance == .other ? $0.displayName : $0.substance.rawValue }).sorted().joined(separator: ", ")).font(.caption)
                }
                if let note = item.coUseNote { Text(note).font(.caption) }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func bloodSection(_ labs: [StimulantBloodSample], history: [StimulantIntake]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let latest = labs.last {
                Text("Blood measurements").font(.headline).padding(.top, 6)
                let recent = labs.suffix(20)
                Chart {
                    ForEach(recent) { reading in
                        PointMark(x: .value("Collection time", reading.date), y: .value("Measured ng/mL", reading.nanogramsPerML))
                            .foregroundStyle(Color.surface)
                    }
                    ForEach(0...24, id: \.self) { hour in
                        let time = latest.date.addingTimeInterval(Double(hour) * 3600)
                        if let level = StimulantHistory.projectedBlood(latest, at: time, samples: labs, entries: history) {
                            LineMark(x: .value("Time", time), y: .value("Illustrative ng/mL", level))
                                .lineStyle(.init(lineWidth: 2, dash: [4, 4])).foregroundStyle(Color.trailAmber)
                        }
                    }
                }.modifier(HealthStimulantChartAxes()).frame(height: 104)
                    .accessibilityLabel("Measured blood concentrations")
                Text("Dots show measured levels in ng/mL." + (latest.postAbsorption ? " Dashes show the modeled decline where available." : ""))
                    .font(.caption).foregroundStyle(muted)
                ForEach(showAllLabs ? Array(labs.reversed()) : Array(labs.suffix(1))) { reading in
                    Button { sample = reading } label: {
                        HStack {
                            Text(reading.date.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(reading.nanogramsPerML.formatted() + " ng/mL").monospacedDigit()
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.font(.subheadline).buttonStyle(.plain)
                }
                if labs.count > 1 {
                    Button(showAllLabs ? "Show latest result" : "Show all \(labs.count) results") { showAllLabs.toggle() }.frame(minHeight: 44)
                }
            } else if substance.sources.isEmpty {
                Text("No blood measurements through this day.").font(.subheadline).foregroundStyle(muted)
            }
            addLabButton
        }
    }

    private func response(_ latest: StimulantIntake, history: [StimulantIntake]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if latest.comparableAmount != nil {
                let matches = StimulantHistory.comparableResponses(to: latest, entries: history, after: horizon, asOf: asOf)
                HStack {
                    Text("Personal response").font(.headline)
                    Spacer()
                    Menu {
                        Picker("Time after intake", selection: $horizon) {
                            ForEach([1.0, 2, 4, 6], id: \.self) { Text($0 == 1 ? "1 hour" : "\(Int($0)) hours").tag($0) }
                        }
                    } label: {
                        Label("\(Int(horizon)) h", systemImage: "clock").font(.subheadline).frame(minHeight: 44)
                    }.accessibilityLabel("Time after intake").accessibilityValue("\(Int(horizon)) hours")
                }
                if let delta = StimulantHistory.medianChange(matches) {
                    Text(delta.formatted(.number.sign(strategy: .always())) + " / 10")
                        .font(.title3.monospacedDigit()).accessibilityLabel("Typical energy change " + delta.formatted())
                    Text("Typical energy change across \(matches.count) comparable reports.")
                        .font(.caption).foregroundStyle(muted)
                    if let baseline = latest.baselineEnergy {
                        let estimated = min(10, max(0, Double(baseline) + delta))
                        Text("Estimated energy after \(Int(horizon)) h · " + estimated.formatted() + "/10").font(.subheadline)
                        let target = latest.date.addingTimeInterval(horizon * 3600)
                        if let hour = calendar.dateInterval(of: .hour, for: target), hour.start > store.now {
                            Button("Review in Plan", systemImage: "calendar") {
                                forecastEdit = ForecastEditSelection(date: target, scope: .hour, proposedScore: estimated)
                            }.frame(minHeight: 44)
                        }
                    }
                    if matches.count >= 6, let first = StimulantHistory.medianChange(Array(matches.prefix(3))),
                       let last = StimulantHistory.medianChange(Array(matches.suffix(3))) {
                        Text("First three · " + first.formatted(.number.sign(strategy: .always())) + "    Latest three · " + last.formatted(.number.sign(strategy: .always())))
                            .font(.caption).foregroundStyle(muted)
                    }
                } else {
                    Text("A personal estimate needs three earlier, comparable before-and-after reports.")
                        .font(.caption).foregroundStyle(muted)
                }
            }
        }
    }
    @ViewBuilder private var aboutEstimates: some View {
        Text("Intake records cannot establish a blood concentration, receptor sensitivity, or whether a combination is safe. The log highlights close timing and changes in your own reported response. Use lab results for measured levels.")
        if let halfLife = substance.halfLifeHours {
            Text("The illustrative half-life for " + substance.rawValue.lowercased() + " is " + halfLife.formatted() + " hours. Individual values vary. Estimates are unsuitable for choosing a dose or timing another use.")
        } else {
            Text("Custom products support intake and personal response history. Their ingredients have no built-in clearance model.")
        }
        Link("EFSA · caffeine", destination: URL(string: "https://www.efsa.europa.eu/sites/default/files/corporate_publications/files/efsaexplainscaffeine150527.pdf")!)
        Link("Human methylxanthine kinetics", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC1401099/")!)
        Link("Theobromine disposition", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/627135/")!)
        Link("Nicotine delivery by formulation", destination: URL(string: "https://doi.org/10.1007/s40262-020-00960-5")!)
        Link("Nicotine and cotinine kinetics", destination: URL(string: "https://www.ncbi.nlm.nih.gov/books/NBK507191/")!)
        Link("FDA · understanding interactions", destination: URL(string: "https://www.fda.gov/drugs/resources-drugs/drug-interactions-what-you-should-know")!)
    }


}

private struct HealthStimulantChartAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: .init(lineWidth: 0.6)).foregroundStyle(Color.surface.opacity(0.2))
                    AxisValueLabel().foregroundStyle(Color.surface.opacity(0.76))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel().foregroundStyle(Color.surface.opacity(0.76))
                }
            }
    }
}

private struct StimulantIntakeEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.dismiss) private var dismiss
    @State var entry: StimulantIntake
    @State private var deleting = false
    private var existing: Bool { store.journal.stimulantIntakes?.contains { $0.id == entry.id } == true }

    private var title: String {
        (existing ? "Edit " : "Log ") + (entry.substance == .other ? "intake" : entry.substance.rawValue.lowercased())
    }

    private func entryField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.body).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
            TextField(label, text: text, prompt: Text(prompt).foregroundStyle(Color.moss), axis: .vertical)
                .font(.body).frame(minHeight: 44).accessibilityLabel(label)
        }
    }

    var body: some View {
        Form {
            if type.isAccessibilitySize {
                Text(title).font(.title2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Section {
                IntakeChoice(label: "Source", selection: $entry.source, options: entry.substance.sources, name: { $0 })
                    .onChange(of: entry.source) {
                        if !entry.isPatch { entry.ended = nil }
                        let preferred = entry.supportedUnits[0]
                        if preferred != entry.unit { entry.milligrams = nil }
                        entry.labelUnit = preferred
                        if preferred != .liquid { entry.liquidVolumeML = nil }
                    }
                let productLabel = entry.substance == .other ? "Nonprescription product name" : "Product name (optional)"
                entryField(productLabel, prompt: "Name", text: Binding(
                    get: { entry.productName ?? "" },
                    set: { entry.productName = $0.isEmpty ? nil : $0 }
                ))
                IntakeDateFields(label: "Taken", date: $entry.date, bounds: Date.distantPast...Date.now)
                if entry.supportedUnits.count > 1 {
                    IntakeChoice(label: "Label unit", selection: Binding(get: { entry.unit }, set: { unit in
                        entry.labelUnit = unit
                        entry.milligrams = nil
                        entry.liquidVolumeML = nil
                    }), options: entry.supportedUnits, name: { $0.rawValue })
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Labeled amount in " + entry.unit.rawValue + " (optional)").font(.body)
                        .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                    TextField("Amount", value: $entry.milligrams, format: .number,
                              prompt: Text(entry.unit.rawValue).foregroundStyle(Color.moss))
                        .font(.body).keyboardType(.decimalPad)
                        .accessibilityLabel("Labeled amount in " + entry.unit.rawValue + " (optional)")
                }
                if entry.unit == .liquid {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Liquid used in mL (optional)").fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                        TextField("Liquid used in mL (optional)", value: $entry.liquidVolumeML, format: .number, prompt: Text("mL"))
                            .keyboardType(.decimalPad)
                    }
                    if let total = entry.comparableAmount {
                        IntakeLabelAndValue(label: "Nicotine in liquid used", value: total.formatted() + " mg")
                    }
                }
                if entry.isPatch && entry.date <= Date.now {
                    Toggle("Patch removed", isOn: Binding(get: { entry.ended != nil }, set: { entry.ended = $0 ? .now : nil }))
                    if entry.ended != nil {
                        IntakeDateFields(label: "Removed", date: Binding(get: { entry.ended ?? .now }, set: { entry.ended = $0 }), bounds: entry.date...max(entry.date, Date.now))
                    }
                }
            }
            if existing {
                let others = StimulantHistory.alongside(entry, entries: store.journal.stimulantIntakes ?? [])
                if !others.isEmpty || entry.coUseNote != nil {
                    Section("Co-use") {
                        ForEach(others) { other in
                            IntakeLabelAndValue(label: other.displayName, value: other.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        entryField("Effect noticed together", prompt: "Note", text: Binding(get: { entry.coUseNote ?? "" },
                            set: { entry.coUseNote = $0.isEmpty ? nil : $0 }))
                        if others.contains(where: { Set([$0.substance, entry.substance]) == Set([.caffeine, .nicotine]) }) {
                            Text("Caffeine and nicotine can both raise blood pressure. Individual responses vary.")
                            Link("Human interaction study", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/8354027/")!)
                        }
                        Text("This view groups intakes within two hours and entries during logged patch wear. The window describes timing only.")
                            .font(.footnote).foregroundStyle(Color.moss)
                    }
                }
            }
            Section {
                Text("Energy response").font(.headline).foregroundStyle(Color.journalInk).accessibilityAddTraits(.isHeader)
                IntakeChoice(label: "Perceived effect", selection: $entry.perceivedEffect,
                             options: [nil] + PerceivedStimulantEffect.allCases.map(Optional.some),
                             name: { $0?.rawValue ?? "Unrecorded" })
                energyChoice("Before intake", selection: $entry.baselineEnergy)
                    .onChange(of: entry.baselineEnergy) {
                        if entry.baselineEnergy == nil { entry.responseTime = nil; entry.responseEnergy = nil }
                    }
                if entry.baselineEnergy != nil {
                    energyChoice("Follow-up energy", selection: $entry.responseEnergy)
                        .onChange(of: entry.responseEnergy) {
                            if entry.responseEnergy == nil { entry.responseTime = nil }
                            else if entry.responseTime == nil { entry.responseTime = .now }
                        }
                    if entry.responseEnergy != nil {
                        IntakeDateFields(label: "Follow-up", date: Binding(get: { entry.responseTime ?? .now }, set: { entry.responseTime = $0 }),
                                   bounds: entry.date...max(entry.date, Date.now))
                    }
                }
                entryField("Effects or other products taken", prompt: "Notes", text: $entry.notes)
            }
            if existing { Button("Delete intake", role: .destructive) { deleting = true } }
        }.formPaper().navigationTitle(type.isAccessibilitySize ? "" : title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(Color.journalInk).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    store.change { journal in
                        var entries = journal.stimulantIntakes ?? []
                        entries.removeAll { $0.id == entry.id }
                        entries.append(entry)
                        journal.stimulantIntakes = entries
                    }
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.headline).foregroundStyle(Color.journalInk).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Save").disabled(!entry.isValid || entry.date > Date.now || (entry.responseTime ?? .distantPast) > Date.now)
            }
        }
        .confirmationDialog("Delete this intake?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { store.change { $0.stimulantIntakes?.removeAll { $0.id == entry.id } }; dismiss() }
        }
    }

    private func energyChoice(_ label: String, selection: Binding<Int?>) -> some View {
        IntakeChoice(label: label, selection: selection, options: [nil] + (0...10).map(Optional.some),
                     name: { $0.map { "\($0)/10" } ?? "Unrecorded" })
    }
}

private struct BloodSampleEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var sample: StimulantBloodSample
    @State private var level: Double?
    @State private var micrograms = false
    @State private var deleting = false

    init(sample: StimulantBloodSample) {
        _sample = State(initialValue: sample)
        _level = State(initialValue: sample.nanogramsPerML)
    }
    private var existing: Bool { store.journal.stimulantBloodSamples?.contains { $0.id == sample.id } == true }
    var body: some View {
        Form {
            Section(sample.substance.rawValue) {
                DatePicker("Collected", selection: $sample.date, in: ...Date.now)
                Picker("Lab unit", selection: $micrograms) {
                    Text("ng/mL").tag(false)
                    Text("mg/L or µg/mL").tag(true)
                }.onChange(of: micrograms) { old, new in
                    if old != new, let value = level { level = new ? value / 1000 : value * 1000 }
                }
                TextField("Measured concentration", value: $level, format: .number).keyboardType(.decimalPad)
                Toggle("Model post-absorption decline", isOn: $sample.postAbsorption)
                if sample.postAbsorption {
                    Text("Use only after absorption and metabolite formation have ended, with no ongoing delivery. A later logged intake interrupts the scenario.")
                        .font(.footnote)
                }
            }
            if existing { Button("Delete result", role: .destructive) { deleting = true } }
        }.formPaper().navigationTitle("Lab result").navigationBarTitleDisplayMode(.inline)
        .onAppear { if !existing && sample.nanogramsPerML == 0 { level = nil } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(Color.journalInk).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard let level else { return }
                    sample.nanogramsPerML = level * (micrograms ? 1000 : 1)
                    guard sample.isValid else { return }
                    store.change {
                        var labs = $0.stimulantBloodSamples ?? []
                        labs.removeAll { $0.id == sample.id }
                        labs.append(sample)
                        $0.stimulantBloodSamples = labs
                    }
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.headline).foregroundStyle(Color.journalInk).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Save").disabled(level.map { !($0 * (micrograms ? 1000 : 1)).isFinite || $0 < 0 } ?? true)
            }
        }
        .confirmationDialog("Delete this lab result?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { store.change { $0.stimulantBloodSamples?.removeAll { $0.id == sample.id } }; dismiss() }
        }
    }
}
