import PulseEngine
import SwiftUI

struct WeekImpactDisclosure: View {
    @Environment(Workspace.self) private var store
    @Binding var expanded: Bool
    let taskID: UUID
    let slot: TaskPlacement
    let fullTime: (Date) -> String

    private struct Request: Equatable {
        let taskID: UUID
        let slot: TaskPlacement
        let date: Date
        let energyRevision: Int
    }
    private struct Result {
        let request: Request
        let impact: WeekSlotImpact?
    }
    @State private var result: Result?
    @State private var showAll = false
    private var request: Request? {
        expanded ? Request(taskID: taskID, slot: slot, date: store.now, energyRevision: store.healthController.revision) : nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let request {
                if let result, result.request == request {
                    if let impact = result.impact {
                        if let margin = impact.margin {
                            Label(marginText(margin), systemImage: margin.isFocus ? "timer" : "calendar")
                                .font(.subheadline).foregroundStyle(Color.moss)
                        }
                        if impact.others.isEmpty {
                            Text(impact.selectedChanged ? "No other task’s projected blocks would change." : "This time already matches the projected week.")
                                .font(.subheadline)
                        } else {
                            Text(impact.others.count == 1 ? "1 other task would change in the projected week." :
                                    "\(impact.others.count) other tasks would change in the projected week.")
                                .font(.subheadline)
                            ForEach(impact.others.prefix(showAll ? impact.others.count : 3)) { change in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(change.title).font(.subheadline.weight(.medium))
                                    if !change.before.isEmpty {
                                        Text("Currently planned " + describe(change.before)).font(.caption).foregroundStyle(Color.moss)
                                    }
                                    Text(change.after.isEmpty ? (change.before.count == 1 ? "This block would drop out of the week." : "These blocks would drop out of the week.") :
                                            "Would be " + describe(change.after)).font(.caption)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if !showAll && impact.others.count > 3 {
                                Button("Show \(impact.others.count - 3) more") { showAll = true }
                            }
                        }
                    } else {
                        Text("The plan changed. Choose a time to compare again.").font(.subheadline)
                    }
                } else {
                    ProgressView("Comparing the week")
                }
            }
        } label: {
            Text("What changes")
        }
        .task(id: request) {
            showAll = false
            guard let request else { result = nil; return }
            let impact = await store.weekImpact(for: taskID, slot: slot)
            guard !Task.isCancelled else { return }
            result = Result(request: request, impact: impact)
        }
    }

    private func describe(_ blocks: [Block]) -> String {
        guard let first = blocks.first else { return "" }
        if blocks.count == 1 { return fullTime(first.start) + " · \(first.minutes) min" }
        let minutes = blocks.reduce(0) { $0 + $1.minutes }
        return "\(blocks.count) blocks totaling \(minutes) min, starting " + fullTime(first.start)
    }

    private func marginText(_ margin: WeekSlotImpact.Margin) -> String {
        let name = margin.isFocus ? "your current focus session" : "“\(margin.title)”"
        if margin.gap == 0 {
            return margin.eventIsFirst ? "Starts when \(name) ends." : "Ends when \(name) starts."
        }
        if margin.buffer > 0 && margin.gap == Double(margin.buffer) * 60 {
            return margin.eventIsFirst ? "Starts after the \(margin.buffer) min buffer following \(name)." :
                "Leaves the \(margin.buffer) min buffer before \(name)."
        }
        let amount = margin.gap < 60 ? "less than a minute" :
            Duration.seconds(margin.gap).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        var text = margin.eventIsFirst ? "Starts \(amount) after \(name) ends" : "Ends \(amount) before \(name) starts"
        if margin.buffer > 0 && margin.gap >= Double(margin.buffer) * 60 {
            text += ", including your \(margin.buffer) min buffer"
        }
        return text + "."
    }
}
