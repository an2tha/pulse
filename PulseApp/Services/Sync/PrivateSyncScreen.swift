import SwiftUI
import UniformTypeIdentifiers

struct PrivateSyncScreen: View {
    @Environment(Workspace.self) private var store
    @State private var sync = PrivateSync.shared
    @State private var code = ""
    @State private var creating = true
    @State private var savedKey = false
    @State private var chooseFolder = false
    @State private var revealKey = false
    @State private var error: String?
    @State private var resolution: UUID?
    @State private var confirming = false

    var body: some View {
        Form {
            if sync.connected {
                Section {
                    LabeledContent("Private sync", value: sync.busy ? "Syncing…" : sync.status)
                    Button("Sync now") { sync.manualRefresh(store: store) }.disabled(sync.busy)
                    Button(revealKey ? "Hide recovery key" : "Show recovery key") {
                        do {
                            code = try sync.recoveryKey()
                            revealKey.toggle()
                            if !revealKey { code = "" }
                        } catch { self.error = error.localizedDescription }
                    }
                    if revealKey { Text(code).font(.footnote.monospaced()).textSelection(.enabled).privacySensitive() }
                }
                if !sync.conflicts.isEmpty {
                    Section {
                        Button("Keep this device’s journal") {
                            resolution = nil
                            confirming = true
                        }
                        ForEach(sync.conflicts) { head in
                            Button {
                                resolution = head.id
                                confirming = true
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(
                                        "Use folder revision · "
                                            + head.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(
                                        "\(head.content.tasks.count) tasks · \(head.content.reports.count) check-ins · \(head.content.sessions.count) sessions"
                                    ).font(.caption)
                                }
                            }
                        }
                    } header: {
                        Text("Review differences")
                    } footer: {
                        Text(
                            "Your choice replaces the synced collections. Earlier encrypted revisions remain in the folder. Export a copy first if you want to keep both journals."
                        )
                    }
                }
                Section {
                    Button("Disconnect this device") {
                        sync.disconnect()
                        revealKey = false
                        code = ""
                    }
                } footer: {
                    Text(
                        "Disconnecting removes the key and folder access from Pulse. To delete cloud copies, remove Pulse Sync from the selected folder on all linked devices."
                    )
                }
            } else {
                Section {
                    Picker("Connection", selection: $creating) {
                        Text("Create").tag(true)
                        Text("Join").tag(false)
                    }.pickerStyle(.segmented)
                    if creating {
                        Button(code.isEmpty ? "Generate recovery key" : "Generate a different key") {
                            code = PrivateSync.newKey()
                            savedKey = false
                        }
                        if !code.isEmpty {
                            Text(code).font(.footnote.monospaced()).textSelection(.enabled).privacySensitive()
                            Toggle("I saved the key privately", isOn: $savedKey)
                        }
                    } else {
                        SecureField("Recovery key from the first device", text: $code).textInputAutocapitalization(
                            .never
                        ).autocorrectionDisabled()
                    }
                    Button(sync.busy ? "Connecting…" : "Choose folder") { chooseFolder = true }
                        .disabled(
                            sync.busy || (creating && !savedKey)
                                || Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines))?.count
                                    != 32
                        )
                } header: {
                    Text("Encrypted journal")
                } footer: {
                    Text(
                        "Choose the same parent folder in iCloud Drive on each device. Pulse encrypts tasks, calendar commitments, notes, check-ins, goals, templates and focus history before writing. Keep the recovery key outside that folder. Losing it prevents recovery."
                    )
                }
            }
        }.formPaper().navigationTitle("Private sync").disabled(store.isDemo || PrivacySession.connectionsLocked)
            .onChange(of: creating) {
                code = ""
                savedKey = false
            }
            .onDisappear {
                code = ""
                revealKey = false
                savedKey = false
            }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                do {
                    let url = try result.get()
                    Task {
                        do {
                            try await sync.connect(folder: url, code: code, creating: creating, store: store)
                            code = ""
                            savedKey = false
                        } catch { self.error = error.localizedDescription }
                    }
                } catch {
                    if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription }
                }
            }
            .confirmationDialog("Replace synced collections?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Use selected journal", role: .destructive) {
                    if let resolution { sync.take(resolution, store: store) } else { sync.keepLocal(store: store) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Private sync", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Close") {}
            } message: {
                Text(error ?? "")
            }
    }
}
