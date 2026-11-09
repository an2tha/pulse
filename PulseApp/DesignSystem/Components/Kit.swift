import PulseEngine
import SwiftUI

extension Color {
    static let trailAmber = Color(red: 1, green: 209.0 / 255, blue: 135.0 / 255)
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduced ? 0.98 : 1)
            .animation(reduced ? nil : .snappy(duration: 0.15), value: configuration.isPressed)
    }
}
struct SolidButton: View {
    let title: String
    var icon: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon { Image(systemName: icon).font(.caption.weight(.bold)) }
                Text(title).font(.headline)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(Color.paper).background(Color.journalInk, in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(PressStyle())
    }
}
extension PulseEngine.Category {
    var symbol: String {
        switch self {
        case .focus: "scope"
        case .study: "book"
        case .personal: "leaf"
        case .recovery: "wind"
        }
    }
}
extension View {
    func formPaper() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.paper)
            .foregroundStyle(Color.journalInk)
            .tint(.journalAccent)
            .toolbarBackground(Color.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .presentationBackground(Color.paper)
    }
}
