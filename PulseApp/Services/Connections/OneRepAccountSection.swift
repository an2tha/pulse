import SwiftUI

struct OneRepAccountSection: View {
    let date: Date
    @Binding var linked: Bool
    @Binding var canLog: Bool
    let revision: Int
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.scenePhase) private var phase
    @State private var summary: OneRepDaySummary?
    @State private var loadedDay: Date?
    @State private var message: String?
    @State private var signIn: Task<Void, Never>?
    @State private var signInMessage: String?
    @State private var refresh = 0
    @State private var loading = false

    private var day: Date { Calendar.current.startOfDay(for: date) }
    private var allowed: Bool {
        store.canSync && !privacy.lockConnections && !store.restoring
    }
    private var enabled: Bool { store.journal.connections?.oneRep == true }
    private struct Context: Equatable {
        var day: Date
        var allowed: Bool
        var active: Bool
        var refresh: Int
        var revision: Int
        var epoch: UUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if linked && allowed && enabled {
                HStack {
                    Text(date.formatted(.dateTime.month().day())).font(.headline)
                    Spacer()
                    Menu {
                        Button("Refresh readings") { refresh += 1 }
                        Button("Sign in again") { connect() }.disabled(signIn != nil)
                        Button("Disconnect account", role: .destructive) { disconnect() }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                    }.accessibilityLabel("OneRep account options")
                }
                if loading { ProgressView("Reading OneRep") }
                if let summary, loadedDay == day {
                    Text(summary.workoutCount == 1 ? "1 workout" : "\(summary.workoutCount) workouts")
                        .font(.title2.weight(.medium))
                    if summary.trainingMinutes > 0 { metric("Training", summary.trainingMinutes, "min") }
                    if summary.restDay { Text("Planned rest day") }
                    if let water = summary.waterML { metric("Water", water, "mL") }
                    if let protein = summary.proteinGrams { metric("Protein", protein, "g") }
                    if let steps = summary.steps { metric("Steps", steps, "") }
                    if let minutes = summary.sleepMinutes { metric("Sleep", minutes, "min") }
                    if let rate = summary.restingHeartRateBPM { metric("Resting heart rate", rate, "bpm") }
                    if let hrv = summary.hrvMS { metric("Heart rate variability", hrv, "ms") }
                    if let energy = summary.activeEnergyKcal { metric("Active energy", energy, "kcal") }
                }
            } else if allowed {
                Button(signIn == nil ? "Connect OneRep" : "Signing in…", systemImage: "link") { connect() }
                    .disabled(signIn != nil).frame(minHeight: 44)
            }
            if let message = signInMessage ?? message { Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true) }
        }
        .task(id: Context(day: day, allowed: allowed && enabled, active: phase == .active, refresh: refresh, revision: revision, epoch: store.journalEpoch)) {
            await read()
        }
        .onDisappear { signIn?.cancel() }
        .onChange(of: allowed) { _, allowed in if !allowed { signIn?.cancel() } }
    }

    private func connect() {
        guard allowed, signIn == nil else { return }
        let epoch = store.journalEpoch
        let connection = OneRepCredentials.connectionID
        signInMessage = nil
        signIn = Task { @MainActor in
            defer { signIn = nil }
            do {
                await OneRepCredentials.awaitPendingRevocation()
                try Task.checkCancellation()
                let grant = try await OneRepSignIn.authorize()
                guard !Task.isCancelled, allowed, store.journalEpoch == epoch,
                      OneRepCredentials.connectionID == connection else {
                    OneRepCredentials.discard(grant)
                    return
                }
                do { try OneRepCredentials.saveGrant(grant) }
                catch { OneRepCredentials.discard(grant); throw error }
                store.change { journal in
                    var connections = journal.connections ?? ConnectionState()
                    connections.oneRep = true
                    journal.connections = connections
                }
                linked = true
                refresh += 1
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { signInMessage = error.localizedDescription }
            }
        }
    }

    private func metric(_ name: String, _ value: Double, _ unit: String) -> some View {
        LabeledContent(name, value: value.formatted(.number.precision(.fractionLength(0...1))) + (unit.isEmpty ? "" : " " + unit))
    }

    @MainActor private func read() async {
        summary = nil
        canLog = false
        message = nil
        loading = false
        guard allowed, enabled, phase == .active else { return }
        do {
            let connection = OneRepCredentials.connectionID
            guard try OneRepCredentials.load() != nil else { linked = false; return }
            linked = true
            guard let key = try await OneRepCredentials.validToken() else { linked = false; return }
            try Task.checkCancellation()
            guard allowed, enabled, connection == OneRepCredentials.connectionID else { return }
            let requestedDay = day
            loading = true
            let access = try await OneRepAPI().permissions(token: key)
            try Task.checkCancellation()
            guard allowed, enabled, connection == OneRepCredentials.connectionID else { return }
            canLog = access.contains("write")
            let result = try await OneRepAPI().readDay(requestedDay, token: key)
            try Task.checkCancellation()
            guard allowed, enabled, day == requestedDay, connection == OneRepCredentials.connectionID else { return }
            summary = result
            loadedDay = requestedDay
        } catch {
            guard !Task.isCancelled, allowed else { return }
            if (try? OneRepCredentials.load()) == nil { linked = false }
            message = error.localizedDescription
        }
        loading = false
    }

    private func disconnect() {
        do {
            signIn?.cancel()
            signInMessage = nil
            try OneRepCredentials.delete()
            linked = false
            summary = nil
            refresh += 1
        } catch { message = error.localizedDescription }
    }
}

extension OneRepAPI {
    func permissions(token: String) async throws -> Set<String> {
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else {
            throw OneRepAPIError.unauthorized
        }
        struct Access: Decodable { let scopes: Set<String> }
        let request = URLRequest(url: Self.origin.appending(path: "v1/me"))
        let data = try await send(request, token: token)
        guard let result = try? JSONDecoder().decode(Access.self, from: data) else { throw OneRepAPIError.invalidResponse }
        return result.scopes
    }
}
