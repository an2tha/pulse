import Charts
import HealthKit
import SwiftUI

enum OneRepDestination: String, CaseIterable, Identifiable {
    case quickLog = "Quick log a workout"
    case coach = "Ask OneRep AI"
    case progress = "View progress in OneRep"
    case workouts = "Workout library"
    var id: Self { self }

    func url(at date: Date = .now, timeZone: TimeZone = .current) -> URL {
        var components = URLComponents()
        components.scheme = "onerep"
        switch self {
        case .quickLog:
            components.host = "workouts"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            components.queryItems = [.init(name: "logPast", value: formatter.string(from: date))]
        case .coach: components.host = "coach"
        case .workouts: components.host = "workouts"
        case .progress: components.host = "progress"
        }
        return components.url!
    }
}

struct OneRepHealthStats {
    struct Measurement {
        let value: Double
        let date: Date
    }
    var workoutMinutes: Double?
    var trainingByDay: [Date: Double] = [:]
    var workouts = 0
    var waterML: Double?
    var proteinGrams: Double?
    var weightKG: Measurement?
    var hasReadings: Bool { workoutMinutes != nil || waterML != nil || proteinGrams != nil || weightKG != nil }
}

actor OneRepHealthReader {
    private let health = HKHealthStore()
    static let sourceBundle = "com.ananthh.onerep"

    func read(requestAccess: Bool, at date: Date = .now) async throws -> OneRepHealthStats {
        guard HKHealthStore.isHealthDataAvailable() else { throw HKError(.errorHealthDataUnavailable) }
        let water = HKQuantityType(.dietaryWater)
        let protein = HKQuantityType(.dietaryProtein)
        let mass = HKQuantityType(.bodyMass)
        if requestAccess {
            try await health.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), water, protein, mass])
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let weekFilter = HKQuery.predicateForSamples(withStart: week, end: date, options: [.strictStartDate])
        let workoutSources = try await HKSourceQueryDescriptor(predicate: .workout(weekFilter)).result(for: health)
            .filter { $0.bundleIdentifier == Self.sourceBundle }
        var stats = OneRepHealthStats()
        if !workoutSources.isEmpty {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                weekFilter, HKQuery.predicateForObjects(from: Set(workoutSources))])
            let workouts = try await HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: []).result(for: health)
            if !workouts.isEmpty {
                for workout in workouts {
                    stats.trainingByDay[calendar.startOfDay(for: workout.startDate), default: 0] += workout.duration / 60
                }
                stats.workouts = workouts.count
                stats.workoutMinutes = workouts.reduce(0) { $0 + $1.duration } / 60
            }
        }
        let waterSamples = try await quantities(water, from: today, through: date)
        if !waterSamples.isEmpty { stats.waterML = waterSamples.reduce(0) { $0 + $1.quantity.doubleValue(for: .literUnit(with: .milli)) } }
        let proteinSamples = try await quantities(protein, from: today, through: date)
        if !proteinSamples.isEmpty { stats.proteinGrams = proteinSamples.reduce(0) { $0 + $1.quantity.doubleValue(for: .gram()) } }
        if let latest = try await quantities(mass, from: nil, through: date, limit: 1).first {
            stats.weightKG = .init(value: latest.quantity.doubleValue(for: .gramUnit(with: .kilo)), date: latest.endDate)
        }
        return stats
    }

    private func quantities(_ type: HKQuantityType, from start: Date?, through end: Date, limit: Int? = nil) async throws -> [HKQuantitySample] {
        let dates = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let sources = try await HKSourceQueryDescriptor(predicate: .quantitySample(type: type, predicate: dates)).result(for: health)
            .filter { $0.bundleIdentifier == Self.sourceBundle }
        guard !sources.isEmpty else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [dates, HKQuery.predicateForObjects(from: Set(sources))])
        return try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: limit).result(for: health)
    }
}

