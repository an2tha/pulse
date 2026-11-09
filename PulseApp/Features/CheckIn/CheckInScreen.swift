import PulseEngine
import SwiftUI
import UIKit

/// Live controls for the check-in sheet, all expressed on the journal’s 0...10 scale.
struct LakeConditions: Equatable {
    var clarity, interest: Double
    var sleep, workload: Double?
    var reduceMotion: Bool
}

struct CheckInScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var energy = 5.0
    @State private var clarity = 5.0
    @State private var interest = 5.0
    @State private var sleep = 5.0
    @State private var workload = 5.0
    @State private var addSleep = false
    @State private var addLoad = false
    @State private var feltWorse = false
    @State private var stress = 5.0
    @State private var includeStress = false
    @State private var fatigueNote = ""
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var details = false
    @State private var saved = false
    @ScaledMetric(relativeTo: .title3) private var rowLabelHeight = 25

    var body: some View {
        GeometryReader { viewport in
            if viewport.size.width > viewport.size.height && viewport.size.height < 500 {
                HStack(spacing: 0) {
                    scene.frame(width: viewport.size.width * 0.43)
                    controls
                }
            } else {
                VStack(spacing: 0) {
                    // Reserve room for the three tracks and the fixed footer on shorter phones.
                    let controlsHeight = 3 * (rowLabelHeight + 44) + 48 + 72
                    let sceneHeight = min(
                        viewport.size.height * (type.isAccessibilitySize ? 0.25 : 0.51),
                        viewport.size.height - controlsHeight)
                    scene.frame(height: max(140, sceneHeight))
                    controls
                }
            }
        }
        .background(store.sky.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let last = store.latest {
                energy = last.energy
                clarity = last.clarity
                interest = last.interest
            }
        }
    }

    private var scene: some View {
        let sky = store.sky
        return EnergyLandscape(
            sky: sky, energy: energy,
            conditions: LakeConditions(
                clarity: clarity, interest: interest,
                sleep: addSleep ? sleep : nil, workload: addLoad ? workload : nil,
                reduceMotion: reduceMotion),
            theme: store.landscapeTheme
        )
        .equatable()
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [sky.ground.opacity(0), sky.ground], startPoint: .top, endPoint: .bottom)
                .frame(height: 46).allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            HStack {
                Text("Check-in").font(.title2.weight(.medium)).tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Text("Skip").font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.surface).padding(.horizontal, 11).padding(.vertical, 5)
                        .background(sky.ground, in: Capsule())
                        .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .foregroundStyle(sky.usesLightHeaderInk ? Color.surface : Color.pine)
            .padding(.horizontal, 26).padding(.top, 10)
            .background {
                LinearGradient(stops: [
                    .init(color: sky.upperSky, location: 0),
                    .init(color: sky.upperSky.opacity(0.91), location: 0.58),
                    .init(color: sky.upperSky.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -18)
                .allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if details {
                            Toggle("Sleep quality", isOn: $addSleep).accessibilityLabel("Include sleep quality")
                            if addSleep { rating("Sleep quality", value: $sleep, showLabel: false) }
                            Toggle("Workload", isOn: $addLoad).accessibilityLabel("Include workload")
                            if addLoad { rating("Perceived workload", value: $workload, showLabel: false) }
                            Toggle("Stress", isOn: $includeStress)
                            if includeStress { rating("Stress", value: $stress, showLabel: false) }
                            TextField("Fatigue note (optional)", text: $fatigueNote, axis: .vertical).lineLimit(1...4)
                            Toggle("Feeling worse after activity", isOn: $feltWorse)
                            if feltWorse { Text("The rest of today stays open.").font(.subheadline) }
                        } else {
                            rating("Physical energy", value: $energy, ink: .trailAmber)
                            rating("Mental clarity", value: $clarity, ink: Ink(0x9BD1C5).color)
                            rating("Interest", value: $interest, ink: Ink(0xEFAB92).color)
                        }
                    }
                    .font(.headline.weight(.medium)).foregroundStyle(Color.surface)
                    .tint(store.sky.pigments[5].mixed(Ink(0x427962), 0.65).color)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .frame(maxWidth: 580).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(details)
                .transition(sectionTransition)
            }
            .clipped()
            let footer = type.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 12))
            footer {
                detailsButton
                if !type.isAccessibilitySize { Spacer(minLength: 8) }
                saveButton
            }
            .frame(maxWidth: 524)
            .padding(.horizontal, 28).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .background(store.sky.ground)
    }

    private var sectionTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let forward: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        let offset: CGFloat = (details ? 12 : -12) * forward
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: offset)),
            removal: .opacity.combined(with: .offset(x: -offset)))
    }

    private var detailsButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)) { details.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: details ? "chevron.backward" : "plus").font(.caption.weight(.semibold))
                Text(details ? "Ratings" : "Details")
            }.font(.subheadline.weight(.medium)).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).foregroundStyle(Color.surface)
            .accessibilityLabel(details ? "Back to ratings" : "Optional details")
    }

    private var saveButton: some View {
        SceneButton(title: "Save", icon: "checkmark") {
            guard !saved else { return }
            saved = true
            var report = CheckIn(
                energy: energy.rounded(), clarity: clarity.rounded(), interest: interest.rounded(),
                sleep: addSleep ? sleep.rounded() : nil, workload: addLoad ? workload.rounded() : nil,
                feltWorseAfterActivity: feltWorse)
            report.stress = includeStress ? stress.rounded() : nil
            report.fatigueNote = fatigueNote.isEmpty ? nil : fatigueNote
            store.change { $0.reports.append(report) }
            dismiss()
        }.accessibilityLabel("Save check-in")
    }

    private func rating(
        _ title: String, value: Binding<Double>, showLabel: Bool = true, ink: Color = .surface
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                if showLabel {
                    Text(title).font(.headline.weight(.medium))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(value.wrappedValue.rounded()))")
                        .font(.system(.title3, design: .monospaced).weight(.medium)).foregroundStyle(ink)
                    Text("/10").font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.surface.opacity(0.69))
                }
            }.accessibilityHidden(true)
            RatingTrack(value: value, label: title, color: UIColor(ink), headerHeight: rowLabelHeight)
                .frame(height: 44)
                .sensoryFeedback(.selection, trigger: Int(value.wrappedValue.rounded()))
        }
    }
}

