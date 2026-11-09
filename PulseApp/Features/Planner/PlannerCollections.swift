import PulseEngine
import SwiftUI

enum PlanMode: String, CaseIterable {
    case timeline = "Timeline"
    case inbox = "Inbox"
    case all = "All items"
    case tomorrow = "Tomorrow"
    case week = "Week"
    case projects = "Projects"
    case routines = "Routines"
    case archive = "Archive"
}

struct WeekScheduledTasksKey: PreferenceKey {
    static var defaultValue: [Date: Set<UUID>] { [:] }
    static func reduce(value: inout [Date: Set<UUID>], nextValue: () -> [Date: Set<UUID>]) {
        value.merge(nextValue(), uniquingKeysWith: { $0.union($1) })
    }
}

struct WeeklyPlan: View {
    @Environment(Workspace.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dynamicTypeSize) private var type
    private struct ProjectionInput: Equatable {
        var generation: Int
        var energyRevision: Int
    }
    let tomorrow: Bool
    @Binding var panel: Panel?
    let onTiming: (UUID, Date) -> Void
    @Binding var selectedTimestamp: Double?
    let showWeek: () -> Void
    let startTask: (UUID) -> Void
    let deleteTask: (PlanTask) -> Void
    @Binding var drawerTask: UUID?
    @Binding var openWeekDay: Date?
    @State private var editingTools = false
    @State private var exactTime: WeekDayTimeSelection?
    @State private var days: [OutlookDay] = []
    @State private var remaining: [WeekRemainder] = []
    @State private var showRemaining = false
    private var selection: Date? {
        get { selectedTimestamp.map { Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: $0)) } }
        nonmutating set { selectedTimestamp = newValue?.timeIntervalSinceReferenceDate }
    }
    @Environment(WeekAgendaDrag.self) private var drag
    @State private var sectionFrames: [Date: CGRect] = [:]
    @State private var dayFrames: [Date: CGRect] = [:]
    @State private var dayStripFrame = CGRect.zero
    @State private var hourTargets: [Date: TimelineHourTargets] = [:]
    @State private var focusTargets: [AgendaFocusTarget] = []
    @State private var hoveredFocus: AgendaFocusTarget?
    @State private var selectedTask: UUID?
    @State private var message: String?
    @State private var messageDay: Date?
    @State private var moving = false
    @State private var alternative: (offer: TimeDropSuggestion, fromInbox: Bool)?

    private var scheduledIDs: [Date: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: days.map { day in
            (day.date, Set(day.blocks.compactMap { block -> UUID? in
                if case .task(let id) = block.kind { return id }
                return nil
            }))
        })
    }

    private func isDrawerTask(_ id: UUID) -> Bool {
        guard let task = store.timingTask(id), task.id != store.journal.active?.taskID,
              store.journal.tasks.contains(where: { $0.id == id }),
              task.plannedStart.map({ $0 < store.now }) ?? true else { return false }
        return task.isInboxOnly || !days.contains(where: { $0.blocks.contains { $0.kind == .task(id) } })
    }

    private var taskIcons: [UUID: TaskIcon] {
        var icons: [UUID: TaskIcon] = [:]
        for task in store.journal.tasks where task.icon != nil { icons[task.id] = task.icon }
        for day in days {
            for task in day.projectedTasks where task.icon != nil { icons[task.id] = task.icon }
        }
        return icons
    }

    private var movableIDs: Set<UUID> {
        Set(store.offeredTasks.filter {
            !$0.done && $0.archived != true && $0.id != store.journal.active?.taskID
        }.map(\.id)).union(days.flatMap(\.projectedTasks).map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let first = days.first {
                let tomorrowDay = days.dropFirst().first ?? first
                let detail = tomorrow ? tomorrowDay : days.first { $0.date == openWeekDay }
                let selected = detail ?? days.first { $0.date == selection } ?? first
                let movable = movableIDs
                let timeline = store.energyTimeline
                if tomorrow { dayStrip(selected: selected, movable: movable, timeline: timeline) }
                if let detail {
                    dayTimeline(detail, movable: movable, timeline: timeline)
                } else {
                    let icons = taskIcons
                    ForEach(days) { section in
                        dayAgenda(section, selected: selected, movable: movable, icons: icons, timeline: timeline)
                    }
                }
                if detail == nil, !remaining.isEmpty {
                    Button { showRemaining = true } label: {
                        HStack {
                            Label("Still to schedule", systemImage: "calendar.badge.clock")
                            Spacer()
                            Text("\(remaining.count)").monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                        }
                        .font(.subheadline).frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.surface)
                    .accessibilityLabel("Still to schedule")
                    .accessibilityValue(remaining.count == 1 ? "1 task" : "\(remaining.count) tasks")
                }
            } else {
                ProgressView().tint(.surface)
            }
        }
        .preference(key: WeekScheduledTasksKey.self, value: scheduledIDs)
        .onChange(of: drawerTask) { _, id in
            guard let id else { return }
            message = nil
            alternative = nil
            if let day = tomorrow ? days.dropFirst().first?.date : openWeekDay {
                drawerTask = nil
                if isDrawerTask(id) { pickTime(task: id, on: day, source: nil) }
            }
        }
        .onChange(of: openWeekDay) { editingTools = false }
        .onChange(of: tomorrow) { editingTools = false }
        .onPreferenceChange(AgendaFocusFrames.self) { focusTargets = $0 }
        .onAppear { bindDateDock() }
        .onChange(of: tomorrow) { bindDateDock() }
        .onDisappear {
            drag.end()
            drag.openDate = nil
            drag.previewDate = nil
            drag.dropOnDate = nil
        }
        .onChange(of: store.journalEpoch) {
            exactTime = nil
            openWeekDay = nil
            drawerTask = nil
            selectedTask = nil
            message = nil
            alternative = nil
            days = []
        }
        .task(id: ProjectionInput(generation: store.generation, energyRevision: store.healthController.revision)) {
            guard let result = await store.projectedWeek(), !Task.isCancelled else { return }
            if let openWeekDay, !result.days.contains(where: { $0.date == openWeekDay }) { self.openWeekDay = nil }
            days = result.days
            remaining = result.remaining
        }
        .sheet(item: $exactTime) { target in
            WeekDayTimePicker(target: target)
        }
        .sheet(isPresented: $showRemaining) {
            NavigationStack { WeekRemainderReview(remaining: $remaining) }
                .foregroundStyle(Color.journalInk).tint(.journalAccent)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: store.lastTimeMove) { previous, current in
            if let current {
                alternative = nil
                selectedTask = current.taskID
                messageDay = Calendar.current.startOfDay(for: current.start)
                select(Calendar.current.startOfDay(for: current.start), from: Calendar.current.startOfDay(for: current.sourceDay))
                message = current.title + (current.projected ? " planned for " : " moved to ") + current.start.formatted(.dateTime.weekday(.wide).hour().minute()) + "."
            } else if let previous, previous.taskID == selectedTask {
                if previous.wasRestored(in: store.journal.tasks) {
                    messageDay = Calendar.current.startOfDay(for: previous.sourceDay)
                    select(Calendar.current.startOfDay(for: previous.sourceDay), from: Calendar.current.startOfDay(for: previous.start))
                    message = "Previous timing restored."
                } else {
                    selectedTask = nil
                    message = nil
                }
            }
        }
        .sensoryFeedback(.selection, trigger: store.lastTimeMove?.id)
    }

    private func bindDateDock() {
        drag.openDate = { date in
            guard !tomorrow, days.contains(where: { $0.date == date }) else { return }
            tapDay(date, current: openWeekDay ?? selection ?? date)
        }
        drag.previewDate = { date in
            guard !tomorrow, !moving, !store.restoring, days.contains(where: { $0.date == date }),
                  openWeekDay != date || editingTools else { return }
            editingTools = false
            selection = date
            openWeekDay = date
            message = nil
            alternative = nil
            drag.jump = .init(date: date, animated: false)
        }
        drag.dropOnDate = { items, day in
            guard !tomorrow else { return false }
            return nativeDrop(items, onto: day, movable: movableIDs)
        }
    }

    private func dayStrip(selected: OutlookDay, movable: Set<UUID>, timeline: EnergyTimeline) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(days) { target in
                    let active = target.date == selected.date
                    let energy = timeline.daily(on: target.date)?.score
                    Button {
                        tapDay(target.date, current: selected.date)
                    } label: {
                        VStack(spacing: 2) {
                            Text(target.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                            Text(target.date.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                            Text(target.blocks.isEmpty ? "Open" : target.blocks.count == 1 ? "1 item" : "\(target.blocks.count) items")
                                .font(.caption2).monospacedDigit()
                        }
                        .fixedSize()
                        .frame(minWidth: 44, minHeight: 47)
                        .background(active ? Color.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(active ? store.sky.ground : Color.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 9).strokeBorder(
                                drag.highlighted == target.date ? Color.trailAmber : .clear, lineWidth: 2)
                        }
                    }
                    .accessibilityLabel(target.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .accessibilityValue(daySummary(target) + (energy.map { ", energy \(Int($0.rounded())) out of 10" } ?? ""))
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .dropDestination(for: String.self) { ids, _ in
                        nativeDrop(ids, onto: target.date, movable: movable)
                    } isTargeted: { highlight($0, date: target.date) }
                    .accessibilityIdentifier("plan-day-\(Int(target.date.timeIntervalSince1970))")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dayFrames[target.date] = $0 }
                }
            }
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dayStripFrame = $0 }
    }

    private func daySummary(_ day: OutlookDay) -> String {
        day.blocks.isEmpty ? "Open day" : "\(day.blocks.count) scheduled"
    }

    private func dayTimeline(_ day: OutlookDay, movable: Set<UUID>, timeline: EnergyTimeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !tomorrow {
                    Button("Week", systemImage: "chevron.backward") {
                        openWeekDay = nil
                        drag.jump = .init(date: day.date)
                    }
                    .accessibilityLabel("Back to week").accessibilityIdentifier("week-back-to-overview")
                }
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    editingTools.toggle()
                } label: {
                    Image(systemName: editingTools ? "calendar.day.timeline.left" : "slider.horizontal.2.square")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(editingTools ? "Back to day timeline" : "Edit time blocks and forecast")
                .accessibilityIdentifier("week-day-tools")
            }.id(WeekAgendaAnchor(day: day.date))
            if messageDay == day.date, let message, !moving { moveFeedback(message) }
            if editingTools {
                ForecastTimeline(now: store.now, blocks: day.blocks, energy: timeline.projectedHours(on: day.date, sleepWindow: store.plannedSleep, referenceWindow: store.sleepCalibrationWindow),
                                 selectedTaskID: selectedTask, onSelect: { onTiming($0, day.date) },
                                 onMove: { id, hour in move(id, from: day.date, to: day.date, hour: hour) },
                                 displayedDay: day.date, compactWeekDay: false, movableTaskIDs: movable,
                                 hoverDay: hover, dropOnDay: { id, point in
                                     resolveDrop(id, from: day.date, at: point)
                                 }, acceptWeeklyDrag: { items, hour in
                                     nativeDrop(items, onto: day.date, hour: hour, movable: movable)
                                 }, acceptFocusDrag: { items, block in
                                     placeNativeTask(items, in: block)
                                 }, checkingMove: moving, panel: $panel)
                    .onPreferenceChange(TimelineHourTargetsKey.self) { hourTargets[day.date] = $0 }
            } else {
                TaskDayTimeline(date: day.date, blocks: day.blocks, energy: timeline.projectedHours(on: day.date, sleepWindow: store.plannedSleep, referenceWindow: store.sleepCalibrationWindow),
                                panel: $panel, onMove: { id, source, time in
                                    guard Calendar.current.isDate(time, inSameDayAs: day.date) else { return }
                                    if let source {
                                        guard scheduledIDs[source]?.contains(id) == true else { return }
                                    } else {
                                        guard isDrawerTask(id) else { return }
                                    }
                                    drawerTask = nil
                                    move(id, from: source ?? day.date, to: day.date, hour: time,
                                         exact: true, fromInbox: source == nil)
                                }, onStart: startTask, onDelete: deleteTask,
                                week: .init(projectedTasks: day.projectedTasks,
                                            pickTime: { id in pickTime(task: id, on: day.date, source: day.date) },
                                            returnToDrawer: { id in _ = drag.returnToDrawer?(id, day.date) }))
                    .id(day.date)
            }
        }
    }

    private func dayAgenda(_ day: OutlookDay, selected: OutlookDay, movable: Set<UUID>, icons: [UUID: TaskIcon], timeline: EnergyTimeline) -> some View {
        let stamp = Int(day.date.timeIntervalSince1970)
        let active = selected.date == day.date
        return VStack(alignment: .leading, spacing: 5) {
            Button { tapDay(day.date, current: selected.date) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.title3.weight(.medium))
                        Spacer(minLength: 4)
                        if !day.blocks.isEmpty {
                            Text(daySummary(day)).font(.caption).foregroundStyle(Color.surface.opacity(0.78))
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    if active, let score = timeline.daily(on: day.date)?.score {
                        Text("Expected energy · " + score.formatted(.number.precision(.fractionLength(0...1))) + "/10")
                            .font(.caption).foregroundStyle(Color.surface.opacity(0.8))
                    }
                    if day.blocks.isEmpty {
                        Text("Nothing scheduled").font(.subheadline).foregroundStyle(Color.surface.opacity(0.76))
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityHint("Open the day timeline")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("week-agenda-\(stamp)")
            .padding(.top, 8).id(WeekAgendaAnchor(day: day.date))
            if messageDay == day.date, let message, !moving { moveFeedback(message) }
            ForEach(day.blocks) { block in
                agendaRow(block, on: day, movable: movable, icons: icons)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.surface.opacity(0.22)).frame(height: 0.7) }
        .background(drag.highlighted == day.date ? Color.trailAmber.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .overlay {
            if drawerTask != nil {
                Button { tapDay(day.date, current: selected.date) } label: {
                    Color.clear.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Choose a time on " + day.date.formatted(.dateTime.weekday(.wide)))
            }
        }
        .dropDestination(for: String.self) { ids, _ in nativeDrop(ids, onto: day.date, movable: movable) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames[day.date] = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("week-section-\(stamp)")
    }

    @ViewBuilder private func moveFeedback(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if store.undoableTimeMove(for: selectedTask) != nil, alternative == nil {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                }
                Text(message).fixedSize(horizontal: false, vertical: true)
            }.font(.footnote)
            if alternative == nil, let move = store.undoableTimeMove(for: selectedTask) {
                HStack(spacing: 18) {
                    Button("Set time") { pickTime(task: move.taskID, on: move.start, source: move.start) }
                        .accessibilityIdentifier("week-drop-set-time")
                    Button("Undo") { store.undoTimeMove(move) }
                        .accessibilityLabel("Undo time change")
                }.font(.footnote.bold()).frame(minHeight: 44)
            }
        }.foregroundStyle(Color.trailAmber)
        if let alternative {
            Button(alternative.offer.label(includeDay: true), systemImage: "clock.arrow.circlepath") {
                move(alternative.offer.taskID, from: alternative.offer.source, to: alternative.offer.start,
                     hour: alternative.offer.start, exact: true, fromInbox: alternative.fromInbox)
            }.font(.subheadline.weight(.medium)).foregroundStyle(Color.trailAmber).frame(minHeight: 44)
                .accessibilityIdentifier("week-drop-alternative")
        }
    }

    @ViewBuilder private func agendaRow(_ block: Block, on day: OutlookDay, movable: Set<UUID>, icons: [UUID: TaskIcon]) -> some View {
        switch block.kind {
        case .task(let id) where movable.contains(id):
            let saved = store.journal.tasks.first { $0.id == id }
            HStack(spacing: 0) {
                Button { onTiming(id, day.date) } label: {
                    row(block, icon: icons[id], projectedRoutine: day.projectedTasks.contains { $0.id == id })
                }
                .draggable(id.uuidString + "@" + String(Int(day.date.timeIntervalSince1970)))
                .modifier(TaskDeleteSwipe(enabled: saved != nil) {
                    if let saved { deleteTask(saved) }
                })
                .contextMenu {
                    Button("Set exact time", systemImage: "clock") { pickTime(task: id, on: day.date, source: day.date) }
                    if block.start <= Date.now, let candidate = store.skipCandidate(for: id) {
                        Button("Skip for today", systemImage: "forward.end") { panel = .taskSkip(candidate) }
                    }
                    Button("Return to Tasks", systemImage: "tray.and.arrow.down") { _ = drag.returnToDrawer?(id, day.date) }
                    if let saved {
                        Button("Start now", systemImage: "play.fill") { startTask(id) }
                        Button("Delete task", systemImage: "trash", role: .destructive) { deleteTask(saved) }
                    }
                }
                .accessibilityLabel(block.title)
                .accessibilityValue(block.start.formatted(date: .omitted, time: .shortened) + ", \(block.minutes) minutes")
                .accessibilityHint("Show available days and hours")
                .accessibilityAction(named: "Return to Tasks") { _ = drag.returnToDrawer?(id, day.date) }
                .accessibilityIdentifier("week-task-\(Int(day.date.timeIntervalSince1970))-\(id.uuidString)")
                if tomorrow {
                    AgendaTaskHandle(title: block.title, tap: { onTiming(id, day.date) }, destination: dropLabel, hover: hover, drop: { point in
                        _ = resolveDrop(id, from: day.date, at: point)
                    })
                } else {
                    Button { onTiming(id, day.date) } label: {
                        Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
                    }
                    .draggable(id.uuidString + "@" + String(Int(day.date.timeIntervalSince1970)))
                    .accessibilityLabel("Move " + block.title)
                    .accessibilityHint("Drag to a date, then onto its timeline")
                }
            }
        case .task(let id):
            row(block, icon: icons[id])
        case .timeBlock(let id, .focus) where block.end > store.now:
            Button { panel = .timeBlock(id) } label: { row(block) }
                .focusDropFrame(block)
                .background(hoveredFocus?.ruleID == id && hoveredFocus?.start == block.start ? Color.trailAmber.opacity(0.22) : .clear)
                .dropDestination(for: String.self) { items, _ in placeNativeTask(items, in: block) }
                .accessibilityIdentifier("agenda-focus-" + block.id)
        case .timeBlock(let id, _):
            Button { panel = .timeBlock(id) } label: { row(block) }
        case .fixed:
            PlanningEventButton(block: block, panel: $panel) { row(block) }
        case .rest:
            row(block)
        }
    }

    private func highlight(_ over: Bool, date: Date) {
        if over { drag.highlighted = date } else if drag.highlighted == date { drag.highlighted = nil }
    }

    private func hover(_ point: CGPoint?) {
        guard let point else { hoveredFocus = nil; drag.end(); return }
        drag.isOverDrawer = drag.drawerFrame.contains(point)
        if drag.isOverDrawer { hoveredFocus = nil; drag.highlighted = nil; return }
        hoveredFocus = focusAt(point)
        if drag.dates.isEmpty { drag.dates = days.map(\.date) }
        drag.highlighted = dayUnderFinger(point)
    }

    private func focusAt(_ point: CGPoint) -> AgendaFocusTarget? {
        guard dockDate(at: point) == nil else { return nil }
        return focusTargets.first { $0.frame.contains(point) }
    }

    private func dropLabel(at point: CGPoint) -> String? {
        if drag.drawerFrame.contains(point) { return "Tasks" }
        if let focus = focusAt(point) { return focus.title }
        if let hour = destinationHour(at: point) { return hour.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return dayUnderFinger(point)?.formatted(.dateTime.weekday(.wide))
    }

    private func destinationHour(at point: CGPoint) -> Date? {
        guard dockDate(at: point) == nil else { return nil }
        for day in days {
            if let hour = hourTargets[day.date]?.hour(at: point) { return hour }
        }
        return nil
    }

    private func dockDate(at point: CGPoint) -> Date? {
        let frames = tomorrow ? drag.frames : drag.pinnedFrames
        return frames.first { $0.value.contains(point) }?.key
    }

    private func dayUnderFinger(_ point: CGPoint) -> Date? {
        if let date = dockDate(at: point) { return date }
        if dayStripFrame.contains(point) { return days.first { dayFrames[$0.date]?.contains(point) == true }?.date }
        return days.first { (!tomorrow || $0.date == days.dropFirst().first?.date) && sectionFrames[$0.date]?.contains(point) == true }?.date
    }

    private func resolveDrop(_ id: UUID, from source: Date, at point: CGPoint) -> Bool {
        guard !moving else { return false }
        if drag.drawerFrame.contains(point) {
            let returned = drag.returnToDrawer?(id, source) ?? false
            drag.end()
            return returned
        }
        if let focus = focusAt(point), store.journal.tasks.contains(where: { $0.id == id }),
           let block = days.flatMap(\.blocks).first(where: { $0.kind == .timeBlock(focus.ruleID, .focus) && $0.start == focus.start }) {
            return place(id, in: block)
        }
        if let hour = destinationHour(at: point) {
            move(id, from: source, to: Calendar.current.startOfDay(for: hour), hour: hour)
            return true
        }
        guard let day = dayUnderFinger(point), day != source else { return false }
        move(id, from: source, to: day, hour: nil)
        return true
    }

    private func nativeDrop(_ ids: [String], onto target: Date, hour: Date? = nil, movable: Set<UUID>) -> Bool {
        if let raw = ids.first, let id = UUID(uuidString: raw), isDrawerTask(id), !moving {
            drag.end()
            drawerTask = nil
            move(id, from: target, to: target, hour: hour, fromInbox: true)
            return true
        }
        guard !moving, let parts = ids.first?.split(separator: "@"), parts.count == 2,
              let id = UUID(uuidString: String(parts[0])), movable.contains(id), let timestamp = Int(parts[1]),
              let source = days.first(where: { Int($0.date.timeIntervalSince1970) == timestamp }),
              source.blocks.contains(where: { $0.kind == .task(id) }),
              source.date != target || hour != nil else { return false }
        drag.end()
        move(id, from: source.date, to: target, hour: hour)
        return true
    }

    private func placeNativeTask(_ items: [String], in block: Block) -> Bool {
        guard let raw = items.first else { return false }
        let parts = raw.split(separator: "@")
        guard let key = parts.first, let id = UUID(uuidString: String(key)) else { return false }
        if parts.count == 1 {
            guard isDrawerTask(id) else { return false }
        } else {
            guard parts.count == 2, let stamp = Int(parts[1]),
                  days.contains(where: { Int($0.date.timeIntervalSince1970) == stamp && $0.blocks.contains { $0.kind == .task(id) } }) else { return false }
            // A projected routine has no saved task to attach yet. Keep its existing day-and-hour move.
            if !store.journal.tasks.contains(where: { $0.id == id }) {
                return nativeDrop(items, onto: Calendar.current.startOfDay(for: block.start), hour: block.start, movable: movableIDs)
            }
        }
        return place(id, in: block)
    }

    @discardableResult
    private func place(_ id: UUID, in block: Block) -> Bool {
        guard !moving, case .timeBlock(let ruleID, .focus) = block.kind,
              let rule = store.journal.timeBlocks?.first(where: { $0.id == ruleID }) else { return false }
        guard let day = Calendar.current.dateInterval(of: .day, for: block.start),
              rule.blocks(on: day).contains(block) else {
            messageDay = Calendar.current.startOfDay(for: block.start)
            selectedTask = nil
            alternative = nil
            message = "This focus block changed. Drop the task again."
            return true
        }
        moving = true
        alternative = nil
        drag.end()
        Task { @MainActor in
            defer { moving = false }
            messageDay = day.start
            do {
                let slot = try await store.assignTask(id, to: rule, on: block.start)
                selectedTask = id
                let name = store.timingTask(id)?.title ?? "Task"
                message = name + " · " + rule.displayTitle + " · " + slot.start.formatted(date: .omitted, time: .shortened) + " · \(slot.minutes) min"
            } catch {
                selectedTask = nil
                message = error.localizedDescription
            }
        }
        return true
    }

    private func row(_ block: Block, icon: TaskIcon? = nil, projectedRoutine: Bool = false) -> some View {
        let layout = type.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        return layout {
            Text(block.start, style: .time)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.trailAmber)
                .frame(minWidth: type.isAccessibilitySize ? nil : 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                TaskIconTitle(title: block.title, icon: icon).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                let details: String = {
                    let duration = "\(block.minutes) min"
                    if case .fixed(let id) = block.kind, store.calendarEvents.contains(where: { $0.id == id }) {
                        return duration + " · Apple Calendar"
                    }
                    if let task = store.focusTaskSummary(for: block) { return duration + " · " + task }
                    if case .timeBlock(_, let role) = block.kind, block.title != role.label {
                        return duration + " · " + role.label
                    }
                    return projectedRoutine ? duration + " · Projected routine" : duration
                }()
                Text(details).font(.caption).foregroundStyle(Color.surface.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 48).contentShape(Rectangle()).accessibilityElement(children: .combine)
        .transition(reduced ? .identity : .opacity)
    }

    private func tapDay(_ day: Date, current: Date) {
        if let id = drawerTask {
            drawerTask = nil
            guard isDrawerTask(id) else {
                messageDay = current
                message = "This task’s schedule has changed."
                return
            }
            pickTime(task: id, on: day, source: nil)
        } else {
            if !tomorrow || day != current { openWeekDay = day }
            select(day, from: current)
            drag.jump = .init(date: day)
            message = nil
            alternative = nil
        }
    }

    private func pickTime(task id: UUID, on date: Date, source: Date?) {
        guard !moving, let task = store.timingTask(id), let day = Calendar.current.dateInterval(of: .day, for: date) else { return }
        let existing = days.first { $0.date == day.start }?.blocks.first { $0.kind == .task(id) }?.start
        let usual = Calendar.current.date(bySettingHour: store.journal.planningStartHour ?? 9, minute: 0, second: 0, of: day.start) ?? day.start
        let fallback = max(usual, Date(timeIntervalSince1970: ceil(store.now.timeIntervalSince1970 / 900) * 900))
        exactTime = WeekDayTimeSelection(taskID: id, title: task.title, day: day, source: source,
                                         initial: existing ?? min(day.end.addingTimeInterval(-60), fallback), epoch: store.journalEpoch)
    }

    private func select(_ date: Date, from source: Date) {
        let alreadyViewing = openWeekDay == date || (tomorrow && days.dropFirst().first?.date == date)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = date
            if tomorrow && date != days.dropFirst().first?.date {
                openWeekDay = date
                showWeek()
            } else if openWeekDay != nil { openWeekDay = date }
        }
        if alreadyViewing { return }
        drag.jump = .init(date: date)
    }

    private func move(_ id: UUID, from source: Date, to destination: Date, hour: Date?, exact: Bool = false, fromInbox: Bool = false) {
        guard !moving else { return }
        moving = true
        selectedTask = nil
        message = nil
        alternative = nil
        let epoch = store.journalEpoch
        Task { @MainActor in
            defer { moving = false }
            if !store.calendarReadyForStart { _ = await store.refreshLiveCalendar() }
            guard store.journalEpoch == epoch else { return }
            guard store.calendarReadyForStart else {
                messageDay = tomorrow ? days.dropFirst().first?.date : destination
                message = "Calendar couldn’t update. Try scheduling again."
                return
            }
            if await store.moveWeekTask(id, day: destination, hour: hour, sourceDay: fromInbox ? nil : source, exactStart: exact),
               let task = store.timingTask(id), let start = task.plannedStart {
                selectedTask = id
                messageDay = Calendar.current.startOfDay(for: destination)
                select(Calendar.current.startOfDay(for: destination), from: source)
                message = task.title + (store.lastTimeMove?.projected == true ? " planned for " : " moved to ") + start.formatted(.dateTime.weekday(.wide).hour().minute()) + "."
            } else {
                let options = await store.weekPlacements(for: id, sourceDay: fromInbox ? nil : source)
                guard store.journalEpoch == epoch else { return }
                alternative = TimeDropSuggestion(for: store.timingTask(id), from: source, day: destination, hour: hour, options: options)
                    .map { ($0, fromInbox) }
                messageDay = tomorrow ? days.dropFirst().first?.date : destination
                message = store.blockedDropMessage(taskID: id, day: destination, hour: hour, exact: exact)
                if let messageDay { drag.jump = .init(date: messageDay) }
            }
        }
    }

}

struct GoalEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var goal: PersonalGoal
    @State private var milestone = ""
    var body: some View {
        Form {
            TextField("Goal or project", text: $goal.title)
            Section("Milestones") {
                ForEach($goal.milestones) { $m in
                    Toggle(isOn: $m.done) { TextField("Milestone", text: $m.title) }
                }
                .onDelete { goal.milestones.remove(atOffsets: $0) }
                HStack {
                    TextField("New milestone", text: $milestone)
                    Button("Add") {
                        goal.milestones.append(TaskStep(milestone))
                        milestone = ""
                    }.disabled(milestone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.formPaper().navigationTitle("Goal").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let name = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !milestone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        goal.milestones.append(TaskStep(milestone))
                    }
                    goal.title = name
                    store.change { j in
                        var list = j.goals ?? []
                        if let i = list.firstIndex(where: { $0.id == goal.id }) {
                            let old = list[i].title
                            for index in j.tasks.indices where j.tasks[index].project == old {
                                j.tasks[index].project = name
                            }
                            list[i] = goal
                        } else {
                            list.append(goal)
                        }
                        j.goals = list
                    }
                    dismiss()
                }.disabled(
                    goal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || goal.milestones.contains {
                            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        || store.journal.goals?.contains {
                            $0.id != goal.id
                                && $0.title.localizedCaseInsensitiveCompare(
                                    goal.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                        } == true)
            }
        }
    }
}

struct ProjectList: View {
    @Environment(Workspace.self) private var store
    @Binding var panel: Panel?
    @State private var editing: PersonalGoal?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                editing = PersonalGoal(title: "")
            } label: {
                Label("New project or goal", systemImage: "plus")
            }
            let names = Set(
                store.journal.tasks.compactMap(\.project) + (store.journal.goals ?? []).map(\.title)
            )
            .sorted()
            ForEach(names, id: \.self) { name in
                DisclosureGroup {
                    let goal = store.journal.goals?.first(where: { $0.title == name })
                    if let goal {
                        ForEach(goal.milestones) { m in
                            Label(m.title, systemImage: m.done ? "checkmark.circle.fill" : "circle").font(
                                .subheadline)
                        }
                    }
                    ForEach(store.journal.tasks.filter { $0.project == name && $0.archived != true }) { t in
                        Button {
                            panel = .task(t)
                        } label: {
                            Label { Text(t.title) } icon: {
                                TaskIconView(icon: t.done ? nil : t.icon, fallback: t.done ? "checkmark.circle" : t.category.symbol)
                            }
                        }.frame(minHeight: 44)
                    }
                    Button("Edit milestones") { editing = goal ?? PersonalGoal(title: name) }.frame(
                        minHeight: 44)
                } label: {
                    Text(name).font(.title3)
                }
            }
        }.tint(.surface).sheet(item: $editing) { g in
            NavigationStack { GoalEditor(goal: g) }.foregroundStyle(Color.journalInk).tint(.journalAccent)
        }
    }
}
