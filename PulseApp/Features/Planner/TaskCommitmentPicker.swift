import PulseEngine
import SwiftUI

struct TaskCommitmentPicker: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    let select: (TaskPreparation) -> Bool

    private struct Input: Equatable, Sendable {
        let events: [Commitment]
        let clock: Date
        let calendar: Calendar
    }
    private struct Option: Identifiable, Sendable {
        let title: String
        let link: TaskPreparation
        var id: TaskPreparation { link }
    }
    @State private var options: [Option] = []
    @State private var loading = true
    @State private var search = ""
    @State private var issue: String?

    var body: some View {
        let input = Input(events: store.planningEvents, clock: store.now, calendar: .current)
        let matches = options.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        List {
            if let issue { Text(issue).foregroundStyle(Color.clay) }
            if loading && options.isEmpty { ProgressView("Reading commitments") }
            else if options.isEmpty {
                ContentUnavailableView("No commitments in the next two weeks", systemImage: "calendar")
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                Section("Next two weeks") {
                    ForEach(matches) { option in
                        Button {
                            if select(option.link) { dismiss() }
                            else { issue = "This task or commitment changed. Choose another opening." }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title).font(.headline)
                                Text(option.link.lastKnownStart.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline).foregroundStyle(Color.moss)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .formPaper().foregroundStyle(Color.journalInk).tint(.journalAccent)
        .searchable(text: $search, prompt: "Find a commitment")
        .navigationTitle("Prepare for").navigationBarTitleDisplayMode(.inline)
        .task(id: input) {
            loading = true
            let job = Task.detached(priority: .userInitiated) { Self.upcoming(input) }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            options = result
            loading = false
        }
    }

    private nonisolated static func upcoming(_ input: Input) -> [Option] {
        let calendar = input.calendar
        let today = calendar.startOfDay(for: input.clock)
        var choices: [Option] = []
        for offset in 0..<14 {
            guard !Task.isCancelled, let day = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            for event in input.events {
                let links = event.preparationOccurrences(on: day, after: input.clock, calendar: calendar)
                choices += links.map { Option(title: event.title, link: $0) }
            }
        }
        return choices.sorted { a, b in
            if a.link.lastKnownStart == b.link.lastKnownStart { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return a.link.lastKnownStart < b.link.lastKnownStart
        }
    }
}
