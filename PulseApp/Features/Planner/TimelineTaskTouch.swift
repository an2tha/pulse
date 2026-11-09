import SwiftUI
import UIKit

/// A plotted task takes the drag immediately. The surrounding ruler still scrolls from empty space.
struct TimelineTaskTouch: UIViewRepresentable {
    let title: String
    var destination: (CGPoint) -> String? = { _ in nil }
    let tap: () -> Void
    let moved: (CGPoint) -> Void
    let released: (CGPoint?) -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }
    func updateUIView(_ view: TouchView, context: Context) {
        view.taskTitle = title
        view.destination = destination
        view.tap = tap
        view.moved = moved
        view.released = released
    }

    final class TouchView: UIControl {
        var taskTitle = ""
        var destination: ((CGPoint) -> String?)?
        private var lift: UILabel?
        var tap: (() -> Void)?
        var moved: ((CGPoint) -> Void)?
        var released: ((CGPoint?) -> Void)?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(track(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = false
            pan.maximumNumberOfTouches = 1
            addGestureRecognizer(pan)
            addTarget(self, action: #selector(open), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { removeLift(); return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { scroll.panGestureRecognizer.require(toFail: pan) }
                ancestor = view.superview
            }
        }

        private func removeLift() {
            lift?.removeFromSuperview()
            lift = nil
        }

        private func updateLift(at point: CGPoint) {
            guard let window else { return }
            let label = lift ?? UILabel()
            if lift == nil {
                label.isAccessibilityElement = false
                label.isUserInteractionEnabled = false
                label.textAlignment = .center
                label.font = .preferredFont(forTextStyle: .subheadline)
                label.backgroundColor = .secondarySystemBackground
                label.textColor = .label
                label.layer.cornerRadius = 9
                label.clipsToBounds = true
                window.addSubview(label)
                lift = label
            }
            let target = destination?(point)
            label.text = target.map { taskTitle + " · " + $0 } ?? taskTitle
            let width = min(label.intrinsicContentSize.width + 22, window.bounds.width - 24)
            let height = max(34, label.font.lineHeight + 12)
            label.frame = CGRect(x: max(12, min(window.bounds.width - width - 12, point.x - width / 2)),
                                 y: max(window.safeAreaInsets.top, point.y - height - 20), width: width, height: height)
        }

        @objc private func open() { tap?() }
        @objc private func track(_ sender: UIPanGestureRecognizer) {
            let point = sender.location(in: window)
            switch sender.state {
            case .began, .changed:
                if sender.state == .began { UISelectionFeedbackGenerator().selectionChanged() }
                moved?(point)
                updateLift(at: point)
            case .ended: removeLift(); released?(point)
            case .cancelled, .failed: removeLift(); released?(nil)
            default: break
            }
        }
    }
}

struct TimelineHourTargets: Equatable {
    let day: DateInterval
    let overview: CGRect
    let ruler: CGRect
    let offset: CGFloat
    let hourWidth: CGFloat

    func hour(at point: CGPoint) -> Date? {
        let seconds: CGFloat
        if overview.contains(point), overview.width > 0 {
            seconds = (point.x - overview.minX) / overview.width * day.duration
        } else if ruler.contains(point), hourWidth > 0 {
            seconds = (offset + point.x - ruler.minX) / hourWidth * 3600
        } else { return nil }
        let hour = day.start.addingTimeInterval(floor(max(0, seconds) / 3600) * 3600)
        return hour < day.end ? hour : nil
    }
}

struct TimelineHourTargetsKey: PreferenceKey {
    static var defaultValue: TimelineHourTargets? { nil }
    static func reduce(value: inout TimelineHourTargets?, nextValue: () -> TimelineHourTargets?) {
        value = nextValue() ?? value
    }
}

struct AgendaTaskHandle: View {
    let title: String
    let tap: () -> Void
    let destination: (CGPoint) -> String?
    var hover: (CGPoint?) -> Void = { _ in }
    let drop: (CGPoint) -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: "line.3.horizontal")
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.surface.opacity(0.75))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            TimelineTaskTouch(title: title, destination: destination, tap: tap, moved: { hover($0) },
                              released: { point in
                                  if let point { drop(point) }
                                  hover(nil)
                              }).accessibilityHidden(true)
        }
        .accessibilityLabel("Move " + title)
        .accessibilityHint("Choose a day and hour")
    }
}
