import SwiftUI

/// Practice is entirely local to this presentation. Closing it discards every example.
struct PulseWalkthrough: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dynamicTypeSize) private var type
    let finish: (() -> Void)?

    enum Lesson: String, CaseIterable {
        case capture = "Capture", plan = "Schedule", repeatTime = "Repeat", focus = "Focus", energy = "Energy"
        var heading: String {
            switch self {
            case .capture: "Catch a to-do"
            case .plan: "Give it a time"
            case .repeatTime: "Protect a regular hour"
            case .focus: "Start a short sprint"
            case .energy: "Plan around your energy"
            }
        }
        var instruction: String {
            switch self {
            case .capture: "On Today, tap Quick add. Type a task, or include a time like “call Sam tomorrow at 3”."
            case .plan: "In Today’s plan, open Tasks and drag a to-do onto an open time. Try placing this example at 3:00."
            case .repeatTime: "In Add to plan, choose New time block and Protected time. Under Repeat, select Choose days and tap the days you want to keep free."
            case .focus: "Tap the play button beside a to-do to begin. During a sprint, Capture distraction saves a thought in Inbox."
            case .energy: "Use Check in on Today to rate your energy. Open Health to compare your ratings, see forecasts and adjust your plan."
            }
        }
    }

    init(startingAt lesson: Lesson = .capture, finish: (() -> Void)? = nil) {
        self.finish = finish
        _lesson = State(initialValue: lesson)
    }

    @State private var lesson: Lesson
    @State private var draft = ""
    @State private var captured: String?
    @State private var practiceTime: String?
    @State private var weekdays: Set<Int> = [2, 4, 6]
    @State private var runningSince: Date?
    @State private var seconds: TimeInterval = 120
    @State private var energy = 5.0
    @FocusState private var typing: Bool
    private var example: String { captured ?? "Read a chapter" }

    var body: some View {
        GeometryReader { bounds in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LookoutLandscape(sky: store.sky, energy: energy, theme: store.landscapeTheme)
                        .frame(maxWidth: .infinity)
                        .frame(height: min(215, max(100, bounds.size.height * 0.25)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 12) {
                        Menu {
                            ForEach(Lesson.allCases, id: \.self) { page in
                                Button { select(page) } label: {
                                    if lesson == page { Label(page.rawValue, systemImage: "checkmark") }
                                    else { Text(page.rawValue) }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(lesson.rawValue)
                                Image(systemName: "chevron.down").font(.caption2)
                            }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                        }
                        .accessibilityLabel("Walkthrough topics").accessibilityValue(lesson.rawValue)
                        Text(lesson.heading).font(.largeTitle.weight(.regular)).tracking(-0.8)
                            .accessibilityAddTraits(.isHeader)
                        Text(lesson.instruction).font(.body).fixedSize(horizontal: false, vertical: true)
                        practice
                            .padding(.vertical, 10)
                        Divider().overlay(Color.surface.opacity(0.25))
                        HStack {
                            if let previous = neighbor(-1) {
                                Button("Back") { select(previous) }.frame(minWidth: 48, minHeight: 48)
                            }
                            Spacer()
                            if let next = neighbor(1) {
                                SceneButton(title: "Next", icon: "arrow.right") { select(next) }
                            } else {
                                SceneButton(title: finish == nil ? "Done" : "Open my journal", icon: "checkmark") {
                                    if let finish { finish() } else { dismiss() }
                                }.accessibilityIdentifier("finish-pulse-walkthrough")
                            }
                        }
                    }
                    .padding(.horizontal, 26).padding(.vertical, 16)
                    .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .id(lesson)
        }
        .task(id: runningSince) {
            guard let start = runningSince else { return }
            do { try await Task.sleep(for: .seconds(timeLeft(at: .now))) }
            catch { return }
            guard runningSince == start else { return }
            seconds = 0
            runningSince = nil
        }
        .foregroundStyle(Color.surface).tint(.trailAmber)
        .background(store.sky.ground)
        .navigationTitle("Pulse walkthrough").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .accessibilityLabel("Close walkthrough")
            }
        }
    }

    @ViewBuilder private var practice: some View {
        switch lesson {
        case .capture:
            VStack(alignment: .leading, spacing: 6) {
                Text("Practice task").font(.caption.weight(.medium))
                if let captured {
                    Label(captured, systemImage: "tray").font(.headline)
                    Text("To remove a real task, swipe left on its title and tap Delete.").font(.subheadline)
                    Button("Clear practice task") { self.captured = nil }
                        .frame(minHeight: 44)
                } else {
                    TextField("Read a chapter", text: $draft, prompt: Text("Read a chapter").foregroundStyle(Color.surface.opacity(0.74)))
                        .focused($typing).textInputAutocapitalization(.sentences)
                        .submitLabel(.done).onSubmit(capture)
                        .padding(12).background(Color.surface.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Practice task")
                    Button("Try capture", action: capture).frame(minHeight: 44)
                }
                Text("Walkthrough examples stay out of your journal.").font(.caption)
            }
        case .plan:
            VStack(alignment: .leading, spacing: 8) {
                Label(example, systemImage: "line.3.horizontal").font(.headline)
                    .frame(minHeight: 44).draggable("pulse-walkthrough-example")
                VStack(spacing: 4) {
                    practiceHour("2:00")
                    practiceHour("3:00")
                }
            }
        case .repeatTime:
            VStack(alignment: .leading, spacing: 8) {
                Label("Protected time · 9–10 AM", systemImage: "shield").font(.headline)
                let calendar = Calendar.current
                let columns = [GridItem(.adaptive(minimum: type.isAccessibilitySize ? 74 : 44), spacing: 5)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                    ForEach(0..<7, id: \.self) { offset in
                        let day = (calendar.firstWeekday - 1 + offset) % 7 + 1
                        let active = weekdays.contains(day)
                        Button {
                            if active {
                                if weekdays.count > 1 { weekdays.remove(day) }
                            } else { weekdays.insert(day) }
                        } label: {
                            Text(calendar.veryShortWeekdaySymbols[day - 1]).font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(active ? Color.trailAmber : Color.surface.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(active ? store.sky.ground : Color.surface)
                        }
                        .disabled(active && weekdays.count == 1)
                        .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
        case .focus:
            VStack(alignment: .leading, spacing: 5) {
                Text(example).font(.subheadline)
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    let remaining = Int(ceil(timeLeft(at: clock.date)))
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.largeTitle.monospacedDigit()).accessibilityLabel("\(remaining) seconds")
                }
                Button(runningSince != nil ? "Pause" : seconds == 0 ? "Try again" : seconds < 120 ? "Resume" : "Try sprint") {
                    let now = Date.now
                    if runningSince == nil {
                        if seconds <= 0 { seconds = 120 }
                        runningSince = now
                    } else {
                        seconds = timeLeft(at: now)
                        runningSince = nil
                    }
                }.frame(minHeight: 44)
            }
        case .energy:
            VStack(alignment: .leading, spacing: 8) {
                Text("Energy · \(Int(energy)) / 10").font(.headline.monospacedDigit())
                Slider(value: $energy, in: 0...10, step: 1)
                    .accessibilityLabel("Practice energy").accessibilityValue("\(Int(energy)) out of ten")
            }
        }
    }

    private func capture() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        captured = title.isEmpty ? "Read a chapter" : String(title.prefix(140))
        draft = ""
        typing = false
    }

    private func practiceHour(_ title: String) -> some View {
        let selected = practiceTime == title
        return Button { practiceTime = title } label: {
            Text(selected ? title + "  ·  " + example : title).font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(selected ? store.sky.ground : Color.surface)
                .background(selected ? Color.trailAmber : Color.surface.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .dropDestination(for: String.self) { values, _ in
            guard values.contains("pulse-walkthrough-example") else { return false }
            practiceTime = title
            return true
        }
    }

    private func neighbor(_ distance: Int) -> Lesson? {
        let pages = Lesson.allCases
        guard let index = pages.firstIndex(of: lesson), pages.indices.contains(index + distance) else { return nil }
        return pages[index + distance]
    }

    private func select(_ page: Lesson) {
        typing = false
        seconds = timeLeft(at: .now)
        runningSince = nil
        withAnimation(reduced ? nil : .easeInOut(duration: 0.18)) { lesson = page }
    }

    private func timeLeft(at date: Date) -> TimeInterval {
        max(0, seconds - (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0))
    }
}
