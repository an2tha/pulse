import SwiftUI

/// Keep the controls in the sky and let the foreground meet the journal at its lower edge.
struct JournalHeader<DateLabel: View>: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    @ViewBuilder var dateLabel: () -> DateLabel
    let actionTitle: String
    let actionIcon: String
    var action: () -> Void
    var settings: () -> Void

    var body: some View {
        let sky = store.sky
        HStack(spacing: 8) {
            dateLabel().font(.system(.subheadline, design: .rounded, weight: .semibold))
            Spacer(minLength: 4)
            Button(action: action) {
                if type.isAccessibilitySize {
                    Image(systemName: actionIcon).font(.body.weight(.medium)).dynamicTypeSize(...DynamicTypeSize.xxxLarge).frame(width: 44, height: 44).contentShape(
                        Circle())
                } else {
                    Label(actionTitle, systemImage: actionIcon)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .overlay { Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 0.7) }
                        .frame(minHeight: 44)
                }
            }.accessibilityLabel(actionTitle)
            Button(action: settings) {
                Image(systemName: "slider.horizontal.3").font(.body.weight(.medium)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }.accessibilityLabel("Settings")
        }
        .padding(.leading, 26).padding(.trailing, 16).padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .top)
        .containerRelativeFrame(.vertical, alignment: .top) { height, _ in
            min(350, max(150, height * 0.36))
        }
        .foregroundStyle(sky.usesLightHeaderInk ? Color.surface : Color.pine)
        .buttonStyle(PressStyle())
        .background {
            CirquePanorama(sky: sky)
        }
    }
}

private struct CirquePanorama: View {
    let sky: Sky

    // Multiply the same plate through changing light so its ridge and river stay in place.
    private func light(_ phase: Atmosphere) -> Ink {
        switch phase {
        case .dawn: Ink(0xFFD8C9)
        case .day: Ink(0xFFFFFF)
        case .golden: Ink(0xFFD18A)
        case .evening: Ink(0xAA91B9)
        case .night: Ink(0x556E97)
        }
    }

    var body: some View {
        GeometryReader { bounds in
            Image(decorative: "CirquePanorama")
                .resizable().scaledToFill()
                .colorMultiply(light(sky.precedingPhase).mixed(light(sky.phase), sky.phaseBlend).color)
                .frame(width: bounds.size.width, height: bounds.size.height)
                .clipped()
                .overlay {
                    LinearGradient(stops: [
                        .init(color: sky.upperSky, location: 0),
                        .init(color: sky.upperSky.opacity(0.94), location: 0.07),
                        .init(color: sky.upperSky.opacity(0), location: 0.36),
                        .init(color: sky.ground.opacity(0), location: 0.66),
                        .init(color: sky.ground.opacity(0.55), location: 0.88),
                        .init(color: sky.ground, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension JournalHeader where DateLabel == Text {
    init(
        dateLabel: String, actionTitle: String, actionIcon: String, action: @escaping () -> Void,
        settings: @escaping () -> Void
    ) {
        self.init(
            dateLabel: { Text(dateLabel) }, actionTitle: actionTitle, actionIcon: actionIcon, action: action,
            settings: settings)
    }
}

struct JournalTitleMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            HStack(alignment: .center, spacing: 9) {
                Text(title).font(.largeTitle.weight(.regular)).tracking(-0.6)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(
                    .white.opacity(0.65))
            }.frame(minHeight: 44)
        }.tint(.surface).accessibilityLabel(title)
    }
}

/// Printed contour lines sit in the lower margin, leaving the working part of the page clear.
struct JournalGround: View {
    let sky: Sky

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            sky.ground
            Canvas { context, size in
                let span = max(size.width, 370)
                let origin = CGPoint(x: size.width * 0.86, y: size.height + 34)
                for index in 0..<13 {
                    let radius = span * (0.10 + 0.042 * Double(index))
                    var contour = Path()
                    for step in 0...144 {
                        let theta = Double(step) * .pi / 72
                        let bend =
                            1.0 + 0.14 * sin(theta * 3 + 0.17 * Double(index))
                            + 0.075 * cos(theta * 5 - 0.06 * Double(index))
                        let point = CGPoint(
                            x: origin.x + radius * bend * cos(theta),
                            y: origin.y + radius * 0.67 * bend * sin(theta))
                        if step == 0 { contour.move(to: point) } else { contour.addLine(to: point) }
                    }
                    contour.closeSubpath()
                    context.stroke(
                        contour, with: .color(sky[6].opacity(index.isMultiple(of: 4) ? 0.16 : 0.095)),
                        lineWidth: index.isMultiple(of: 4) ? 1.0 : 0.65)
                }
            }
            .frame(maxWidth: 720)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// Keep one set of controls as the heading wraps. This also preserves VoiceOver focus.
struct JournalHeadingLayout: Layout {
  let stack: Bool

  private func measure(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, title: CGSize, actions: CGSize, stacked: Bool) {
    var title = subviews[0].sizeThatFits(.unspecified)
    var actions = subviews[1].sizeThatFits(.unspecified)
    let required = title.width + 12 + actions.width
    let available = width ?? required
    let stacked = stack || required > available
    if stacked {
      let column = ProposedViewSize(width: available, height: nil)
      title = subviews[0].sizeThatFits(column)
      actions = subviews[1].sizeThatFits(column)
    }
    return (available, title, actions, stacked)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let m = measure(proposal.width, subviews)
    let height = m.stacked ? m.title.height + 4 + m.actions.height : max(m.title.height, m.actions.height)
    return CGSize(width: m.width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let m = measure(bounds.width, subviews)
    if m.stacked {
      subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(m.title))
      subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + m.title.height + 4),
                        anchor: .topLeading, proposal: ProposedViewSize(m.actions))
    } else {
      subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(m.title))
      subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(m.actions))
    }
  }
}
