import PulseEngine
import SwiftUI
import Charts

extension Workspace {
    var plannedSleep: PlannedSleepWindow {
        journal.sleepWindow ?? sleepCalibrationWindow
    }

    var sleepCalibrationWindow: PlannedSleepWindow {
        let calendar = Calendar.current
        let wakes = sleepHistory.nights.map {
            calendar.component(.hour, from: $0.wake) * 60 + calendar.component(.minute, from: $0.wake)
        }.sorted()
        let wake = wakes.isEmpty ? 420 : wakes[wakes.count / 2]
        return PlannedSleepWindow(wake: wake, targetMinutes: Int(sleepHistory.need * 60))
    }
}

private func sleepClock(_ minute: Int, on day: Date) -> Date {
    Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
}

private func sleepLength(_ minutes: Int) -> String {
    Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

/// The rail uses the same elapsed-time scale as task rows, including clock changes.
struct SleepPlanTimeline: View {
    @Environment(Workspace.self) private var store
    let start: Date
    let end: Date
    let energy: [EnergyPoint]
    let landmarks: [EnergyTurningPoint]
    @Binding var preview: PlannedSleepWindow?
    @Binding var editing: Bool
    @GestureState private var drag: PlannedSleepWindow?
    @State private var draggedEdge: PlannedSleepWindow.Edge?
    @State private var previous: PlannedSleepWindow?
    private var plan: PlannedSleepWindow { store.plannedSleep }
    private var visible: PlannedSleepWindow { drag ?? plan }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.height / end.timeIntervalSince(start)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let day = Calendar.current.startOfDay(for: start)
                    let bed = sleepClock(visible.bedtime, on: day)
                    let wake = sleepClock(visible.wake, on: day)
                    let intervals = bed < wake ? [(bed, wake)] : [(day, wake), (bed, end)]
                    for (a, b) in intervals where b > start && a < end {
                        let top = max(0, a.timeIntervalSince(start) * scale)
                        let bottom = min(size.height, b.timeIntervalSince(start) * scale)
                        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                                     with: .color(TimelineEnergyRibbon.low.opacity(0.035)))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(landmarks) { marker in
                    if marker.id >= start && marker.id < end {
                        let isPeak = marker.kind == .peak
                        let tint = isPeak ? TimelineEnergyRibbon.high : TimelineEnergyRibbon.low
                        Label(isPeak ? "Peak" : "Dip", systemImage: isPeak ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Color.surface)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(store.sky.ground.opacity(0.88), in: Capsule())
                            .background(tint.opacity(0.3), in: Capsule())
                            .overlay { Capsule().strokeBorder(tint.opacity(0.5)) }
                            .fixedSize().offset(x: 4, y: (marker.id.timeIntervalSince(start) * scale) + 25)
                            .accessibilityLabel("Estimated \(isPeak ? "peak" : "dip") at \(marker.id.formatted(date: .omitted, time: .shortened))")
                            .allowsHitTesting(false)
                    }
                }
                ForEach(PlannedSleepWindow.Edge.allCases, id: \.self) { edge in
                    let time = sleepClock(visible.time(edge), on: start)
                    if time >= start && time < end {
                        let label = edge == .bedtime ? "Bedtime" : "Wake time"
                        Image(systemName: edge == .bedtime ? "moon.fill" : "sunrise.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.surface)
                            .padding(5).background(store.sky.ground, in: Capsule())
                            .overlay { Capsule().strokeBorder(Color.surface.opacity(0.55)) }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                                .updating($drag) { value, state, _ in
                                    state = moved(edge, delta: value.translation.height / scale)
                                }.onChanged { _ in draggedEdge = edge }.onEnded { value in
                                    save(moved(edge, delta: value.translation.height / scale))
                                })
                            .onTapGesture { editing = true }
                            .accessibilityLabel(label).accessibilityValue(time.formatted(date: .omitted, time: .shortened))
                            .accessibilityAdjustableAction { direction in
                                save(plan.moving(edge, to: plan.time(edge) + (direction == .increment ? 15 : -15)))
                            }
                            .overlay(alignment: .leading) {
                                if drag != nil {
                                    Text(time.formatted(date: .omitted, time: .shortened))
                                        .font(.caption.monospacedDigit()).fixedSize()
                                        .padding(4).background(store.sky.ground, in: Capsule())
                                        .offset(x: 40).allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .leading) {
                                if drag != nil && draggedEdge == edge {
                                    nextDayPreview
                                        .frame(width: 240)
                                        .offset(x: 48, y: edge == .bedtime ? -75 : 75)
                                        .allowsHitTesting(false)
                                }
                            }
                            .position(x: geo.size.width / 2, y: min(geo.size.height - 12, max(12, time.timeIntervalSince(start) * scale)))
                    }
                }
            }
        }
        .onChange(of: drag) { _, value in preview = value }
        .onDisappear { preview = nil }
        .sheet(isPresented: $editing, onDismiss: { previous = nil }) {
            NavigationStack {
                Form {
                    if let previous {
                        Section("Shorter sleep window") {
                            Text("Your planned sleep changed from \(sleepLength(previous.minutes)) to \(sleepLength(plan.minutes)). Both times now stay where you set them.")
                            Button("Restore previous window") {
                                store.change { $0.sleepWindow = previous }
                                self.previous = nil
                            }
                        }
                    }
                    Section {
                        ForEach(PlannedSleepWindow.Edge.allCases, id: \.self) { edge in
                            DatePicker(edge == .wake ? "Wake time" : "Bedtime", selection: Binding(
                                get: { sleepClock(plan.time(edge), on: start) },
                                set: { date in
                                    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                                    save(plan.moving(edge, to: (c.hour ?? 0) * 60 + (c.minute ?? 0)))
                                }), displayedComponents: .hourAndMinute)
                        }
                        LabeledContent("Planned sleep", value: sleepLength(plan.minutes))
                    } footer: {
                        Text(plan.independent ? "Both times are set independently each night." : "Moving one time keeps the duration. Adjust the other time to set both independently.")
                    }
                    Section("How the curve is estimated") {
                        Text("Sleep timing sets a starting rhythm from your body clock, rising sleep pressure and grogginess after waking. The chart previews repeating this nightly schedule. Body-clock shifts from a single changed night can take several days.")
                        Text("Recorded sleep and recent sleep debt adjust the level. Check-ins near the same hour, matching weekdays and comparable sleep, resting heart rate and HRV readings gradually refine the estimate.")
                        Text("The 0–10 scale and peak times are approximate. A check-in or manual correction takes priority.")
                    }
                    nextDayPreview.listRowBackground(Color.clear)
                    if plan.independent {
                        Button("Link times at current duration") {
                            store.change { $0.sleepWindow = PlannedSleepWindow(wake: plan.wake, targetMinutes: plan.minutes) }
                            previous = nil
                        }
                    }
                }.formPaper().navigationTitle("Nightly sleep window").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { editing = false } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private var nextDayPreview: some View {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? end
        let points = store.energyTimeline.projectedHours(on: tomorrow, sleepWindow: visible, referenceWindow: store.sleepCalibrationWindow)
        let turns = EnergyTurningPoint.find(in: points)
        return VStack(alignment: .leading, spacing: 7) {
            Text("Next day · " + tomorrow.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption.weight(.semibold))
            Chart(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Energy", point.score))
                    .interpolationMethod(.monotone).foregroundStyle(TimelineEnergyRibbon.middle.opacity(0.8))
            }
            .chartYScale(domain: 0...10).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 64)
            HStack(spacing: 10) {
                if let peak = turns.first(where: { marker in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: marker.id)
                    let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                    return marker.kind == .peak && (minute - visible.bedtime + 1440) % 1440 >= visible.minutes
                }) {
                    Text("Peak " + peak.id.formatted(date: .omitted, time: .shortened))
                }
                if let dip = turns.first(where: { $0.kind == .dip }) {
                    Text("Dip " + dip.id.formatted(date: .omitted, time: .shortened))
                }
            }.font(.caption2.monospacedDigit())
            Text("Repeating this sleep window").font(.caption2)
        }
        .padding(12).foregroundStyle(Color.surface)
        .background(store.sky.ground.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
    }

    private func moved(_ edge: PlannedSleepWindow.Edge, delta: CGFloat) -> PlannedSleepWindow {
        let original = sleepClock(plan.time(edge), on: start)
        let date = min(end.addingTimeInterval(-60), max(start, original.addingTimeInterval((delta / 900).rounded() * 900)))
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return plan.moving(edge, to: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    private func save(_ next: PlannedSleepWindow) {
        let old = plan
        guard next != old else { return }
        store.change { $0.sleepWindow = next }
        if next.independent && next.minutes < old.minutes {
            previous = old
            editing = true
        } else { previous = nil }
    }
}
