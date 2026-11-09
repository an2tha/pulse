import PulseEngine
import SwiftUI

struct PreFocusSuggestionRow: View {
    @Environment(Workspace.self) private var store
    @Binding var rule: WeeklyTimeBlock
    let occurrence: Date

    var body: some View {
        if rule.boostActivityID == nil, let suggestion = store.preFocusSuggestion(for: rule, opening: occurrence) {
            Button {
                guard rule.boostActivityID == nil,
                      let current = store.preFocusSuggestion(for: rule, opening: occurrence),
                      current.activity.id == suggestion.activity.id else { return }
                rule.boostActivityID = current.activity.id
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Use \(suggestion.activity.title)", systemImage: "leaf")
                    let change = suggestion.typicalChange.formatted(.number.sign(strategy: .always()).precision(.fractionLength(0...1)))
                    Text("\(suggestion.activity.minutes) min at \(suggestion.interval.start.formatted(date: .abbreviated, time: .shortened))")
                    Text("Typical energy change \(change) · \(suggestion.days) logged days")
                }.font(.subheadline).frame(minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("pre-focus-suggestion")
        }
    }
}
