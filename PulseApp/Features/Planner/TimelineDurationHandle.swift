import SwiftUI
import UIKit

/// A vertical pan beginning on the end grip belongs to the duration editor.
struct TimelineDurationHandle: UIViewRepresentable {
    var update: (CGFloat) -> Void
    var finish: (CGFloat?) -> Void
    var tap: () -> Void

    func makeUIView(context: Context) -> Control { Control() }
    func updateUIView(_ view: Control, context: Context) {
        view.callbacks = self
    }

    final class Control: UIControl {
        var callbacks: TimelineDurationHandle?
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
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { scroll.panGestureRecognizer.require(toFail: pan) }
                ancestor = view.superview
            }
        }

        @objc private func open() { callbacks?.tap() }
        @objc private func track(_ gesture: UIPanGestureRecognizer) {
            let distance = gesture.translation(in: window).y
            switch gesture.state {
            case .began, .changed: callbacks?.update(distance)
            case .ended: callbacks?.finish(distance)
            case .cancelled, .failed: callbacks?.finish(nil)
            default: break
            }
        }
    }
}

struct TimelineDurationTarget: Identifiable, Equatable {
    let id: String
    let taskID: UUID
    let title: String
    let start: Date
    let end: Date

    var minutes: Int { max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }

    func maxMinutes(before midnight: Date) -> Int {
        min(1440, max(1, Int(midnight.timeIntervalSince(start) / 60)))
    }

    func newMinutes(translation: CGFloat, secondsPerPoint: Double, midnight: Date) -> Int {
        let delta = Int((translation * secondsPerPoint / 60).rounded())
        return min(maxMinutes(before: midnight), max(1, minutes + delta))
    }
}

struct TimelineDurationEditor: View {
    let target: TimelineDurationTarget
    let dayEnd: Date
    let apply: (Int) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var problem: String?

    init(target: TimelineDurationTarget, dayEnd: Date, apply: @escaping (Int) async throws -> Void) {
        self.target = target
        self.dayEnd = dayEnd
        self.apply = apply
        _text = State(initialValue: String(target.minutes))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(target.title).font(.headline)
                    LabeledContent("Minutes") {
                        TextField("Minutes", text: $text).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).accessibilityLabel("Duration in minutes")
                    }
                    if let value {
                        LabeledContent("Ends at", value: target.start.addingTimeInterval(Double(value) * 60)
                            .formatted(date: .omitted, time: .shortened))
                    }
                    if let problem { Text(problem).font(.footnote) }
                }
            }
            .formPaper().navigationTitle("Duration").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value, !saving else { return }
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do { try await apply(value); dismiss() }
                            catch { problem = error.localizedDescription }
                        }
                    }.disabled(value == nil || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var value: Int? {
        guard let number = Int(text), (1...target.maxMinutes(before: dayEnd)).contains(number) else { return nil }
        return number
    }
}
