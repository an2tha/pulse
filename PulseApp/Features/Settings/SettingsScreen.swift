import SwiftUI

struct SettingsScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.dismiss) private var dismiss
    @State private var walkthrough = false
    @State private var deleting = false
    @State private var deleteError = false

    var body: some View {
        Form {
            Section("Daily plan") {
                Stepper("\(store.journal.limit) minute workload limit", value: setting(\.limit), in: 0...480, step: 5)
                Toggle("Include breathing room", isOn: setting(\.breaks))
                Toggle(
                    "Rest for today",
                    isOn: Binding(
                        get: { store.isRestDay }, set: { value in store.change { $0.restDate = value ? .now : nil } }))
                NavigationLink("Planning preferences") { PlanPreferencesScreen() }
            }
            if !store.isDemo {
                Button("Reset onboarding", systemImage: "arrow.counterclockwise") {
                    dismiss()
                    privacy.sleepSetupFinished = false
                    privacy.welcomed = false
                }
            }
            Button("Replay walkthrough", systemImage: "book.pages") { walkthrough = true }
                .accessibilityIdentifier("replay-pulse-walkthrough")
            Section {
                Toggle("Require photos for selected tasks", isOn: Binding(
                    get: { store.journal.photoProofEnabled != false },
                    set: { value in store.change { $0.photoProofEnabled = value } }))
                    .accessibilityIdentifier("settings-photo-proof")
                NavigationLink("Picture log") { PictureLogScreen() }
            } footer: {
                Text("Choose which tasks need a completion photo in their task editor.")
            }
            Section("Landscape") {
                NavigationLink {
                    LandscapeThemeScreen()
                } label: {
                    LabeledContent("Theme pack", value: store.landscapeTheme.title)
                }
                .accessibilityIdentifier("settings-landscape-theme")
                Picker("Atmosphere", selection: setting(\.atmosphere)) {
                    Text("Follow local time").tag(Optional<String>.none)
                    ForEach(Atmosphere.allCases) { Text($0.rawValue).tag(Optional($0.rawValue)) }
                }
            }
            if !store.isDemo {
                Section("Connections") {
                    if !privacy.lockConnections {
                        NavigationLink("Calendar, health & assistant") { ConnectionsScreen() }
                    }
                    NavigationLink("Reminders & widgets") { ReminderPreferencesView() }
                    if !privacy.lockConnections { NavigationLink("Private sync") { PrivateSyncScreen() } }
                }
                Section("Your journal") {
                    NavigationLink("Journal files") { JournalFilesScreen() }
                    NavigationLink("Privacy & feedback") { PrivacyOptionsScreen() }
                    if ReleaseFeatures.demo {
                        Button("Explore a demo") {
                            dismiss()
                            privacy.demo = true
                        }
                    }
                    Button("Delete all local data", role: .destructive) { deleting = true }
                }
            }
        }.formPaper().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $walkthrough) { NavigationStack { PulseWalkthrough() } }
            .confirmationDialog("Delete your entire journal?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    PrivateSync.shared.disconnect()
                    Task {
                        do {
                            try await store.eraseJournal()
                            privacy.erase()
                            dismiss()
                        } catch { deleteError = true }
                    }
                }
                Button("Keep journal", role: .cancel) {}
            } message: {
                Text(
                    "This removes local check-ins, tasks, sessions, preferences and recovery data. Files you exported or synced separately stay where you saved them."
                )
            }
            .alert("Couldn’t delete the journal", isPresented: $deleteError) {
                Button("Close") {}
            } message: {
                Text("Your local journal is still here. Try again.")
            }
    }
    private func setting<T>(_ path: WritableKeyPath<Journal, T>) -> Binding<T> {
        Binding(get: { store.journal[keyPath: path] }, set: { value in store.change { $0[keyPath: path] = value } })
    }
}
