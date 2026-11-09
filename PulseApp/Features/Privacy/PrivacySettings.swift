import SwiftUI
import UniformTypeIdentifiers

struct JournalFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw JournalArchive.Failure.missing }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct JournalFilesScreen: View {
    @Environment(Workspace.self) private var store
    @State private var file: JournalFile?
    @State private var type = UTType.json
    @State private var documentName = "Pulse Journal"
    @State private var exporting = false
    @State private var importing = false
    @State private var restoring = false
    @State private var includeNotes = false
    @State private var testing = false
    @State private var candidate: Journal?
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Button("Back up journal as JSON") { export(csv: false) }
                Button("Restore from backup") { importing = true }
                    .disabled(store.journal.active != nil || restoring)
                if store.journal.active != nil {
                    Text("Finish your current focus session before restoring.").font(.footnote)
                }
            } footer: {
                Text("A backup contains tasks, check-ins, photos, notes and focus history. Choose a private location in Files.")
            }
            Section {
                Toggle("Include recovery feedback and notes", isOn: $includeNotes)
                Button("Export check-ins and focus as CSV") { export(csv: true) }
            } footer: {
                Text("CSV is for reviewing trends in a spreadsheet. JSON can restore the journal.")
            }
            if testing || restoring { ProgressView(restoring ? "Restoring journal" : "Preparing file") }
            if let message { Text(message).accessibilityAddTraits(.isStaticText) }
        }
        .formPaper().navigationTitle("Journal files").navigationBarTitleDisplayMode(.inline)
        .disabled(testing || restoring)
        .fileExporter(isPresented: $exporting, document: file, contentType: type, defaultFilename: documentName) {
            result in
            switch result {
            case .success: message = "File saved."
            case .failure(let issue): handle(issue)
            }
            file = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let issue): handle(issue)
            case .success(let url):
                testing = true
                Task {
                    defer { testing = false }
                    do {
                        candidate = try await Task.detached(priority: .userInitiated) {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                                size > JournalArchive.maxBytes
                            {
                                throw JournalArchive.Failure.tooLarge
                            }
                            return try JournalArchive.decodeBackup(Data(contentsOf: url, options: .mappedIfSafe))
                        }.value
                    } catch { handle(error) }
                }
            }
        }
        .confirmationDialog(
            "Replace the current journal?",
            isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }), presenting: candidate
        ) { restored in
            Button("Replace journal", role: .destructive) {
                candidate = nil
                restoring = true
                Task {
                    defer { restoring = false }
                    do {
                        var replacement = restored
                        // Restore content independently of the permissions on the source device.
                        replacement.notifications = store.journal.notifications
                        replacement.reminderPreferences = store.journal.reminderPreferences
                        replacement.connections = store.journal.connections
                        PrivateSync.shared.disconnect()
                        try await store.restoreJournal(replacement, disconnectOneRep: true)
                        message = "Journal restored."
                    } catch { handle(error) }
                }
            }
            Button("Keep current journal", role: .cancel) { candidate = nil }
        } message: { journal in
            Text(restoreSummary(journal))
        }
        .alert("Journal files", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Close") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
    private func restoreSummary(_ journal: Journal) -> String {
        let groups = [(journal.tasks.count, "task"), (journal.events.count, "commitment"),
                      (journal.reports.count, "check-in"), (journal.sessions.count, "session"),
                      (journal.photos?.count ?? 0, "photo"), (journal.practices?.count ?? 0, "weekly practice"),
                      (journal.goals?.count ?? 0, "goal"), (journal.templates?.count ?? 0, "template"),
                      (journal.energyCorrections?.count ?? 0, "energy update"), (journal.energyExpectations?.count ?? 0, "forecast adjustment"),
                      (journal.forecastHistory?.count ?? 0, "saved forecast")]
        let counts = groups.filter { $0.0 > 0 }.map { count, name in
            "\(count) " + name + (count == 1 ? "" : "s")
        }
        let summary = counts.isEmpty ? "This backup contains journal settings." : counts.joined(separator: " · ")
        return PrivateSync.shared.connected ? summary + "\nPrivate sync will be disconnected." : summary
    }
    private func export(csv: Bool) {
        testing = true
        let snapshot = store.journal
        let notes = includeNotes
        Task {
            defer { testing = false }
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    if csv { return JournalArchive.csv(snapshot, includePrivateNotes: notes) }
                    return try JournalArchive.backup(snapshot)
                }.value
                type = csv ? .commaSeparatedText : .json
                documentName = csv ? "Pulse trends" : "Pulse Journal"
                file = JournalFile(data: bytes)
                exporting = true
            } catch { handle(error) }
        }
    }
    private func handle(_ issue: Error) {
        guard (issue as NSError).code != NSUserCancelledError else { return }
        error =
            (issue as? LocalizedError)?.errorDescription
            ?? "The file could not be read or written. Check the file and try again."
    }
}

struct PrivacyOptionsScreen: View {
    @Environment(PrivacySession.self) private var privacy
    @Environment(Workspace.self) private var store
    @State private var feedback = ""
    var body: some View {
        @Bindable var privacy = privacy
        Form {
            Section("Your journal") {
                Text(
                    "Pulse stores your journal on this device. You choose which integrations to allow, which files to share, and whether to use private sync."
                )
                NavigationLink("Privacy policy") { PrivacyPolicyView() }
            }
            Section {
                Toggle("Keep local diagnostic counts", isOn: $privacy.diagnosticsEnabled)
                if privacy.diagnosticsEnabled {
                    Text(PrivacyDiagnostics.shared.summary).font(.footnote.monospacedDigit())
                    ShareLink(item: PrivacyDiagnostics.shared.summary) {
                        Label("Share diagnostic counts", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Apple delivers periodic crash and hang counts. Turning this off clears the local report.")
            }
            Section {
                Toggle(
                    "Keep external connections off",
                    isOn: Binding(
                        get: { privacy.lockConnections },
                        set: { locked in
                            privacy.lockConnections = locked
                            if locked {
                                privacy.sleepConnected = false
                                privacy.automaticHealthPlanning = false
                                PrivacySession.preferences.removeObject(forKey: "readOneRepHealth")
                                store.useHealthForToday(false)
                                store.healthController.clear()
                                PrivateSync.shared.disconnect()
                                store.change { $0.connections = nil }
                            }
                        }))
            } header: {
                Text("Privacy controls")
            } footer: {
                Text(
                    "Available at any age. This hides connection and sync setup. Calendar, Health and Screen Time permissions can also be changed in iPhone Settings."
                )
            }
            if ReleaseFeatures.returnAfterAbsence {
                Section("Preferences") {
                    Toggle("Offer a fresh start after a week away", isOn: $privacy.welcomeBackEnabled)
                }
            }
            Section {
                TextField("What could work better?", text: $feedback, axis: .vertical).lineLimit(2...5)
                ShareLink(item: feedback) { Label("Share feedback", systemImage: "square.and.arrow.up") }
                    .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Feedback")
            } footer: {
                Text("You choose the recipient. Your journal is excluded.")
            }
        }.formPaper().navigationTitle("Privacy & feedback").navigationBarTitleDisplayMode(.inline)
    }
}
