import PulseEngine
import SwiftUI

struct HealthSkipPatternsSection: View {
    @Environment(Workspace.self) private var store
    let day: Date
    @State private var selection = Selection.first
    @State private var showAll = false

    private enum Selection {
        case first, task(UUID), closed

        func expandedID(in patterns: [TaskSkipPattern]) -> UUID? {
            switch self {
            case .first: return patterns.first?.id
            case .task(let id): return patterns.contains { $0.id == id } ? id : patterns.first?.id
            case .closed: return nil
            }
        }
    }

    var body: some View {
        let patterns = store.skipPatterns(through: day)
        let expandedID = selection.expandedID(in: patterns)
        VStack(alignment: .leading, spacing: 6) {
            Text("Repeated skips").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("health-skip-patterns-heading")
            Text("30 days through \(day.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.caption).foregroundStyle(Color.surface.opacity(0.78))
            if patterns.isEmpty {
                Text("Tasks appear here after two skips in this period.")
                    .font(.subheadline).padding(.top, 6)
            } else {
                ForEach(patterns.prefix(showAll ? patterns.count : 3)) { pattern in
                    let expanded = expandedID == pattern.id
                    Button {
                        selection = expanded ? .closed : .task(pattern.id)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pattern.title).font(.headline.weight(.medium))
                                Text(summary(of: pattern)).font(.subheadline)
                                    .foregroundStyle(Color.surface.opacity(0.82))
                            }
                            Spacer(minLength: 4)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.footnote).accessibilityHidden(true)
                        }
                        .multilineTextAlignment(.leading).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("health-skip-task-\(pattern.id)")
                    if expanded {
                        energyBreakdown(pattern)
                        if Calendar.current.isDate(day, inSameDayAs: store.now) {
                            if let target = pattern.targetTaskID {
                                if SkipTimingRecommendation.hasTimingEvidence(in: pattern.records, calendar: .current) {
                                    SkipSuggestionAction(pattern: pattern, taskID: target)
                                        .id(ActionIdentity(taskID: target, latestSkip: pattern.records.first?.id, epoch: store.journalEpoch))
                                } else {
                                    Text("These surveys haven’t shown a recurring time or low-energy pattern yet.")
                                        .font(.footnote).foregroundStyle(Color.surface.opacity(0.78))
                                }
                            } else {
                                Text("No task available to move.")
                                    .font(.footnote).foregroundStyle(Color.surface.opacity(0.78))
                            }
                        }
                    }
                    Divider().overlay(Color.surface.opacity(0.22))
                }
                if patterns.count > 3 {
                    Button(showAll ? "Show fewer tasks" : "Show all \(patterns.count) tasks") {
                        showAll.toggle()
                        if !showAll, !patterns.prefix(3).contains(where: { $0.id == expandedID }) { selection = .first }
                    }
                    .font(.subheadline).frame(minHeight: 44)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .privacySensitive()
        .onChange(of: day) { selection = .first; showAll = false }
    }

    private struct ActionIdentity: Hashable {
        let taskID: UUID
        let latestSkip: UUID?
        let epoch: UUID
    }

    private func summary(of pattern: TaskSkipPattern) -> String {
        let count = pattern.records.count
        let counts = pattern.energyCounts
        let scores = counts.indices.filter { counts[$0] > 0 }
        guard let first = scores.first, let last = scores.last else { return "\(count) skips" }
        let range = first == last ? String(first) : "\(first)–\(last)"
        return "\(count) skips · Energy \(range)/10"
    }

    private func energyBreakdown(_ pattern: TaskSkipPattern) -> some View {
        let counts = pattern.energyCounts
        let maximum = max(1, counts.max() ?? 0)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Energy reported when skipping").font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(counts.indices, id: \.self) { rating in
                    let count = counts[rating]
                    if count > 0 {
                        GridRow {
                            Text("\(rating)/10").monospacedDigit().fixedSize()
                            GeometryReader { geometry in
                                Capsule().fill(Color.trailAmber)
                                    .frame(width: max(2, geometry.size.width * CGFloat(count) / CGFloat(maximum)))
                            }.frame(height: 5).accessibilityHidden(true)
                            Text(count == 1 ? "1 skip" : "\(count) skips")
                                .monospacedDigit().fixedSize().gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Energy \(rating) out of 10")
                        .accessibilityValue(count == 1 ? "1 skip" : "\(count) skips")
                    }
                }
            }.font(.caption)
        }.padding(.vertical, 5)
    }
}

private struct SkipSuggestionAction: View {
    @Environment(Workspace.self) private var store
    let pattern: TaskSkipPattern
    let taskID: UUID
    @State private var phase = Phase.finding
    @State private var request = UUID()

    private enum Phase {
        case finding, noOpening
        case offered(SkipTimeOffer), applying(SkipTimeOffer)
        case moved(Date, UUID?), undone, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch phase {
            case .finding:
                ProgressView("Checking your week…").frame(minHeight: 44)
            case .noOpening:
                Text("No stronger match among this week’s available times.").font(.subheadline)
                findButton
            case .offered(let offer), .applying(let offer):
                Text(offer.reason).font(.subheadline)
                if case .applying = phase {
                    ProgressView("Updating Plan…").frame(minHeight: 44)
                } else {
                    Button {
                        phase = .applying(offer)
                        request = UUID()
                    } label: {
                        Label("Move to " + time(offer.start) + " · \(offer.minutes) min", systemImage: "calendar")
                            .multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: 44).foregroundStyle(Color.trailAmber)
                    .accessibilityIdentifier("health-apply-skip-suggestion")
                }
            case .moved(let start, let receipt):
                Label("Moved to " + time(start), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                if let move = store.undoableTimeMove(for: taskID), move.id == receipt {
                    Button("Undo time change") {
                        phase = store.undoTimeMove(move) ? .undone : .failed("The plan changed. Check the available times again.")
                    }.frame(minHeight: 44)
                } else { findButton }
            case .undone:
                Text("Previous timing restored.").font(.subheadline)
                findButton
            case .failed(let reason):
                Text(reason).font(.subheadline)
                findButton
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.surface)
        .task(id: request) { await run() }
    }

    private var findButton: some View {
        Button {
            phase = .finding
            request = UUID()
        } label: {
            Label("Check again", systemImage: "arrow.clockwise")
        }.frame(minHeight: 44).foregroundStyle(Color.trailAmber)
            .accessibilityIdentifier("health-find-skip-suggestion")
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    @MainActor private func run() async {
        do {
            switch phase {
            case .finding:
                let offer = try await store.skipTimeSuggestion(for: pattern)
                try Task.checkCancellation()
                phase = offer.map { .offered($0) } ?? .noOpening
            case .applying(let offer):
                try await store.applySkipTimeSuggestion(offer)
                try Task.checkCancellation()
                phase = .moved(offer.start, store.undoableTimeMove(for: taskID)?.id)
            default: return
            }
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }
}
