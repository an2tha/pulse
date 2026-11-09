import PulseEngine
import SwiftUI
import UIKit

struct TaskDeleteRequest: Identifiable {
    let task: PlanTask
    let epoch: UUID
    var id: UUID { task.id }
}

struct TaskDeleteConfirmation: ViewModifier {
    @Environment(Workspace.self) private var store
    @Binding var request: TaskDeleteRequest?
    var onDeleted: () -> Void = {}

    func body(content: Content) -> some View {
        content.alert("Delete “" + (request?.task.title ?? "") + "”?",
                      isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                      presenting: request) { item in
            Button("Delete task", role: .destructive) {
                if store.deleteTask(item.task, in: item.epoch) { onDeleted() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            let detail = store.deletionDetail(for: item.task)
            if !detail.isEmpty { Text(detail) }
        }
    }
}

/// The agenda is a scrolling canvas, so native List swipe actions cannot attach to its rows.
/// Observe only swipes beginning on the task title, leaving its independent scheduling grip free.
private struct TaskSwipeRegion: UIViewRepresentable {
    let towardLeading: CGFloat
    let action: () -> Void

    func makeUIView(context: Context) -> Region { Region() }
    func updateUIView(_ view: Region, context: Context) {
        view.towardLeading = towardLeading
        view.action = action
    }
    static func dismantleUIView(_ view: Region, coordinator: ()) { view.detach() }

    final class Region: UIView, UIGestureRecognizerDelegate {
        var action: (() -> Void)?
        var towardLeading: CGFloat = -1
        lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.addGestureRecognizer(pan)
                    scroll.panGestureRecognizer.require(toFail: pan)
                    break
                }
                ancestor = view.superview
            }
        }

        func detach() { pan.view?.removeGestureRecognizer(pan) }
        @objc private func panned() {
            guard pan.state == .ended else { return }
            let movement = pan.translation(in: self)
            if movement.x * towardLeading >= 54 && abs(movement.x) > abs(movement.y) * 1.5 {
                action?()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            window != nil && bounds.contains(touch.location(in: self))
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: self)
            return velocity.x * towardLeading > 0 && abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}

struct TaskDeleteSwipe: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.background {
                TaskSwipeRegion(towardLeading: layoutDirection == .leftToRight ? -1 : 1, action: action)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }.accessibilityAction(named: "Delete task", action)
        } else { content }
    }
}
