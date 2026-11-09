import SwiftUI

struct OneRepWorkoutDraft: Identifiable {
    let id = UUID()
    var name = ""
    var sets = 1
    var reps = 8
    var weight = ""

    func exercise(locale: Locale) -> OneRepWorkoutRequest.Exercise? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWeight = weight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf16.count <= 80,
              (1...30).contains(sets), reps >= 0 else { return nil }
        var kilograms: Double?
        if !cleanWeight.isEmpty {
            let normalized = cleanWeight.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
            guard let number = Double(normalized), number.isFinite, number >= 0 else { return nil }
            kilograms = number
        }
        return .init(name: cleanName, sets: Array(repeating: .init(reps: reps, weightKg: kilograms), count: sets))
    }
}

struct OneRepWorkoutRequest: Encodable {
    struct Exercise: Encodable {
        struct SetEntry: Encodable {
            var reps: Int
            var weightKg: Double?
        }
        let name: String
        let sets: [SetEntry]
    }
    let date: String
    let durationMinutes: Int
    let exercises: [Exercise]

    init(date: Date, timeZone: TimeZone = .current, duration: Int, exercises: [Exercise]) {
        self.date = OneRepAPI.dayKey(date, timeZone: timeZone)
        self.durationMinutes = duration
        self.exercises = exercises
    }

    func submit(token: String) async throws {
        var request = URLRequest(url: OneRepAPI.origin.appending(path: "v1/workouts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(self)
        let data = try await OneRepAPI().send(request, token: token)
        struct Receipt: Decodable {
            let ok: Bool
            let sessionId: String
            let date: String
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.ok, !receipt.sessionId.isEmpty, receipt.date == date else {
            throw URLError(.cannotParseResponse)
        }
    }
}

struct OneRepWorkoutLog: View {
    let date: Date
    let onLogged: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(PrivacySession.self) private var privacy
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var exercises = [OneRepWorkoutDraft()]
    @State private var minutes = 30
    @State private var connection: UUID?
    @State private var message: String?
    @State private var saving = false

    private var allowed: Bool {
        workspace.canSync && !workspace.restoring && !privacy.lockConnections
            && workspace.journal.connections?.oneRep == true
    }

    private var payload: OneRepWorkoutRequest? {
        let rows = exercises.compactMap { $0.exercise(locale: locale) }
        guard !rows.isEmpty, rows.count == exercises.count else { return nil }
        return OneRepWorkoutRequest(date: date, duration: minutes, exercises: rows)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .omitted))
                    Stepper("\(minutes) min", value: $minutes, in: 1...600)
                        .accessibilityLabel("Duration").accessibilityValue("\(minutes) minutes")
                }
                ForEach($exercises) { $exercise in
                    Section {
                        TextField("Exercise name", text: $exercise.name)
                        if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 80 {
                            Text("Use up to 80 characters.").font(.footnote)
                        }
                        Stepper("\(exercise.sets) \(exercise.sets == 1 ? "set" : "sets")", value: $exercise.sets, in: 1...30)
                        Stepper("\(exercise.reps) reps per set", value: $exercise.reps, in: 0...999)
                        TextField("Weight per set (kg, optional)", text: $exercise.weight)
                            .keyboardType(.decimalPad)
                        if !exercise.weight.isEmpty, exercise.exercise(locale: locale) == nil,
                           !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           exercise.name.utf16.count <= 80 {
                            Text("Enter a weight of zero or more.").font(.footnote)
                        }
                        if exercises.count > 1 {
                            Button("Remove exercise", role: .destructive) {
                                exercises.removeAll { $0.id == exercise.id }
                            }
                        }
                    }
                }
                if exercises.count < 20 {
                    Button("Add exercise", systemImage: "plus") { exercises.append(OneRepWorkoutDraft()) }
                }
                if let message { Text(message).font(.subheadline).accessibilityLabel(message) }
            }
            .formPaper()
            .disabled(saving)
            .navigationTitle("Log in OneRep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || payload == nil || !allowed || connection == nil)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            guard allowed else { dismiss(); return }
            do {
                connection = try OneRepCredentials.load() == nil ? nil : OneRepCredentials.connectionID
                if connection == nil { message = "Connect your OneRep account, then open Quick log again." }
            } catch { message = "Unlock your device and reopen Quick log to access your OneRep connection." }
        }
        .onChange(of: allowed) { _, available in if !available { dismiss() } }
    }

    @MainActor private func save() async {
        guard !saving, allowed, let connection, let payload else { return }
        saving = true
        defer { saving = false }
        do {
            guard connection == OneRepCredentials.connectionID, let token = try await OneRepCredentials.validToken(),
                  connection == OneRepCredentials.connectionID, allowed else {
                message = "Your OneRep connection changed. Reopen Quick log before saving."
                return
            }
            try await payload.submit(token: token)
            guard allowed, connection == OneRepCredentials.connectionID else { dismiss(); return }
            onLogged()
            dismiss()
        } catch {
            if error is URLError || error is DecodingError || error as? OneRepAPIError == .unavailable {
                message = "Pulse couldn’t confirm the save. Check your workouts in OneRep before trying again."
            } else {
                message = error.localizedDescription
            }
        }
    }
}
