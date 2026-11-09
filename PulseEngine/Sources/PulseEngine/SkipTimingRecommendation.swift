import Foundation

/// Surveys for the selected task or routine, already scoped to the reporting window.
struct SkipTimingProfile {
    private let lowEnergyMedian: Double?
    private let lowEnergyCount: Int
    private struct MissedHour {
        let hour: Int
        let example: Date
        let days: Int
    }
    private let missedHours: [MissedHour]
    private let outsideWindowReason: String?
    private let calendar: Calendar

    init(records: [TaskSkipRecord], calendar: Calendar) {
        self.calendar = calendar
        let low = records.filter { $0.reason == .lowEnergy }
        lowEnergyCount = low.count
        if Set(low.map { calendar.startOfDay(for: $0.skippedAt) }).count >= 2 {
            let values = low.map(\.energy).sorted()
            lowEnergyMedian = Double(values[(values.count - 1) / 2] + values[values.count / 2]) / 2
        } else {
            lowEnergyMedian = nil
        }

        let timing = records.filter { $0.reason == .interrupted || $0.reason == .notEnoughTime || $0.reason == .lowEnergy }
        let byHour = Dictionary(grouping: timing) { calendar.component(.hour, from: $0.scheduledStart) }
        missedHours = byHour.compactMap { hour, skips in
            let days = Set(skips.map { calendar.startOfDay(for: $0.scheduledStart) }).count
            guard days >= 2, let example = skips.first?.scheduledStart else { return nil }
            return MissedHour(hour: hour, example: example, days: days)
        }.sorted { $0.days == $1.days ? $0.hour < $1.hour : $0.days > $1.days }
        if let common = missedHours.first, let window = calendar.dateInterval(of: .hour, for: common.example) {
            var style = Date.FormatStyle.dateTime.hour().minute()
            style.timeZone = calendar.timeZone
            let range = window.start.formatted(style) + "–" + window.end.formatted(style)
            outsideWindowReason = "You skipped this task on \(common.days) days when it was scheduled for \(range). This start avoids that hour."
        } else {
            outsideWindowReason = nil
        }
    }

    var hasEvidence: Bool { lowEnergyMedian != nil || !missedHours.isEmpty }

    func assessment(for slot: TaskPlacement) -> SkipTimingAssessment {
        var assessment = SkipTimingAssessment()
        if let outsideWindowReason {
            let parts = calendar.dateComponents([.hour, .minute], from: slot.start)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            // Moving just across an hour boundary still lands near the repeatedly missed time.
            let outside = missedHours.allSatisfy { window in
                let fromMidpoint = abs(minute - (window.hour * 60 + 30))
                return min(fromMidpoint, 1440 - fromMidpoint) >= 90
            }
            if outside {
                assessment.timeReason = outsideWindowReason
            } else {
                assessment.timePenalty = 2
            }
        }
        if let median = lowEnergyMedian {
            switch slot.energyBasis {
            case .hour, .day, .expected, .correction:
                if slot.rankingCapacity >= median + 1 {
                    assessment.energyReason = "Estimated energy is \(rating(slot.rankingCapacity))/10 here. You reported a median of \(rating(median))/10 across \(lowEnergyCount) skips due to low energy."
                } else {
                    assessment.energyPenalty = 2
                    assessment.hasLowEstimate = true
                }
            case .manual, .capacity:
                // A generic capacity or workload setting cannot establish an energy improvement.
                assessment.energyPenalty = 2
            }
        }
        return assessment
    }

    private func rating(_ score: Double) -> String {
        score.formatted(.number.precision(.fractionLength(0...1)))
    }
}

struct SkipTimingAssessment: Equatable, Sendable {
    var timePenalty = 0
    var energyPenalty = 0
    var timeReason: String?
    var energyReason: String?
    var hasLowEstimate = false

    var penalty: Double { Double(timePenalty + energyPenalty) }

    func improvement(over baseline: Self?) -> String? {
        guard let baseline else { return energyReason ?? timeReason }
        guard penalty < baseline.penalty else { return nil }
        if baseline.hasLowEstimate, energyPenalty < baseline.energyPenalty, let energyReason { return energyReason }
        if timePenalty < baseline.timePenalty { return timeReason }
        return nil
    }
}

public struct SkipTimingRecommendation: Equatable, Sendable {
    public let placement: TaskPlacement
    public let reason: String

    public static func hasTimingEvidence(in records: [TaskSkipRecord], calendar: Calendar = .current) -> Bool {
        SkipTimingProfile(records: records, calendar: calendar).hasEvidence
    }

    /// Uses the planner's highest-ranked feasible option. A pinned or projected start
    /// needs a comparable baseline; unplaced tasks can use the past reports directly.
    public static func find(in options: [TaskPlacement], current: TaskPlacement? = nil, for task: PlanTask) -> Self? {
        guard let best = options.first(where: \.recommended) else { return nil }
        let currentStart = current?.start ?? best.originalStart
        let baseline = current ?? options.first { $0.start == currentStart }
        guard best.start != currentStart, currentStart == nil || baseline != nil,
              let reason = best.skipTiming.improvement(over: baseline?.skipTiming) else { return nil }
        if let baseline, !best.isPreferred(to: baseline, for: task) { return nil }
        return Self(placement: best, reason: reason)
    }
}
