import PulseEngine
import SwiftUI

/// The same rule can appear on several days or on both sides of midnight.
struct AgendaFocusTarget: Equatable {
    let ruleID: UUID
    let start: Date
    let title: String
    let frame: CGRect
}

struct AgendaFocusFrames: PreferenceKey {
    static var defaultValue: [AgendaFocusTarget] { [] }
    static func reduce(value: inout [AgendaFocusTarget], nextValue: () -> [AgendaFocusTarget]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    @ViewBuilder func focusDropFrame(_ block: Block, clippedTo viewport: CGRect? = nil) -> some View {
        if case .timeBlock(let id, .focus) = block.kind {
            background {
                GeometryReader { geometry in
                    let rect = geometry.frame(in: .global)
                    let visible = viewport.map { $0.intersection(rect) } ?? rect
                    Color.clear.preference(key: AgendaFocusFrames.self, value: visible.isEmpty ? [] : [
                        AgendaFocusTarget(ruleID: id, start: block.start, title: block.title, frame: visible)
                    ])
                }
            }
        } else { self }
    }
}