/// The artwork tracks the finger continuously. Releasing the thumb selects a whole-number rating.
private struct RatingTrack: UIViewRepresentable {
    @Binding var value: Double
    var label: String
    var color: UIColor
    var headerHeight: CGFloat

    func makeUIView(context: Context) -> Track {
        let track = Track()
        track.minimumValue = 0
        track.maximumValue = 10
        track.prepareRail()
        track.setContentHuggingPriority(.defaultLow, for: .horizontal)
        track.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return track
    }
    func updateUIView(_ track: Track, context: Context) {
        context.coordinator.value = $value
        track.accessibilityLabel = label
        track.accessibilityHeaderHeight = headerHeight
        track.setInk(color)
        if track.value != Float(value) { track.setValue(Float(value), animated: false) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Track, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(44, proposal.height ?? 44))
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    @MainActor final class Coordinator {
        var value: Binding<Double>
        init(_ value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: UISlider) { value.wrappedValue = Double(sender.value) }
    }

    final class Track: UISlider {
        private var thumbOffset: CGFloat = 0
        var accessibilityHeaderHeight: CGFloat = 0

        // The single adjustable control includes its visible title and score.
        override var accessibilityFrame: CGRect {
            get {
                let frame = super.accessibilityFrame
                guard !frame.isEmpty else { return frame }
                return CGRect(x: frame.minX, y: frame.minY - accessibilityHeaderHeight,
                              width: frame.width, height: frame.height + accessibilityHeaderHeight)
            }
            set { super.accessibilityFrame = newValue }
        }

        private let rail = CAShapeLayer()
        private let divisions = CAShapeLayer()
        private let progressRail = CAShapeLayer()
        private var ink: UIColor?

        func prepareRail() {
            let empty = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            setMinimumTrackImage(empty, for: .normal)
            setMaximumTrackImage(empty, for: .normal)
            for layer in [rail, divisions, progressRail] {
                layer.fillColor = nil
                self.layer.insertSublayer(layer, at: 0)
            }
            rail.strokeColor = UIColor.white.withAlphaComponent(0.36).cgColor
            rail.lineWidth = 1
            divisions.strokeColor = UIColor.white.withAlphaComponent(0.60).cgColor
            divisions.lineWidth = 1
            progressRail.lineWidth = 2
        }

        func setInk(_ color: UIColor) {
            guard ink != color else { return }
            ink = color
            progressRail.strokeColor = color.cgColor
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: 25, height: 25)).image { _ in
                UIColor(white: 0.09, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 25, height: 25)).fill()
                UIColor(red: 1, green: 0.96, blue: 0.86, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 23, height: 23)).fill()
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 5, y: 5, width: 15, height: 15)).fill()
                UIColor(white: 0.16, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 11.5, y: 7, width: 2, height: 11), cornerRadius: 1).fill()
            }.withRenderingMode(.alwaysOriginal)
            setThumbImage(thumb, for: .normal)
            setThumbImage(thumb, for: .highlighted)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let rect = trackRect(forBounds: bounds)
            func position(_ value: Float) -> CGFloat {
                thumbRect(forBounds: bounds, trackRect: rect, value: value).midX
            }
            let left = position(minimumValue)
            let right = position(maximumValue)
            let y = rect.midY
            let ticks = UIBezierPath()
            for index in 0...40 {
                let x = left + CGFloat(index) / 40 * (right - left)
                let height: CGFloat = index.isMultiple(of: 4) ? 10 : 4
                ticks.move(to: CGPoint(x: x, y: y - height / 2))
                ticks.addLine(to: CGPoint(x: x, y: y + height / 2))
            }
            func line(to x: CGFloat) -> CGPath {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: left, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                return path.cgPath
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rail.path = line(to: right)
            divisions.path = ticks.cgPath
            progressRail.path = line(to: position(value))
            CATransaction.commit()
        }

        override func setValue(_ value: Float, animated: Bool) {
            super.setValue(value, animated: animated)
            setNeedsLayout()
        }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let point = touch.location(in: self)
            let thumb = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
            thumbOffset = thumb.contains(point) ? point.x - thumb.midX : 0
            follow(touch)
            return super.beginTracking(touch, with: event)
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            follow(touch)
            return true
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            if let touch { follow(touch) }
            step(0)
        }
        private func follow(_ touch: UITouch) {
            let rail = trackRect(forBounds: bounds)
            let start = thumbRect(forBounds: bounds, trackRect: rail, value: minimumValue).midX
            let end = thumbRect(forBounds: bounds, trackRect: rail, value: maximumValue).midX
            guard abs(end - start) > 1 else { return }
            let fraction = Float((touch.location(in: self).x - thumbOffset - start) / (end - start))
            setValue(minimumValue + min(1, max(0, fraction)) * (maximumValue - minimumValue), animated: false)
            sendActions(for: .valueChanged)
        }
        override var accessibilityValue: String? {
            get { "\(Int(value.rounded())) out of ten" }
            set { super.accessibilityValue = newValue }
        }
        override func accessibilityIncrement() { step(1) }
        override func accessibilityDecrement() { step(-1) }
        private func step(_ delta: Float) {
            setValue(value.rounded() + delta, animated: false)
            sendActions(for: .valueChanged)
        }
    }
}

struct Meter: View {
    let title, icon: String
    @Binding var value: Double
    @Environment(\.accessibilityReduceMotion) var reduced
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon).frame(width: 22).foregroundStyle(Color.moss)
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(value)) / 10").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(
                    Color.clay
                )
                .contentTransition(reduced ? .identity : .numericText())
            }
            Slider(value: $value, in: 0...10, step: 1).accessibilityLabel(title).accessibilityValue(
                "\(Int(value)) out of ten"
            )
            .sensoryFeedback(.selection, trigger: value)
        }
    }
}
