import PulseEngine
import SwiftUI

struct SpareMomentScreen: View {
    @Environment(Workspace.self) private var store
    let onStart: () -> Void
    @State private var minutes = 10
    @State private var changed = false

    var body: some View {
        let matches = store.spareMoments(minutes: minutes, at: store.now)
        List {
            Picker("Time available", selection: $minutes) {
                ForEach([5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 12, trailing: 0))
            if matches.isEmpty {
                ContentUnavailableView("Nothing fits right now", systemImage: "hourglass", description: Text(emptyReason))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(matches) { block in
                    Button {
                        guard case .task(let id) = block.kind else { return }
                        if store.startSpareMoment(id, minutes: minutes) { onStart() } else { changed = true }
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.title).font(.headline).foregroundStyle(Color.journalInk)
                                Text("\(block.minutes) min").font(.caption).foregroundStyle(Color.moss)
                            }
                            Spacer()
                            Image(systemName: "play.fill").font(.subheadline).foregroundStyle(Color.journalInk)
                        }
                        .padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Start \(block.title)")
                    .accessibilityValue("\(block.minutes) minutes")
                }
            }
        }
        .formPaper().navigationTitle("Spare moment").navigationBarTitleDisplayMode(.inline)
        .alert("Your plan changed", isPresented: $changed) {
            Button("OK") {}
        } message: {
            Text("Check the available tasks again.")
        }
    }

    private var emptyReason: String {
        if store.journal.active != nil { return "You already have a focus session." }
        if store.isRestDay { return "Today is a rest day." }
        if let recovery = store.liveRecovery {
            return "Your break ends at " + recovery.end.formatted(date: .omitted, time: .shortened) + "."
        }
        return "No available task fits this window and today’s workload."
    }
}
