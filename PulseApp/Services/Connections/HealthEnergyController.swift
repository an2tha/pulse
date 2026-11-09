import Foundation
import HealthKit
import Observation
import PulseEngine

struct HealthPulsePoint: Identifiable, Sendable {
    let date: Date
    let bpm: Double
    var id: Date { date }
}

struct HealthEnergyDay: Identifiable, Sendable {
    let date: Date
    var pulse: Double?
    var pulseTime: Date?
    var resting: Double?
    var variability: Double?
    var sleepHours: Double?
    var steps: Int?
    var id: Date { date }
}

private struct HealthEnergySnapshot: Sendable {
    var days: [HealthEnergyDay]
    var nights: [SleepNight]
    var heartRates: [HealthPulsePoint]
    var signals: [EnergySignal]
}

private actor HealthEnergyReader {
    func sleepNights(requestPermission: Bool) async throws -> [SleepNight] {
        guard HKHealthStore.isHealthDataAvailable() else { throw ConnectionError.unavailable }
        let store = HKHealthStore()
        let type = HKCategoryType(.sleepAnalysis)
        if requestPermission { try await store.requestAuthorization(toShare: [], read: [type]) }
        let now = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -29, to: now)!
        let range = HKQuery.predicateForSamples(withStart: start, end: now, options: [.strictEndDate])
        let samples = try await HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: range)],
                                                         sortDescriptors: []).result(for: store)
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        return SleepNight.collect(samples.filter { asleep.contains($0.value) }.map { DateInterval(start: $0.startDate, end: $0.endDate) })
    }

    func read(requestPermission: Bool) async throws -> HealthEnergySnapshot? {
        guard HKHealthStore.isHealthDataAvailable() else { throw ConnectionError.unavailable }
        let store = HKHealthStore()
        let heart = HKQuantityType(.heartRate)
        let resting = HKQuantityType(.restingHeartRate)
        let hrv = HKQuantityType(.heartRateVariabilitySDNN)
        let steps = HKQuantityType(.stepCount)
        let sleep = HKCategoryType(.sleepAnalysis)
        let types: Set<HKObjectType> = [heart, resting, hrv, steps, sleep]
        if requestPermission {
            try await store.requestAuthorization(toShare: [], read: types)
        } else {
            // This status only reports whether Apple would show a prompt. A read may still return no data.
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: types)
            guard status == .unnecessary else { return nil }
        }
        try Task.checkCancellation()

        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -27, to: today)!
        let range = HKQuery.predicateForSamples(withStart: start, end: now, options: [.strictStartDate, .strictEndDate])
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var daily: [Date: HealthEnergyDay] = [:]
        for offset in 0..<28 {
            if let date = calendar.date(byAdding: .day, value: offset, to: start) {
                daily[date] = HealthEnergyDay(date: date)
            }
        }

        // HealthKit aggregates dense workout readings before handing them to the app.
        let pulse = try await HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: heart, predicate: range),
            options: [.discreteAverage, .mostRecent], anchorDate: start,
            intervalComponents: DateComponents(hour: 1)
        ).result(for: store)
        var points: [HealthPulsePoint] = []
        for bucket in pulse.statistics() {
            guard let interval = bucket.mostRecentQuantityDateInterval(), interval.end <= now,
                  let mean = bucket.averageQuantity()?.doubleValue(for: bpm), mean.isFinite, mean > 0
            else { continue }
            let day = calendar.startOfDay(for: interval.end)
            points.append(.init(date: bucket.startDate, bpm: mean))
            if let latest = bucket.mostRecentQuantity()?.doubleValue(for: bpm),
               latest.isFinite, latest > 0, (daily[day]?.pulseTime ?? .distantPast) <= interval.end {
                daily[day]?.pulse = latest
                daily[day]?.pulseTime = interval.end
            }
        }

        var signals: [EnergySignal] = []
        for type in [resting, hrv] {
            try Task.checkCancellation()
            let isResting = type == resting
            let unit = isResting ? bpm : HKUnit.secondUnit(with: .milli)
            // The earliest visible Health day still needs its preceding HRV baseline.
            let baselineStart = calendar.date(byAdding: .day, value: -28, to: start) ?? start
            let measurementRange = isResting ? range : HKQuery.predicateForSamples(
                withStart: baselineStart, end: now, options: [.strictStartDate, .strictEndDate])
            let samples = try await HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: measurementRange)],
                sortDescriptors: [SortDescriptor(\.endDate)]
            ).result(for: store)
            for sample in samples {
                let value = sample.quantity.doubleValue(for: unit)
                guard value.isFinite, value > 0 else { continue }
                let day = calendar.startOfDay(for: sample.endDate)
                if isResting {
                    daily[day]?.resting = value
                    signals.append(EnergySignal(date: sample.endDate, restingPulse: value))
                } else {
                    daily[day]?.variability = value
                    signals.append(EnergySignal(date: sample.endDate, variability: value))
                }
            }
        }
        try Task.checkCancellation()
        let totals = try await HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: steps, predicate: range), options: .cumulativeSum,
            anchorDate: start, intervalComponents: DateComponents(day: 1)
        ).result(for: store)
        for bucket in totals.statistics() {
            if let sum = bucket.sumQuantity()?.doubleValue(for: .count()), sum.isFinite,
               sum >= 0, sum < Double(Int.max) {
                daily[calendar.startOfDay(for: bucket.startDate)]?.steps = Int(sum)
            }
        }
        try Task.checkCancellation()
        let nights = try await sleepNights(requestPermission: false)
        for night in nights {
            let day = calendar.startOfDay(for: night.wake)
            daily[day]?.sleepHours = night.hours
            signals.append(EnergySignal(date: night.wake, sleepHours: night.hours))
        }
        return HealthEnergySnapshot(days: daily.values.sorted { $0.date > $1.date }, nights: nights,
                                    heartRates: points.sorted { $0.date < $1.date },
                                    signals: signals.sorted { $0.date < $1.date })
    }
}

