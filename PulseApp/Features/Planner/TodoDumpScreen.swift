import PulseEngine
import SwiftUI

struct TodoDumpScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    private var input: String { store.captureDrafts.dump }
    private var tasks: [PlanTask] { store.captureDrafts.reviewed }
    @State private var reviewing: String?
    @FocusState private var writing: Bool
    let saved: () -> Void

    var body: some View {
        @Bindable var model = store
        Form {
            Section {
                TextEditor(text: Binding(get: { input }, set: { value in
                    guard value != input else { return }
                    store.captureDrafts.setDump(value)
                    reviewing = nil
                }))
                    .focused($writing)
                    .frame(minHeight: 100)
                    .accessibilityLabel("One to-do per line")
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("One to-do per line").foregroundStyle(Color.moss)
                                .padding(.leading, 5).padding(.top, 8).accessibilityHidden(true).allowsHitTesting(false)
                        }
                    }
                Button(reviewing == nil ? "Review tasks" : "Reviewing…") {
                    writing = false
                    reviewing = input
                }
                    .disabled(reviewing != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !tasks.isEmpty {
                Section {
                    ForEach($model.captureDrafts.reviewed) { $task in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).font(.headline)
                            Stepper("Energy demand · \(Int(task.energyDemand.rounded()))/10",
                                    value: Binding(get: { Int(task.energyDemand.rounded()) },
                                                   set: { task.energyOverride = Double($0) }), in: 0...10)
                            if let cadence = task.captureRecurrence() { Text(cadence).font(.subheadline) }
                            if let timing = task.captureTiming(in: store.captureDrafts.reviewedReference(for: task.id)?.calendar ?? .current) { Text(timing).font(.subheadline) }
                            Text("\(task.minutes) min · Today’s cost \(task.energyCost(at: store.capacity))/10")
                                .font(.caption).foregroundStyle(Color.moss)
                        }
                    }.onDelete { store.captureDrafts.reviewed.remove(atOffsets: $0) }
                } header: {
                    Text("Today’s energy · \(Int(store.capacity.rounded()))/10")
                } footer: {
                    Text("Adjust a task’s usual demand. Pulse estimates its cost today from your available energy.")
                }
                Button("Add to inbox (\(tasks.count))") {
                    guard store.ready, !store.restoring, !tasks.isEmpty else { return }
                    let accepted = tasks
                    clearDraft()
                    store.change { journal in
                        journal.tasks.append(contentsOf: accepted)
                        journal.starterAvailable = false
                    }
                    saved()
                }
            }
        }.formPaper().navigationTitle("To-do dump").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !input.isEmpty && store.captureDrafts.dumpReference == nil { store.captureDrafts.recoverDumpReference() }
            }
            .task(id: reviewing) {
                guard let text = reviewing, let reference = store.captureDrafts.dumpReference else { return }
                let events = store.planningEvents
                let draft = store.captureDrafts
                let result = await Task.detached(priority: .userInitiated) { draft.reviewDump(commitments: events) }.value
                guard !Task.isCancelled, text == input, reference == store.captureDrafts.dumpReference else { return }
                store.captureDrafts.reviewed = result.tasks
                store.captureDrafts.reviewedLineIndices = result.indices.isEmpty ? nil : result.indices
                reviewing = nil
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { clearDraft(); dismiss() } } }
            .onDisappear { store.flushCaptureDrafts() }
    }
    private func clearDraft() {
        store.captureDrafts.setDump("")
    }
}
