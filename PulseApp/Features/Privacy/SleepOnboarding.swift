import SwiftUI
import PulseEngine

extension Workspace {
    var sleepHistory: SleepHistory {
        SleepHistory(nights: healthController.nights, at: .now, target: journal.sleepTarget)
    }
}

private func duration(_ hours: Double) -> String {
    let minutes = Int((hours * 60).rounded())
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}

struct SleepOnboarding: View {
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    let finish: () -> Void
    private var history: SleepHistory { store.sleepHistory }
    private let titles = ["Your nights in Pulse", "Your nightly sleep need", "Your sleep debt", "Today’s energy"]
    private var caption: String {
        switch page {
        case 0: return "Use the last four weeks of recorded sleep to find a starting target and estimate your energy today."
        case 1:
            if store.journal.sleepTarget != nil { return "Your chosen target applies to each recorded night. Adjust it to match how much sleep leaves you rested." }
            if history.nights.isEmpty { return "Eight hours is the starting target. Adjust it to match how much sleep leaves you rested." }
            return "Based on \(history.nights.count) recorded nights. Longer nights help set your target as more sleep history arrives."
        case 2: return "Over the last 14 days, shorter nights add to your balance and longer nights reduce it. Missing nights are left out."
        default: return "This rough sleep-based estimate uses your latest sleep, recent debt and time awake. Check in on Today to record how you actually feel."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sleep & energy").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            HStack(spacing: 5) {
                ForEach(0..<4) { index in Capsule().fill(index <= page ? Color.trailAmber : Color.white.opacity(0.2)).frame(height: 3) }
            }.accessibilityLabel("Step \(page + 1) of 4")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if page == 1 {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Nightly target", systemImage: "moon.stars").font(.subheadline)
                            Text(metric).font(.system(.largeTitle, design: .rounded, weight: .medium)).monospacedDigit()
                            GeometryReader { bounds in
                                let fraction = (history.need - 4) / 8
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.surface.opacity(0.18))
                                    Capsule().fill(Color.trailAmber)
                                        .frame(width: max(8, bounds.size.width * fraction))
                                }
                            }.frame(height: 10)
                            HStack { Text("4h"); Spacer(); Text("12h") }.font(.caption)
                        }.padding(.vertical, 30)
                    } else {
                    ZStack {
                        Circle().strokeBorder(Color.trailAmber.opacity(0.28), lineWidth: 1)
                        Circle().fill(Color.trailAmber.opacity(0.10)).padding(10)
                        VStack(spacing: 8) {
                            Image(systemName: ["moon.stars", "bed.double", "moon.zzz", "sun.horizon"][page])
                                .font(.title).foregroundStyle(Color.trailAmber)
                            Text(metric).font(.system(.largeTitle, design: .rounded, weight: .medium))
                                .monospacedDigit().multilineTextAlignment(.center)
                            Text(unit).font(.subheadline)
                        }.padding(20)
                    }.frame(maxWidth: 240).aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    Text(titles[page]).font(.largeTitle.weight(.medium)).accessibilityAddTraits(.isHeader)
                    Text(caption).fixedSize(horizontal: false, vertical: true)
                    if page == 0 {
                        if privacy.lockConnections {
                            Text("Connections are locked in Privacy settings. You can still choose a sleep target.").font(.callout)
                        } else {
                            Button {
                                Task {
                                    privacy.sleepConnected = true
                                    await store.healthController.refreshSleep(requestPermission: true)
                                }
                            } label: {
                                Label(store.healthController.readingSleep ? "Reading sleep…" : "Read sleep from Apple Health", systemImage: "heart")
                            }.disabled(store.healthController.readingSleep)
                            if store.healthController.sleepError { Text("Sleep could not be loaded. Try again.").font(.callout) }
                            else if privacy.sleepConnected && history.nights.isEmpty && !store.healthController.readingSleep {
                                Text("No nights available. Check sleep access and recordings in Apple Health.").font(.callout)
                            }
                        }
                    }
                    if page == 1 {
                        Stepper("Target · " + duration(history.need), value: Binding(get: { history.need }, set: { value in
                            store.change { $0.sleepTarget = value }
                        }), in: 4...12, step: 0.25)
                        if store.journal.sleepTarget != nil {
                            Button("Use suggested target") { store.change { $0.sleepTarget = nil } }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                SceneButton(title: page == 3 ? "Open Today" : "Continue", icon: "arrow.right") {
                    if page == 3 {
                        privacy.sleepSetupFinished = true
                        dismiss()
                        finish()
                    } else { page += 1 }
                }
            }
        }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            .foregroundStyle(Color.surface).tint(.trailAmber).background(store.sky.ground.ignoresSafeArea())
    }

    private var metric: String {
        switch page {
        case 0: return "\(history.nights.count)"
        case 1: return duration(history.need)
        case 2: return history.debt.map(duration) ?? "Pending"
        default: return history.energy.map { "\(Int($0.rounded())) / 10" } ?? "Pending"
        }
    }
    private var unit: String {
        switch page {
        case 0: return "recorded nights"
        case 1: return "per night"
        case 2: return "\(history.recentCount) nights recorded"
        default: return history.energy == nil ? "Needs today’s sleep" : "estimated energy"
        }
    }
}
