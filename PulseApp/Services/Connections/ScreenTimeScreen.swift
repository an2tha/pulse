import DeviceActivity
@preconcurrency import FamilyControls
import SwiftUI

struct ScreenTimeScreen: View {
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    private let ending: Date?
    private let embedded: Bool
    @State private var week: Bool
    @State private var busy = false
    @State private var message: String?

    init(ending: Date? = nil, initialWeek: Bool = true, embedded: Bool = false) {
        self.ending = ending
        self.embedded = embedded
        _week = State(initialValue: initialWeek)
    }

    private var approved: Bool {
        if #available(iOS 26.4, *), authorization.authorizationStatus == .approvedWithDataAccess { return true }
        return authorization.authorizationStatus == .approved
    }
    private var available: Bool { !store.isDemo && !privacy.lockConnections && !store.restoring }
    private var day: Date { Calendar.current.startOfDay(for: min(ending ?? .now, .now)) }

    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Screen Time").font(.title2).accessibilityAddTraits(.isHeader).accessibilityIdentifier("health-screen-time-heading")
                    content
                }
            } else {
                Form { content }.formPaper().navigationTitle("Screen Time").navigationBarTitleDisplayMode(.inline)
            }
        }
        .onChange(of: phase) { _, phase in if phase == .active && approved { message = nil } }
    }

    @ViewBuilder private var content: some View {
        if !available {
            Text("Screen Time is private in this workspace.").font(.subheadline)
        } else if approved {
            Picker("Screen Time period", selection: $week) {
                Text(Calendar.current.isDateInToday(day) ? "Today" : "Day").tag(false)
                Text("7 days").tag(true)
            }.pickerStyle(.segmented).environment(\.colorScheme, embedded ? .dark : scheme)
            let calendar = Calendar.current
            let start = week ? calendar.date(byAdding: .day, value: -6, to: day) ?? day : day
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? .now
            DeviceActivityReport(.init("Pulse daily use"), filter: .init(segment: .daily(during: .init(start: start, end: end))))
                .frame(minHeight: week ? 228 : 100)
                .environment(\.colorScheme, embedded ? .dark : scheme)
            if !embedded {
                Text("If the report is empty, turn on App & Website Activity in iPhone Settings.").font(.footnote)
                Button("Disconnect Screen Time", role: .destructive) { disconnect() }
            } else {
                Menu("Screen Time access", systemImage: "lock") {
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    Button("Disconnect Screen Time", role: .destructive) { disconnect() }
                }.frame(minHeight: 44)
            }
        } else {
            Text("See daily screen time and pickups from Apple’s private report.").font(.subheadline)
            Button(busy ? "Connecting…" : "Connect Screen Time", systemImage: "hourglass") {
                guard available, !busy else { return }
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await authorization.requestAuthorization(for: .individual) }
                    catch { message = "Screen Time access wasn’t granted. Check Screen Time in Settings and try again." }
                }
            }.disabled(busy).frame(minHeight: 44)
            if authorization.authorizationStatus == .denied {
                Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }.frame(minHeight: 44)
            }
        }
        if let message { Text(message).font(.footnote) }
    }
    @Environment(\.colorScheme) private var scheme

    private func disconnect() {
        guard available else { return }
        authorization.revokeAuthorization { result in
            if case .failure = result { Task { @MainActor in message = "Screen Time couldn’t disconnect. Try again in Settings." } }
        }
    }
}
