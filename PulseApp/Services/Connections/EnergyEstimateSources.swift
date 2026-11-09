import PulseEngine
import SwiftUI

struct EnergyEstimateSources: View {
    let basis: EnergyModelBasis
    let openDay: (Date) -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Estimated energy", value: score(basis.score))
                if case let .recovery(values) = basis.method { readings(values) }
            } footer: {
                Text(explanation)
            }
            Section {
                ForEach(orderedDays) { day in
                    Button { openDay(day.date) } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                dayLabel(day)
                                if let prior = day.readings, case let .recovery(current) = basis.method {
                                    Text(sharedValues(prior, with: current)).font(.caption)
                                        .foregroundStyle(Color.moss).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.moss)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityHint("View this day in Health")
                }
            }
        }
        .formPaper().foregroundStyle(Color.journalInk).tint(.journalAccent)
        .navigationTitle("Estimate sources").navigationBarTitleDisplayMode(.inline)
    }

    private var orderedDays: [EnergyModelBasis.Day] {
        if case .recovery = basis.method { return basis.days }
        return basis.days.sorted { $0.date > $1.date }
    }

    private var explanation: String {
        switch basis.method {
        case .recovery:
            return "Each day contributes ratings logged with similar readings. Pulse uses the median of those daily ratings."
        case let .forecast(weekday, hourly):
            let days = weekday ? "Only matching weekdays are included." : "All weekdays with readings are included."
            let hours = hourly ? "hours within one hour of this time" : "recorded hours"
            return "Each day contributes one average from its " + hours + ". The forecast uses the median of those daily ratings. " + days
        }
    }

    private func dayLabel(_ day: EnergyModelBasis.Day) -> some View {
        LabeledContent(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                       value: score(day.rating))
    }

    private func sharedValues(_ prior: RecoveryReadings, with current: RecoveryReadings) -> String {
        var values: [String] = []
        if current.restingPulse != nil, let bpm = prior.restingPulse { values.append(number(bpm) + " bpm resting") }
        if current.variability != nil, let ms = prior.variability { values.append(number(ms) + " ms HRV") }
        if current.sleepHours != nil, let hours = prior.sleepHours { values.append(number(hours) + " h sleep") }
        return values.joined(separator: " · ")
    }

    @ViewBuilder private func readings(_ values: RecoveryReadings) -> some View {
        if let pulse = values.restingPulse { LabeledContent("Resting heart rate", value: number(pulse) + " bpm") }
        if let variability = values.variability { LabeledContent("Heart rate variability", value: number(variability) + " ms") }
        if let hours = values.sleepHours { LabeledContent("Sleep", value: number(hours) + " h") }
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    private func score(_ value: Double) -> String { number(value) + "/10" }
}