/// Health observations are ephemeral and scoped to one workspace.
@MainActor @Observable
final class HealthEnergyController {
    private(set) var days: [HealthEnergyDay] = []
    private(set) var heartRates: [HealthPulsePoint] = []
    private(set) var signals: [EnergySignal] = []
    private(set) var loading = false
    private(set) var failure: String?
    private(set) var refreshedAt: Date?
    private(set) var revision = 0
    private let reader = HealthEnergyReader()
    @ObservationIgnored private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var requesting = false

    private static let pausedKey = "pausePassiveHealthReads"

    func refresh(requestPermission: Bool = false, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        guard !PrivacySession.connectionsLocked else { clear(); return }
        if requestPermission {
            PrivacySession.preferences.removeObject(forKey: Self.pausedKey)
        } else if PrivacySession.preferences.bool(forKey: Self.pausedKey) {
            return
        }
        if let worker, !requestPermission || requesting {
            await worker.value
            return
        }
        if !force, !requestPermission, let refreshedAt,
           Calendar.current.isDateInToday(refreshedAt),
           (0..<900).contains(Date.now.timeIntervalSince(refreshedAt)) { return }
        worker?.cancel()
        let token = UUID()
        generation = token
        requesting = requestPermission
        loading = true
        failure = nil
        let task = Task {
            defer {
                if generation == token {
                    loading = false
                    requesting = false
                    worker = nil
                }
            }
            do {
                guard let fresh = try await reader.read(requestPermission: requestPermission) else { return }
                guard generation == token, !Task.isCancelled else { return }
                guard !PrivacySession.connectionsLocked else { clear(); return }
                nights = fresh.nights
                lastSleepRead = .now
                sleepError = false
                days = fresh.days
                heartRates = fresh.heartRates
                signals = fresh.signals
                refreshedAt = .now
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                days = []
                heartRates = []
                signals = []
                refreshedAt = nil
                failure = "Health readings couldn’t be loaded. Check access in Health and try again."
            }
            revision += 1
        }
        worker = task
        await task.value
    }

    private(set) var nights: [SleepNight] = []
    private(set) var readingSleep = false
    private(set) var sleepError = false
    private var sleepRead = UUID()
    private var lastSleepRead: Date?

    func refreshSleep(requestPermission: Bool = false) async {
        guard !PrivacySession.connectionsLocked, !readingSleep else { return }
        if !requestPermission, let lastSleepRead, Date.now.timeIntervalSince(lastSleepRead) < 900 { return }
        let token = UUID()
        sleepRead = token
        readingSleep = true
        defer { if token == sleepRead { readingSleep = false } }
        do {
            let result = try await reader.sleepNights(requestPermission: requestPermission)
            guard token == sleepRead, !PrivacySession.connectionsLocked else { return }
            nights = result
            lastSleepRead = .now
            sleepError = false
        } catch {
            guard token == sleepRead else { return }
            sleepError = true
            nights = []
        }
        revision += 1
    }

    func clear(pausePassiveReads: Bool = true) {
        sleepRead = UUID()
        lastSleepRead = nil
        readingSleep = false
        sleepError = false
        nights = []
        if pausePassiveReads { PrivacySession.preferences.set(true, forKey: Self.pausedKey) }
        generation = UUID()
        worker?.cancel()
        worker = nil
        requesting = false
        loading = false
        days = []
        heartRates = []
        signals = []
        failure = nil
        refreshedAt = nil
        revision += 1
    }
}
