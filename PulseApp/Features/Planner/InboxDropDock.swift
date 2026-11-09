import PulseEngine
import SwiftUI

enum InboxScheduleTarget: Hashable {
    case day(Date)
    case focus(Date, UUID)

    var date: Date {
        switch self {
        case .day(let date): date
        case .focus(let start, _): Calendar.current.startOfDay(for: start)
        }
    }
}

private struct InboxTargetFrames: PreferenceKey {
    static var defaultValue: [InboxScheduleTarget: CGRect] { [:] }
    static func reduce(value: inout [InboxScheduleTarget: CGRect], nextValue: () -> [InboxScheduleTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@Observable @MainActor final class InboxDropSession {
    var day: Date?
    var choice: UUID?
    private(set) var highlighted: InboxScheduleTarget?
    @ObservationIgnored private var switchDay: Task<Void, Never>?
    var feedback: String?
    private(set) var receipt: UUID?
    private(set) var working = false
    var frames: [InboxScheduleTarget: CGRect] = [:]
    var dayViewport = CGRect.zero
    var focusViewport = CGRect.zero

    func target(at point: CGPoint) -> InboxScheduleTarget? {
        frames.first { target, frame in
            switch target {
            case .day:
                dayViewport.contains(point) && frame.contains(point)
            case .focus:
                focusViewport.contains(point) && target.date == day && frame.contains(point)
            }
        }?.key
    }

    func hover(_ target: InboxScheduleTarget?) {
        guard highlighted != target else { return }
        switchDay?.cancel()
        switchDay = nil
        highlighted = target
        // A route to a focus chip crosses the day strip. Switch only when the finger pauses there.
        guard case .day(let date) = target, date != day else { return }
        switchDay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, highlighted == target else { return }
            day = date
        }
    }

    func select(_ task: UUID) {
        guard !working else { return }
        feedback = nil
        choice = task
    }

    func place(_ taskID: UUID, at target: InboxScheduleTarget, in store: Workspace) -> Bool {
        guard !working, store.ready, !store.restoring, store.journal.active?.taskID != taskID,
              let task = store.journal.tasks.first(where: { $0.id == taskID && $0.belongsToInbox }) else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let limit = calendar.date(byAdding: .day, value: 7, to: today),
              target.date >= today && target.date < limit else { return false }
        working = true
        receipt = nil
        feedback = nil
        choice = nil
        hover(nil)
        day = target.date
        let epoch = store.journalEpoch
        let priorReceipt = store.lastTimeMove?.id
        Task {
            defer { working = false }
            if !store.calendarReadyForStart { _ = await store.refreshLiveCalendar() }
            guard store.journalEpoch == epoch else { return }
            guard store.calendarReadyForStart else {
                feedback = "Calendar couldn’t update. Try scheduling again."
                return
            }
            let start: Date
            let block: String?
            switch target {
            case .day(let date):
                guard await store.moveWeekTask(taskID, day: date, hour: nil),
                      let placed = store.timingTask(taskID)?.plannedStart else {
                    if store.journalEpoch == epoch { feedback = store.blockedDropMessage(taskID: taskID, day: date, hour: nil) }
                    return
                }
                start = placed
                block = nil
            case .focus(let date, let ruleID):
                guard let rule = store.journal.timeBlocks?.first(where: { $0.id == ruleID && $0.kind == .focus }),
                      let span = calendar.dateInterval(of: .day, for: date),
                      rule.blocks(on: span).contains(where: { $0.start == date }) else {
                    feedback = "This focus block has changed. Choose another time."
                    return
                }
                do {
                    let slot = try await store.assignTask(taskID, to: rule, on: date)
                    start = slot.start
                    block = rule.displayTitle + " · " + String(slot.minutes) + " min"
                } catch {
                    if store.journalEpoch == epoch { feedback = error.localizedDescription }
                    return
                }
            }
            guard store.journalEpoch == epoch else { return }
            let when = start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            feedback = task.title + " · " + when + (block.map { " · " + $0 } ?? "")
            if let move = store.undoableTimeMove(for: taskID), move.id != priorReceipt { receipt = move.id }
        }
        return true
    }
}

struct InboxDropDock: View {
    @Environment(Workspace.self) private var store
    let session: InboxDropSession
    let compare: (UUID) -> Void
    let editBlock: (UUID) -> Void

    private var today: Date { Calendar.current.startOfDay(for: store.now) }
    private var dates: [Date] { (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) } }
    private var day: Date { session.day.flatMap { dates.contains($0) ? $0 : nil } ?? today }
    private var choice: PlanTask? {
        store.journal.tasks.first { $0.id == session.choice && $0.belongsToInbox }
    }

    private struct FocusOpening: Identifiable {
        let rule: WeeklyTimeBlock
        let range: DateInterval
        var id: InboxScheduleTarget { .focus(range.start, rule.id) }
    }

    private func openings(on date: Date) -> [FocusOpening] {
        guard let span = Calendar.current.dateInterval(of: .day, for: date) else { return [] }
        return (store.journal.timeBlocks ?? []).filter { $0.kind == .focus }.flatMap { rule in
            rule.blocks(on: span).filter { $0.end > store.now }.map { block in
                FocusOpening(rule: rule, range: DateInterval(start: block.start, end: block.end))
            }
        }.sorted { $0.range.start < $1.range.start }
    }

    var body: some View {
        let week = Dictionary(uniqueKeysWithValues: dates.map { ($0, openings(on: $0)) })
        let focus = week[day] ?? []
        let hasFocus = week.values.contains { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 3) {
            if let choice {
                HStack {
                    Text("Schedule " + choice.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer()
                    Button("Cancel") { session.choice = nil }.frame(minHeight: 44)
                }
            } else if session.working {
                ProgressView("Finding a time").font(.subheadline)
            } else if let message = session.feedback {
                HStack {
                    Text(message).font(.subheadline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inbox-drop-result")
                    Spacer(minLength: 6)
                    if let move = store.lastTimeMove, move.id == session.receipt,
                       store.undoableTimeMove(for: move.taskID) != nil {
                        Button("Undo") {
                            if store.undoTimeMove(move) { session.feedback = "Previous timing restored." }
                        }.frame(minHeight: 44).accessibilityIdentifier("inbox-drop-undo")
                    }
                    Button { session.feedback = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Dismiss scheduling message")
                }
            } else {
                Text(hasFocus ? "Drag to a day or focus block" : "Drag to a day").font(.subheadline.weight(.semibold))
                    .padding(.vertical, 3)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(dates, id: \.self) { date in
                        let blockCount = week[date]?.count ?? 0
                        let selected = date == day
                        dropTarget(.day(date)) {
                            Button {
                                session.day = date
                                session.feedback = nil
                            } label: {
                                VStack(spacing: 2) {
                                    Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                                    Text(date.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                                    if hasFocus {
                                        Circle().fill(blockCount > 0 ? (selected ? store.sky.ground : Color.trailAmber) : .clear)
                                            .frame(width: 4, height: 4).accessibilityHidden(true)
                                    }
                                }
                                .frame(minWidth: 44, minHeight: 47)
                                .foregroundStyle(selected ? store.sky.ground : Color.surface)
                                .background(selected ? Color.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .accessibilityValue(blockCount == 1 ? "1 focus block" : "\(blockCount) focus blocks")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("inbox-day-\(Int(date.timeIntervalSince1970))")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.dayViewport = $0 }

            if hasFocus || choice != nil {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        if let choice {
                            Button("Schedule on " + day.formatted(.dateTime.weekday(.abbreviated))) {
                                _ = session.place(choice.id, at: .day(day), in: store)
                            }.frame(minHeight: 44)
                            .accessibilityIdentifier("inbox-choose-day")
                        }
                        if focus.isEmpty && choice == nil {
                            Text("Tap a marked day for its focus blocks.")
                                .font(.caption).foregroundStyle(Color.surface.opacity(0.75)).frame(minHeight: 44)
                        }
                        ForEach(focus) { slot in
                            let target = slot.id
                            dropTarget(target) {
                                Button {
                                    if let choice { _ = session.place(choice.id, at: target, in: store) }
                                    else { editBlock(slot.rule.id) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "scope")
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(slot.rule.displayTitle).font(.subheadline.weight(.medium))
                                            Text(slot.range.start.formatted(date: .omitted, time: .shortened) + " to " +
                                                 slot.range.end.formatted(date: .omitted, time: .shortened))
                                                .font(.caption.monospacedDigit())
                                        }
                                    }
                                    .padding(.horizontal, 9).frame(minHeight: 44)
                                    .foregroundStyle(Color.surface)
                                    .background(Color.surface.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .accessibilityHint(choice == nil ? "Edit focus block" : "Schedule the selected task in this focus block")
                                .accessibilityIdentifier("inbox-focus-" + slot.rule.id.uuidString)
                            }
                        }
                        if let choice {
                            Button("Compare times") { session.choice = nil; compare(choice.id) }
                                .frame(minHeight: 44)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.focusViewport = $0 }
                .onDisappear { session.focusViewport = .zero }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        .background(store.sky.ground)
        .overlay(alignment: .top) { Rectangle().fill(Color.surface.opacity(0.22)).frame(height: 0.7) }
        .buttonStyle(.plain).tint(.trailAmber)
        .onAppear { session.day = day }
        .onDisappear { session.hover(nil) }
        .onChange(of: today) { session.day = day }
        .onPreferenceChange(InboxTargetFrames.self) { session.frames = $0 }
    }

    private func dropTarget<Content: View>(_ target: InboxScheduleTarget, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: InboxTargetFrames.self, value: [target: geometry.frame(in: .global)])
                }
            }
            .overlay {
                if session.highlighted == target {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.trailAmber, lineWidth: 3).allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                return session.place(id, at: target, in: store)
            } isTargeted: { over in
                if over { session.hover(target) } else if session.highlighted == target { session.hover(nil) }
            }
    }
}
