import SwiftUI
import PulseEngine

struct HealthHRVSection: View {
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    let date: Date
    @State private var checkingIn = false
    @State private var logging: EnergyActivity?
    @State private var chartDay: Date?
    @State private var showingMethod = false

    private var locked: Bool { store.isDemo || privacy.lockConnections }
    private var controller: HealthEnergyController { store.healthController }

    var body: some View {
        let end = min(date, .now)
        let signals = locked ? [] : controller.signals
        let score = PersonalHRV(signals: signals, at: end)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Heart rate variability").font(.title2)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("health-hrv-heading")
                Spacer()
                Button { showingMethod = true } label: {
                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                }.accessibilityLabel("How the HRV score works")
            }
            if let current = score.current, let last = score.lastReading {
                if let rank = score.percentile {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(rank)").font(.system(.largeTitle, design: .rounded).weight(.light)).monospacedDigit()
                            .foregroundStyle(Color.trailAmber)
                        Text("HRV percentile").font(.subheadline)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("Personal HRV percentile, \(rank) out of 100")
                    Text("\(amount(current)) ms · Personal median \(amount(score.baseline ?? current)) ms")
                        .font(.subheadline)
                } else {
                    Text("\(amount(current)) ms").font(.title.monospacedDigit())
                    Text("\(score.days) of \(PersonalHRV.minimumDays) comparable days for your score")
                        .font(.subheadline)
                }
                let points = score.dailyMedians.map { HealthTracePoint($0.date, $0.median) }
                let low = points.map(\.value).min() ?? current
                let high = points.map(\.value).max() ?? current
                let day = Calendar.current.startOfDay(for: last)
                let start = Calendar.current.date(byAdding: .day, value: -28, to: day) ?? day
                let finish = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? last
                HealthTrace(title: "Personal HRV history", points: points, interval: DateInterval(start: start, end: finish),
                            range: max(0, floor(low - 5))...ceil(high + 5), maximumGap: 90000, tint: .trailAmber,
                            daily: true, unit: "ms", inspected: $chartDay)
                    .frame(height: 115)
                if let chartDay, let point = points.min(by: { abs($0.date.timeIntervalSince(chartDay)) < abs($1.date.timeIntervalSince(chartDay)) }) {
                    Text("\(point.date.formatted(date: .abbreviated, time: .omitted)) · \(amount(point.value)) ms").font(.caption)
                } else {
                    Text("Latest reading · \(last.formatted(date: .omitted, time: .shortened))").font(.caption)
                }
                if Calendar.current.isDateInToday(date), let rank = score.percentile {
                    Text(rank < 25 ? "Below your usual range. Check how you feel before choosing a demanding task."
                         : "Use a check-in alongside this reading to set today’s workload.")
                        .font(.subheadline).foregroundStyle(Color.surface.opacity(0.78))
                    Button("Check in", systemImage: "slider.horizontal.3") { checkingIn = true }
                        .frame(minHeight: 44)
                }
                if Calendar.current.isDateInToday(date), let activity = store.rankedBoosts(through: end).first?.activity {
                    Button {
                        logging = activity
                    } label: {
                        Label("Log \(activity.title)", systemImage: "leaf")
                    }.frame(minHeight: 44)
                    Text("Your best-rated energy boost · \(activity.minutes) min")
                        .font(.caption).foregroundStyle(Color.surface.opacity(0.78))
                }
            } else {
                Text(locked ? "Apple Health readings are private in this workspace." : "No HRV readings for this day.")
                    .font(.subheadline).foregroundStyle(Color.surface.opacity(0.78))
                if !locked {
                    Button(controller.loading ? "Reading…" : "Read Apple Health", systemImage: "heart") {
                        Task { await controller.refresh(requestPermission: true, force: true) }
                    }.disabled(controller.loading).frame(minHeight: 44)
                }
            }
        }
        .onChange(of: Calendar.current.startOfDay(for: date)) { chartDay = nil }
        .sheet(item: $logging) { activity in NavigationStack { EnergyActivityLogEditor(activity: activity) } }
        .sheet(isPresented: $checkingIn) { CheckInScreen() }
        .alert("Your HRV percentile", isPresented: $showingMethod) {
            Button("Done", role: .cancel) {}
            Link("Apple Health measurement", destination: URL(string: "https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn")!)
        } message: {
            Text("Pulse compares your median HRV (SDNN) with readings from the same six-hour period over the past 28 days. A score of 50 is your usual level. Scoring starts after seven comparable days.")
        }
    }

    private func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
