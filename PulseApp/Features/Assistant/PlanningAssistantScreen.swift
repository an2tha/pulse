import FoundationModels
import PulseEngine
import SwiftUI

struct PlanningAssistantScreen: View {
    @Environment(Workspace.self) private var store
    @State private var input = ""
    @State private var proposal: AssistantProposal?
    @State private var source = ""
    @State private var busy = false
    @State private var job: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var result: String?
    @State private var options = false
    var body: some View {
        Form {
            Section {
                TextField("Add tasks, move a task or ask for smaller steps", text: $input, axis: .vertical).lineLimit(
                    2...5
                )
                .onChange(of: input) { invalidate() }
                Button(busy ? "Preparing…" : "Preview") { request(input) }.disabled(
                    busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let proposal {
                Section(source) { review(proposal) }
            }
            if let result { Section { Text(result) } }
            Section {
                Button("Explain my day") { request("Explain my day") }
                Button("Review my week") { request("Review my week") }
            }
            DisclosureGroup("Preferences and privacy", isExpanded: $options) {
                Picker(
                    "Start new tasks",
                    selection: Binding(
                        get: { store.journal.connections?.planningPreference ?? "" },
                        set: { value in settings { $0.planningPreference = value } })
                ) {
                    ForEach(AssistantPlanner.preferences, id: \.self) { p in Text(p).tag(p == "Any time" ? "" : p) }
                }
                Toggle(
                    "Use Apple’s on-device model",
                    isOn: Binding(
                        get: { store.journal.connections?.onDeviceAssistant ?? false },
                        set: { value in settings { $0.onDeviceAssistant = value } }))
                Text(modelStatus).font(.caption)
            }
        }.formPaper().navigationTitle("Planning assistant").navigationBarTitleDisplayMode(.inline)
            .onDisappear { invalidate() }
    }
    @ViewBuilder private func review(_ action: AssistantProposal) -> some View {
        switch action {
        case .answer(let reply): Text(reply)
        case .choose(let tasks, let intent):
            Text("Which task?").font(.headline)
            ForEach(tasks) { task in
                Button(task.title) {
                    run {
                        (
                            try await AssistantPlanner.proposal(
                                for: task, intent: intent,
                                allowModel: store.journal.connections?.onDeviceAssistant == true), "Review"
                        )
                    }
                }
            }
        case .move(let task, let date):
            Text(task.title)
            LabeledContent("Available from", value: date.formatted(date: .abbreviated, time: .shortened))
            applyButton(action)
        case .steps(let task, let steps):
            Text(task.title).font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                TextField(
                    "Step \(index+1)",
                    text: Binding(
                        get: {
                            if case .steps(_, let current) = self.proposal, current.indices.contains(index) {
                                return current[index]
                            }
                            return ""
                        },
                        set: { value in
                            if case .steps(let original, var current) = self.proposal, current.indices.contains(index) {
                                current[index] = value
                                self.proposal = .steps(original, current)
                            }
                        }), axis: .vertical)
            }
            applyButton(action)
        case .capture(let draft):
            ForEach(draft.tasks) { task in
                VStack(alignment: .leading) {
                    Text(task.title)
                    Text(
                        "\(task.minutes) min"
                            + (task.captureRecurrence().map { " · " + $0 } ?? "")
                            + (task.after.map { " · From " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            + (task.availability.map { " · Available " + $0.formattedHours() } ?? "")
                            + (task.due.map { " · Due " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    ).font(.caption)
                }
            }
            ForEach(draft.commitments) { event in
                VStack(alignment: .leading) {
                    Label(event.title, systemImage: "lock")
                    Text(
                        event.start.formatted(date: .abbreviated, time: .shortened) + " to "
                            + event.end.formatted(date: .abbreviated, time: .shortened)
                            + (event.recurrence == .once ? "" : " · " + event.recurrence.rawValue)
                    ).font(.caption)
                }
            }
            applyButton(action)
        }
    }
    private func applyButton(_ action: AssistantProposal) -> some View {
        Button("Apply to journal") {
            var updated = store.journal
            do {
                try action.apply(to: &updated)
                store.change { $0 = updated }
                self.proposal = nil
                result = "Saved to your journal."
            } catch { result = error.localizedDescription }
        }
    }
    private var modelStatus: String {
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            return
                "Apple’s model runs on this device. It uses your request, a selected task title, or weekly counts when you ask for a reflection."
        }
        return "The offline parser is active. Apple’s model requires a supported device with Apple Intelligence ready."
    }
    private func settings(_ edit: (inout ConnectionState) -> Void) {
        invalidate()
        store.change { j in
            var state = j.connections ?? ConnectionState()
            edit(&state)
            j.connections = state
        }
    }
    private func request(_ text: String) {
        run { try await AssistantPlanner.propose(text, journal: store.journal, blocks: store.blocks, now: .now) }
    }
    private func invalidate() {
        job?.cancel()
        generation = UUID()
        busy = false
        proposal = nil
        result = nil
    }
    private func run(_ operation: @escaping @MainActor () async throws -> (AssistantProposal, String)) {
        invalidate()
        busy = true
        let token = generation
        job = Task {
            defer { if token == generation { busy = false } }
            do {
                let response = try await operation()
                guard !Task.isCancelled, token == generation else { return }
                proposal = response.0
                source = response.1
            } catch { if !Task.isCancelled, token == generation { result = error.localizedDescription } }
        }
    }
}
