import Foundation

/// A scheduling prior inspired by the circadian and homeostatic processes in Daan,
/// Beersma & Borbély (1984), doi:10.1152/ajpregu.1984.246.2.R161.
/// The conversion to Pulse's subjective 0...10 scale is a product heuristic.
struct ScheduleEnergyRhythm {
    let window: PlannedSleepWindow
    let calendar: Calendar

    func score(at date: Date) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let localHours = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
            + Double(components.second ?? 0) / 3600
        let phase = (localHours - Double(window.wake) / 60 + 24).truncatingRemainder(dividingBy: 24)
        let sleepHours = min(23.75, max(0.25, Double(window.minutes) / 60))
        let wakingHours = 24 - sleepHours

        // Periodic steady state of exponential accumulation and dissipation.
        let wakeDecay = exp(-wakingHours / 18.2)
        let sleepDecay = exp(-sleepHours / 4.2)
        let bedtimePressure = (1 - wakeDecay) / (1 - wakeDecay * sleepDecay)
        let wakingPressure = bedtimePressure * sleepDecay
        let pressure = phase < wakingHours
            ? 1 - (1 - wakingPressure) * exp(-phase / 18.2)
            : bedtimePressure * exp(-(phase - wakingHours) / 4.2)

        let circadian = -cos(2 * .pi * (phase + 2) / 24)
        let middayDip = exp(-0.5 * pow((phase - 7.5) / 1.8, 2))
        let distanceToWake = min(phase, 24 - phase)
        let inertia = exp(-distanceToWake / 0.6)
        // During the planned sleep opportunity, taper alertness toward mid-sleep.
        // The taper meets the waking curve continuously at both edges.
        let nightPhase = max(0, phase - wakingHours) / sleepHours
        let sleepTaper = 1.8 * pow(sin(.pi * nightPhase), 2)
        let score = 7.4 + 2.6 * circadian - sleepTaper - 4.8 * pressure - 1.5 * middayDip - 1.0 * inertia
        return min(10, max(0, score))
    }
}
