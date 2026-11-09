import PulseEngine
import SwiftUI

struct ActivityEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var activity: EnergyActivity
    @State private var issue: String?
    @State private var deleting = false
    init(initial: EnergyActivity) { _activity = State(initialValue: initial) }

    var body: some View {
        Form {
            TextField("Activity name", text: $activity.title).accessibilityIdentifier("activity-name")
            Picker("Type", selection: $activity.kind) { Text("Boost").tag(EnergyActivity.Kind.boost); Text("Drain").tag(EnergyActivity.Kind.drain) }
            Stepper("\(activity.minutes) minutes", value: $activity.minutes, in: 1...240)
            if store.energyActivityIsScheduled(activity.id) {
                Text("This boost is scheduled before a Focus window. Change the window first to remove it or mark it as a drain.").font(.footnote)
            } else if store.journal.customEnergyActivities?.contains(where: { $0.id == activity.id }) == true {
                Button("Delete activity", role: .destructive) { deleting = true }
            }
            if let issue { Text(issue).foregroundStyle(Color.clay) }
        }.formPaper().navigationTitle("Custom activity").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this custom activity?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete activity", role: .destructive) { if store.deleteEnergyActivity(activity.id) { dismiss() } }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") {
                activity.title = activity.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if store.saveEnergyActivity(activity) { dismiss() } else { issue = "Choose a different activity name." }
            }.disabled(!activity.isValid || (store.energyActivityIsScheduled(activity.id) && activity.kind == .drain)) }
        }
    }
}

struct EnergyActivityLogEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let activity: EnergyActivity
    var presentedAsSheet = true
    @State private var before: Int?
    @State private var after: Int?
    @State private var started = Date.now
    @State private var editing = false
    @State private var issue: String?
    init(activity: EnergyActivity, presentedAsSheet: Bool = true, started: Date = .now) {
        self.activity = activity
        self.presentedAsSheet = presentedAsSheet
        _started = State(initialValue: min(started, .now))
    }

    private var current: EnergyActivity { store.energyActivities.first { $0.id == activity.id } ?? activity }

    var body: some View {
        Form {
            Section {
                DatePicker("Started", selection: $started, in: ...Date.now)
                ActivityRatingPicker(title: "Before", rating: $before, prompt: "Choose rating")
                ActivityRatingPicker(title: "After", rating: $after, prompt: "Add later")
            } footer: { Text("Rate how your energy felt from 0 to 10.") }
            if let history = EnergyActivityLog.typicalChange(for: activity.id, in: store.journal.energyActivityLogs ?? []) {
                LabeledContent("Usual change", value: "\(history.change.formatted(.number.sign(strategy: .always()))) · \(history.days) logged days")
            }
            Button(after == nil ? "Log before rating" : "Save ratings") {
                guard let before else { return }
                let log = EnergyActivityLog(activity: current, started: started, before: before, after: after, finished: after == nil ? nil : .now)
                if store.recordEnergyActivity(log) { dismiss() } else { issue = "These ratings couldn’t be saved. Check the time and try again." }
            }.disabled(before == nil).accessibilityIdentifier("save-activity-log")
            if store.journal.customEnergyActivities?.contains(where: { $0.id == activity.id }) == true {
                Button("Edit activity", systemImage: "pencil") { editing = true }
            }
            if let issue { Text(issue).foregroundStyle(Color.clay) }
        }.formPaper().navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentedAsSheet { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheet(isPresented: $editing) { NavigationStack { ActivityEditor(initial: current) } }
    }
}

private struct ActivityRatingPicker: View {
    let title: String
    @Binding var rating: Int?
    let prompt: String
    var body: some View {
        Picker(title, selection: $rating) {
            Text(prompt).tag(nil as Int?)
            ForEach(0...10, id: \.self) { Text("\($0) / 10").tag(Optional($0)) }
        }
        .accessibilityIdentifier("activity-rating-" + title.lowercased())
    }
}

struct ActivityHistoryDetail: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var rating: Int?
    @State private var deleting = false
    var body: some View {
        Form {
            if let log = store.journal.energyActivityLogs?.first(where: { $0.id == id }) {
                Section {
                    LabeledContent("Activity", value: log.activity.title)
                    LabeledContent("Started", value: log.started.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Before", value: "\(log.before) / 10")
                    if let after = log.after {
                        LabeledContent("After", value: "\(after) / 10")
                        if let finished = log.finished {
                            LabeledContent("After rating recorded", value: finished.formatted(date: .abbreviated, time: .shortened))
                        }
                    } else {
                        ActivityRatingPicker(title: "After", rating: $rating, prompt: "Choose rating")
                        Button("Save after rating") {
                            if let rating, store.finishEnergyActivity(id, after: rating) { dismiss() }
                        }.disabled(rating == nil)
                    }
                }
                Button("Delete entry", role: .destructive) { deleting = true }
            }
        }.formPaper().navigationTitle("Activity history").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .confirmationDialog("Delete this activity entry?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                store.change { $0.energyActivityLogs?.removeAll { $0.id == id } }
                dismiss()
            }
        }
    }
}
