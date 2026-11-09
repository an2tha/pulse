import SwiftUI
import UIKit

struct TaskCompletionEvent: Equatable {
    let id = UUID()
    let taskID: UUID
}

/// Display feedback in the originating window, including over presented task editors.
struct TaskCompletionCue: UIViewRepresentable {
    @Environment(Workspace.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduced

    @MainActor final class Coordinator {
        var last: UUID?
        private var host: UIHostingController<CompletionBadge>?
        var dismissal: Task<Void, Never>?

        func clear() {
            dismissal?.cancel()
            dismissal = nil
            host?.view.removeFromSuperview()
            host = nil
        }

        func present(in window: UIWindow, reduced: Bool) {
            clear()
            let badge = UIHostingController(rootView: CompletionBadge(reduced: reduced))
            host = badge
            let view = badge.view!
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            view.translatesAutoresizingMaskIntoConstraints = false
            badge.sizingOptions = .intrinsicContentSize
            window.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                view.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
                view.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -24)
            ])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Task complete"))
            dismissal = Task { @MainActor [weak self, weak view] in
                do { try await Task.sleep(for: .milliseconds(1150)) } catch { return }
                guard let view else { return }
                UIView.animate(withDuration: 0.2, animations: { view.alpha = 0 }) { _ in
                    if self?.host === badge { self?.clear() }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.last = store.taskCompletion?.id
        return coordinator
    }
    func makeUIView(context: Context) -> UIView {
        let anchor = UIView()
        anchor.isUserInteractionEnabled = false
        anchor.accessibilityElementsHidden = true
        return anchor
    }
    func updateUIView(_ anchor: UIView, context: Context) {
        let coordinator = context.coordinator
        let event = store.taskCompletion?.id
        guard coordinator.last != event else { return }
        coordinator.last = event
        guard event != nil, let window = anchor.window else { coordinator.clear(); return }
        coordinator.present(in: window, reduced: reduced)
    }
    static func dismantleUIView(_ anchor: UIView, coordinator: Coordinator) { coordinator.clear() }
}

private struct CompletionBadge: View {
    let reduced: Bool
    @State private var started = Date.now

    var body: some View {
        VStack(spacing: -5) {
            if reduced {
                CompletionSun(progress: 1).frame(width: 176, height: 104)
            } else {
                TimelineView(.animation) { tick in
                    CompletionSun(progress: min(1, max(0, tick.date.timeIntervalSince(started) / 0.9)))
                }.frame(width: 176, height: 104)
            }
            Text("Task complete")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 15).padding(.vertical, 7)
                .background(Color.pine, in: Capsule())
        }.shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

private struct CompletionSun: View {
    let progress: CGFloat
    private let pale = Color(red: 1, green: 0.96, blue: 0.76)
    private let amber = Color(red: 1, green: 0.71, blue: 0.35)
    private let mint = Color(red: 0.55, green: 0.91, blue: 0.79)

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.52)
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            }
            func ease(_ t: CGFloat) -> CGFloat { 1 - pow(1 - max(0, min(1, t)), 3) }

            let bloom = ease(progress / 0.7)
            let glow = circle(47)
            context.fill(glow, with: .radialGradient(
                Gradient(colors: [amber.opacity(0.43), amber.opacity(0)]),
                center: center, startRadius: 12, endRadius: 47))
            context.stroke(circle(22 + 23 * bloom), with: .color(pale.opacity(0.55 * (1 - bloom))), lineWidth: 1.4)

            // Short arcs catch the light at different angles as the sun opens.
            for index in 0..<18 {
                let angle = CGFloat(index) * 2 * .pi / 18 + 0.15
                let flight = ease((progress - CGFloat(index % 3) * 0.04) / 0.76)
                let radius = 23 + flight * CGFloat(14 + index % 4 * 7)
                let length = (1 - flight) * 8 + 1.4
                let dx = cos(angle), dy = sin(angle)
                let tip = CGPoint(x: center.x + dx * radius * 1.22, y: center.y + dy * radius * 0.86)
                var ray = Path()
                ray.move(to: tip)
                ray.addLine(to: CGPoint(x: tip.x + dx * length, y: tip.y + dy * length))
                let color = [pale, mint, amber][index % 3]
                context.stroke(ray, with: .color(color.opacity(0.95 * (1 - flight))), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }

            // A few slower glints carry the burst beyond the inner ring.
            for index in 0..<6 {
                let angle = CGFloat(index) * .pi / 3 - 0.27
                let life = min(1, max(0, (progress - 0.04 * CGFloat(index % 3)) / 0.84))
                let reach = ease(life)
                let x = center.x + cos(angle) * (32 + 36 * reach)
                let y = center.y + sin(angle) * (25 + 20 * reach)
                let light = sin(.pi * life)
                let width = 1 + 2.3 * light, height = width * 1.65
                var star = Path()
                star.move(to: CGPoint(x: x, y: y - height))
                star.addQuadCurve(to: CGPoint(x: x + width, y: y), control: CGPoint(x: x, y: y))
                star.addQuadCurve(to: CGPoint(x: x, y: y + height), control: CGPoint(x: x, y: y))
                star.addQuadCurve(to: CGPoint(x: x - width, y: y), control: CGPoint(x: x, y: y))
                star.addQuadCurve(to: CGPoint(x: x, y: y - height), control: CGPoint(x: x, y: y))
                context.fill(star, with: .color((index.isMultiple(of: 2) ? mint : pale).opacity(light)))
            }

            let radius = 23 + 5 * sin(.pi * min(1, progress / 0.48)) + 2 * bloom
            let disc = circle(radius)
            context.fill(disc, with: .linearGradient(Gradient(colors: [pale, amber]),
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)))
            context.stroke(disc, with: .color(.white.opacity(0.78)), lineWidth: 1)
            var tick = Path()
            tick.move(to: CGPoint(x: center.x - 10, y: center.y))
            tick.addLine(to: CGPoint(x: center.x - 3, y: center.y + 7))
            tick.addLine(to: CGPoint(x: center.x + 11, y: center.y - 8))
            context.stroke(tick.trimmedPath(from: 0, to: ease((progress - 0.06) / 0.38)),
                           with: .color(.pine), style: StrokeStyle(lineWidth: 3.8, lineCap: .round, lineJoin: .round))
        }
    }
}