struct OneRepScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @AppStorage("readOneRepHealth", store: PrivacySession.preferences) private var readsHealth = false
    var embedded = false
    var date: Date?
    private struct Reading {
        let day: Date
        let stats: OneRepHealthStats
    }
    @State private var reading: Reading?
    @State private var reader = OneRepHealthReader()
    @State private var request: UUID?
    @State private var asking = false
    @State private var healthError: String?
    @State private var launchProblem: String?

    @State private var linked = false
    @State private var canLog = false
    @State private var logging = false
    @State private var workoutRevision = 0

    private var end: Date {
        min(.now, Calendar.current.dateInterval(of: .day, for: date ?? .now)?.end.addingTimeInterval(-0.001) ?? .now)
    }
    private var enabled: Bool { store.journal.connections?.oneRep == true }
    private var available: Bool { !store.isDemo && !privacy.lockConnections && !store.restoring }

    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("OneRep").font(.title2).accessibilityAddTraits(.isHeader).accessibilityIdentifier("health-onerep-heading")
                    content
                }
            } else {
                Form { content }.formPaper().navigationTitle("OneRep").navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: ReadContext(day: Calendar.current.startOfDay(for: end), active: phase == .active, allowed: available && enabled && readsHealth)) {
            if !available || !enabled || !readsHealth {
                if !available || !enabled { request = nil; asking = false }
                reading = nil
                healthError = nil
                return
            }
            if phase == .active { await fetch(ask: false) }
        }
        .sheet(isPresented: $logging) {
            if available && enabled && store.canSync {
                OneRepWorkoutLog(date: date ?? .now) { workoutRevision += 1 }
            }
        }
        .alert("OneRep couldn’t open", isPresented: Binding(get: { launchProblem != nil }, set: { if !$0 { launchProblem = nil } })) {
            Button("Close", role: .cancel) {}
        } message: { Text(launchProblem ?? "") }
    }

    private struct ReadContext: Equatable {
        let day: Date
        let active: Bool
        let allowed: Bool
    }
    @ViewBuilder private var content: some View {
        if !available {
            Text("OneRep is unavailable in this workspace.").font(.subheadline)
        } else {
            if store.canSync {
                OneRepAccountSection(date: date ?? .now, linked: $linked, canLog: $canLog, revision: workoutRevision)
            }
            if !enabled {
                Button("Use OneRep app and Apple Health") {
                    store.change { journal in
                        var connections = journal.connections ?? ConnectionState()
                        connections.oneRep = true
                        journal.connections = connections
                    }
                }.frame(minHeight: 44)
            } else {
                sharedContent
            }
        }
    }

    @ViewBuilder private var sharedContent: some View {
        if let reading, readsHealth, Calendar.current.isDate(reading.day, inSameDayAs: end) {
            let stats = reading.stats
            Text("Shared through Apple Health").font(.headline)
            if let minutes = stats.workoutMinutes {
                Text("\(Int(minutes.rounded())) min").font(.title.monospacedDigit())
                Text("\(stats.workouts) \(stats.workouts == 1 ? "workout" : "workouts") · 7 days").font(.subheadline)
                let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0 - 6, to: Calendar.current.startOfDay(for: end)) }
                Chart(days, id: \.self) { day in
                    BarMark(x: .value("Day", day.formatted(.dateTime.weekday(.abbreviated))),
                            y: .value("Training minutes", stats.trainingByDay[day] ?? 0))
                        .foregroundStyle(embedded ? Color.trailAmber : Color.journalAccent)
                        .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(Int((stats.trainingByDay[day] ?? 0).rounded())) min")
                }.chartXAxis {
                    AxisMarks { AxisValueLabel().foregroundStyle(embedded ? Color.surface : Color.journalInk) }
                }.chartYAxis(.hidden).frame(height: 92).accessibilityLabel("OneRep training this week")
            }
            if let water = stats.waterML { LabeledContent("Water", value: "\(Int(water.rounded())) mL") }
            if let protein = stats.proteinGrams { LabeledContent("Protein", value: "\(Int(protein.rounded())) g") }
            if let mass = stats.weightKG {
                LabeledContent("Weight · \(mass.date.formatted(date: .abbreviated, time: .omitted))",
                               value: "\(mass.value.formatted(.number.precision(.fractionLength(0...1)))) kg")
            }
            if !stats.hasReadings { Text("No shared OneRep readings for this period.").font(.subheadline) }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { trainingActions }
            VStack(alignment: .leading, spacing: 0) { trainingActions }
        }
        if let healthError { Text(healthError).font(.footnote) }
        if readsHealth {
            Menu("Shared stats", systemImage: "heart.text.square") {
                Button("Refresh shared stats") { Task { await fetch(ask: true) } }
                Button("Stop showing stats", role: .destructive) {
                    readsHealth = false
                    request = nil
                    asking = false
                    reading = nil
                    healthError = nil
                }
            }.frame(minHeight: 44)
        } else {
            Button(asking ? "Reading…" : "Read shared health stats", systemImage: "heart.text.square") {
                Task { await fetch(ask: true) }
            }.disabled(asking).frame(minHeight: 44)
        }
    }

    @ViewBuilder private var trainingActions: some View {
        Button("Quick log", systemImage: "plus") {
            if linked && canLog && store.canSync { logging = true } else { open(.quickLog) }
        }.frame(minHeight: 44)
        Button("Ask coach", systemImage: "bubble.left") { open(.coach) }.frame(minHeight: 44)
        Menu {
            if linked && canLog { Button("Log in OneRep") { open(.quickLog) } }
            Button("View progress") { open(.progress) }
            Button("Workout library") { open(.workouts) }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("More OneRep actions")
    }

    private func open(_ action: OneRepDestination) {
        guard available, enabled else { return }
        let url = action.url(at: date ?? .now)
        openURL(url) { accepted in
            if !accepted {
                launchProblem = UIApplication.shared.canOpenURL(url)
                    ? "Try opening OneRep again when you’re ready." : "Install OneRep on this device, then try again."
            }
        }
    }

    @MainActor private func fetch(ask: Bool) async {
        guard available, enabled, readsHealth || ask else { return }
        let ticket = UUID(), instant = end
        request = ticket
        asking = true
        reading = nil
        healthError = nil
        defer { if request == ticket { asking = false } }
        do {
            let result = try await reader.read(requestAccess: ask, at: instant)
            guard request == ticket, !Task.isCancelled, available, enabled, Calendar.current.isDate(instant, inSameDayAs: end) else { return }
            readsHealth = true
            reading = Reading(day: instant, stats: result)
        } catch {
            if request == ticket, !Task.isCancelled {
                healthError = "Apple Health couldn’t open these readings. Check Health access in Settings."
            }
        }
    }
}

struct HealthConnectionsSection: View {
    let date: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OneRepScreen(embedded: true, date: date)
            Divider().overlay(Color.surface.opacity(0.24))
            ScreenTimeScreen(ending: date, embedded: true)
        }
    }
}
