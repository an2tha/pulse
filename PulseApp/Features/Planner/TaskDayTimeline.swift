import PulseEngine
import SwiftUI
import UniformTypeIdentifiers

/// All placements share the same local-day clock, including hours without planned work.
struct TaskDayTimeline: View {
    let date: Date
    let blocks: [Block]
    let energy: [EnergyPoint]
    @Binding var panel: Panel?
    let onMove: (UUID, Date?, Date) -> Void
    let onStart: (UUID) -> Void
    let onDelete: (PlanTask) -> Void
    struct WeekContext {
        let projectedTasks: [PlanTask]
        let pickTime: (UUID) -> Void
        let returnToDrawer: (UUID) -> Void
    }
    var week: WeekContext?

    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    @ScaledMetric(relativeTo: .body) private var hourHeight = 86.0
    @ScaledMetric(relativeTo: .caption) private var clockWidth = 65.0
    @State private var axisHeight: CGFloat = 0
    @State private var wideEnoughForLanes = false
    @State private var showEarlier = false
    @State private var hover: Date?
    @State private var editingSleep = false
    @State private var previewSleep: PlannedSleepWindow?
    @State private var energyEdit: ForecastEditSelection?

    @State private var resizing: TimelineDurationTarget?
    @State private var resizeMinutes = 0
    @State private var chosenGrip: String?
    @State private var editingDuration: TimelineDurationTarget?
    @State private var savingResize = false
    @State private var resizeProblem: String?
    @State private var savedEnd: Date?
    @State private var resizeSuccess = 0

    private struct Entry: Identifiable {
        enum Content {
            case task(PlanTask)
            case event(Commitment, Block?)
            case rule(Block)
            case recorded(String)
        }
        let id: String
        let start: Date
        let end: Date
        let content: Content
        var scheduledSlice = false

        var isTask: Bool {
            if case .task = content { return true }
            return false
        }
    }

    private var day: DateInterval { Calendar.current.dateInterval(of: .day, for: date)! }

    private func entries(in day: DateInterval) -> [Entry] {
        let tasks = Dictionary((store.offeredTasks + (week?.projectedTasks ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Entry] = []
        var plottedTasks = Set<UUID>()
        var events: [UUID: [Block]] = [:]
        for block in blocks {
            switch block.kind {
            case .task(let id):
                if let task = tasks[id] {
                    plottedTasks.insert(id)
                    result.append(Entry(id: block.id + "-\(block.start.timeIntervalSinceReferenceDate)", start: block.start, end: block.end, content: .task(task), scheduledSlice: true))
                }
            case .fixed(let id):
                events[id, default: []].append(block)
            case .timeBlock(_, .boost), .rest:
                result.append(Entry(id: block.id, start: block.start, end: block.end, content: .rule(block)))
            case .timeBlock: break
            }
        }
        for event in store.planningEvents {
            for interval in event.intervals(on: date, calendar: .current) {
                let block = events[event.id]?.first { $0.start == interval.start }
                result.append(Entry(id: "\(event.id)-\(interval.start.timeIntervalSinceReferenceDate)",
                                    start: interval.start, end: interval.end, content: .event(event, block)))
            }
        }
        for rule in store.journal.timeBlocks ?? [] {
            for block in rule.blocks(on: day) {
                result.append(Entry(id: block.id, start: block.start, end: block.end, content: .rule(block)))
                guard rule.kind == .focus else { continue }
                for task in store.tasksAssigned(to: rule.id, during: DateInterval(start: block.start, end: block.end)) {
                    guard let start = task.plannedStart, plottedTasks.insert(task.id).inserted else { continue }
                    result.append(Entry(id: task.id.uuidString, start: start,
                                        end: min(block.end, start.addingTimeInterval(Double(task.minutes) * 60)),
                                        content: .task(task)))
                }
            }
        }
        for record in store.journal.sessions where record.seconds(in: day) > 0 {
            if let periods = record.periods {
                for (index, period) in periods.enumerated() where period.seconds(in: day) > 0 {
                    result.append(Entry(id: "\(record.id)-\(index)", start: period.start,
                                        end: period.start.addingTimeInterval(period.seconds), content: .recorded(record.title)))
                }
            } else {
                result.append(Entry(id: record.id.uuidString + "-session", start: record.start,
                                    end: record.start.addingTimeInterval(record.seconds), content: .recorded(record.title)))
            }
        }
        return result.filter { $0.start < day.end && $0.end > day.start }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.isTask != $1.isTask { return $0.isTask }
                return $0.id < $1.id
            }
    }

    private func openingTime(in window: DateInterval, earliest: Date?) -> Date {
        guard window.start > store.now else { return store.now }
        let usual = Calendar.current.date(bySettingHour: store.journal.planningStartHour ?? 9, minute: 0,
                                          second: 0, of: window.start) ?? window.start
        return min(usual, earliest ?? usual)
    }

    private func payload(for task: PlanTask) -> String {
        guard week != nil else { return task.id.uuidString }
        return task.id.uuidString + "@" + String(Int(day.start.timeIntervalSince1970))
    }

    var body: some View {
        let window = day
        let sleep = previewSleep ?? store.plannedSleep
        let energy = store.energyTimeline.projectedHours(on: date, sleepWindow: sleep, referenceWindow: store.sleepCalibrationWindow)
        let hours = stride(from: window.start.timeIntervalSinceReferenceDate, to: window.end.timeIntervalSinceReferenceDate,
                           by: 3600).map(Date.init(timeIntervalSinceReferenceDate:))
        let landmarks = EnergyTurningPoint.find(in: energy)
        let entries = entries(in: window)
        let opening = openingTime(in: window, earliest: entries.first?.start)
        let first = hours.last(where: { $0 <= opening }) ?? window.start
        let visible = showEarlier ? hours : hours.filter { $0 >= first }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(energy.allSatisfy { $0.source == .rhythm && $0.supportDays == 0 } ? "Sleep rhythm estimate" : "Estimated energy", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.trailAmber)
                Spacer()
                Button("Sleep window", systemImage: "moon.stars") { editingSleep = true }
                    .font(.subheadline).frame(minHeight: 44)
            }.foregroundStyle(Color.surface)
            let upcoming = landmarks.filter { $0.id.addingTimeInterval(3600) > store.now }
            let wakingPeaks = upcoming.filter { marker in
                guard marker.kind == .peak else { return false }
                let components = Calendar.current.dateComponents([.hour, .minute], from: marker.id)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                return (minute - sleep.bedtime + 1440) % 1440 >= sleep.minutes
            }
            let peak = wakingPeaks.first
            let dip = upcoming.first { $0.kind == .dip }
            if peak != nil || dip != nil {
                let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
                    : AnyLayout(HStackLayout(spacing: 16))
                layout {
                    if let peak {
                        Label("Next peak · \(clock(peak.id))", systemImage: "arrow.up.right")
                            .foregroundStyle(TimelineEnergyRibbon.high)
                            .accessibilityHint("Estimated high energy for focused work")
                    }
                    if let dip {
                        Label("Next dip · \(clock(dip.id))", systemImage: "arrow.down.right")
                            .foregroundStyle(TimelineEnergyRibbon.low)
                    }
                }
                .font(.caption.weight(.semibold)).padding(.bottom, 10)
            }
            if first > window.start {
                Button(showEarlier ? "Hide earlier hours" : "Show earlier hours",
                       systemImage: showEarlier ? "chevron.up" : "clock.arrow.circlepath") {
                    showEarlier.toggle()
                }
                .font(.subheadline).foregroundStyle(Color.surface.opacity(0.85)).frame(minHeight: 44)
            }
            if let firstHour = visible.first {
                let visibleEntries = entries.filter { $0.end > firstHour }
                let groups = displayGroups(visibleEntries, firstHour: firstHour)
                let gutter = min(clockWidth, type.isAccessibilitySize ? 100 : 74) + 10
                DayScaleLayout(start: firstHour, end: window.end, baseUnit: hourHeight, gutter: gutter,
                               allowLanes: wideEnoughForLanes && !type.isAccessibilitySize) {
                    GeometryReader { geometry in
                        let clockHeight = geometry.size.height
                        let unit = clockHeight / window.end.timeIntervalSince(firstHour) * 3600
                        VStack(spacing: 0) {
                            ForEach(visible, id: \.self) { hour in
                                let end = min(window.end, hour.addingTimeInterval(3600))
                                let active = visibleEntries.filter { $0.start < end && $0.end > hour }
                                hourRow(hour, end: end, active: active, energy: energy)
                                    .frame(height: end.timeIntervalSince(hour) / 3600 * unit)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { axisHeight = $0 }
                    }
                    ForEach(groups) { group in
                        ViewThatFits(in: .vertical) {
                            if group.entries.count == 1, let entry = group.entries.first {
                                label(entry).fixedSize(horizontal: false, vertical: true)
                            }
                            groupMenu(group)
                        }
                        .layoutValue(key: EntryStart.self, value: group.id)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if axisHeight > 0 {
                        let targets = visibleEntries.compactMap(durationTarget)
                        endHandles(for: targets, firstHour: firstHour, gutter: gutter)
                    }
                }
                .onGeometryChange(for: Bool.self) { ($0.size.width - gutter - 5) / 2 >= 116 } action: { wideEnoughForLanes = $0 }
                .padding(.leading, 56)
                .background(alignment: .topLeading) {
                    if axisHeight > 0 {
                        GeometryReader { bounds in
                            // Behind the schedule so tasks, clock labels and drag handles
                            // keep their contrast and their full interaction regions.
                            TimelineEnergyRibbon(energy: energy, start: firstHour, end: window.end)
                                .frame(width: bounds.size.width * 0.78, height: axisHeight)
                        }.allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if axisHeight > 0 {
                        SleepPlanTimeline(start: firstHour, end: window.end, energy: energy, landmarks: landmarks, preview: $previewSleep, editing: $editingSleep)
                            .frame(width: 54, height: axisHeight)
                    }
                }
                .padding(.leading, -16)
                .contentShape(Rectangle())
                .onDrop(of: [.plainText], delegate: DayTaskDrop(start: firstHour, end: window.end, now: store.now,
                                                                height: axisHeight, stepMinutes: week == nil ? 15 : 1,
                                                                hover: $hover) { id, source, time in
                    guard store.timingTask(id) != nil, id != store.journal.active?.taskID else { return }
                    guard week != nil || source == nil else { return }
                    onMove(id, source, time)
                })
            }
        }
        .sheet(item: $energyEdit) { ForecastExpectationEditor(selection: $0) }
        .sheet(item: $editingDuration) { target in
            TimelineDurationEditor(target: target, dayEnd: day.end) { minutes in
                try await commitResize(target, minutes: minutes)
            }
        }
        .sensoryFeedback(.success, trigger: resizeSuccess)
        .task(id: resizeSuccess) {
            guard savedEnd != nil else { return }
            do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
            savedEnd = nil
        }
        .alert("Couldn’t resize task", isPresented: Binding(get: { resizeProblem != nil }, set: { if !$0 { resizeProblem = nil } })) {
            Button("OK") {}
        } message: { Text(resizeProblem ?? "") }
        .onChange(of: day.start) { _, _ in showEarlier = false; hover = nil; resizing = nil; chosenGrip = nil; savedEnd = nil }
        .onChange(of: store.journalEpoch) { resizing = nil; chosenGrip = nil; editingDuration = nil; savedEnd = nil }
        .onDisappear { resizing = nil; previewSleep = nil }
        .accessibilityIdentifier("task-day-timeline")
    }

    private func durationTarget(_ entry: Entry) -> TimelineDurationTarget? {
        guard entry.scheduledSlice, case .task(let task) = entry.content, !task.done, task.archived != true,
              entry.start.addingTimeInterval(60) > store.now,
              task.id != store.journal.active?.taskID, entry.end > store.now,
              entry.start < entry.end else { return nil }
        return TimelineDurationTarget(id: entry.id, taskID: task.id, title: task.title, start: entry.start, end: entry.end)
    }

    private struct GripGroup: Identifiable {
        let id: String
        var members: [TimelineDurationTarget]
    }

    /// Nearby end handles share a selector so that each task still has a distinct drag target.
    private func gripGroups(_ targets: [TimelineDurationTarget], secondsPerPoint: Double) -> [GripGroup] {
        var result: [GripGroup] = []
        for target in targets.sorted(by: { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }) {
            if let first = result.last?.members.first, target.end.timeIntervalSince(first.end) < 16 * secondsPerPoint {
                result[result.count - 1].members.append(target)
            } else {
                result.append(GripGroup(id: target.id, members: [target]))
            }
        }
        return result
    }

    private func endHandles(for targets: [TimelineDurationTarget], firstHour: Date, gutter: CGFloat) -> some View {
        let secondsPerPoint = day.end.timeIntervalSince(firstHour) / axisHeight
        let groups = gripGroups(targets, secondsPerPoint: secondsPerPoint)
        let selectedTargets = groups.map { group in group.members.first { $0.id == chosenGrip } ?? group.members[0] }
        return ZStack(alignment: .topLeading) {
            if let target = resizing {
                let end = target.start.addingTimeInterval(Double(resizeMinutes) * 60)
                let y = end.timeIntervalSince(firstHour) / secondsPerPoint
                let startY = max(0, target.start.timeIntervalSince(firstHour) / secondsPerPoint)
                Rectangle().fill(Color.trailAmber).frame(width: 3, height: max(1, y - startY))
                    .offset(x: gutter - 8, y: startY).allowsHitTesting(false)
                Rectangle().fill(Color.trailAmber).frame(height: 1).offset(y: y).allowsHitTesting(false)
                Text("\(resizeMinutes) min · \(clock(end))").font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .foregroundStyle(Color.journalInk).background(Color.trailAmber, in: Capsule())
                    .fixedSize().offset(x: gutter + 2, y: max(0, y - 25)).allowsHitTesting(false)
            }
            if let savedEnd, resizing == nil, firstHour < savedEnd, savedEnd <= day.end {
                Image(systemName: "checkmark.circle.fill").font(.subheadline)
                    .foregroundStyle(Color.trailAmber).background(store.sky.ground, in: Circle())
                    .position(x: gutter + 10, y: savedEnd.timeIntervalSince(firstHour) / secondsPerPoint)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                let target = selectedTargets[index]
                let before = index > 0 ? target.end.timeIntervalSince(selectedTargets[index - 1].end) : .infinity
                let after = index + 1 < groups.count ? selectedTargets[index + 1].end.timeIntervalSince(target.end) : .infinity
                let hitHeight = min(44, max(16, min(before, after) / secondsPerPoint))
                let changesThis = resizing?.id == target.id
                let end = changesThis ? target.start.addingTimeInterval(Double(resizeMinutes) * 60) : target.end
                let y = end.timeIntervalSince(firstHour) / secondsPerPoint
                Group {
                    if group.members.count == 1 || chosenGrip == target.id {
                        resizeGrip(target, secondsPerPoint: secondsPerPoint, hitHeight: hitHeight)
                    } else {
                        Menu {
                            ForEach(group.members) { member in
                                Button(member.title + " · " + clock(member.end)) { chosenGrip = member.id }
                            }
                        } label: { gripIcon(multiple: true, hitHeight: hitHeight) }
                        .accessibilityLabel("Choose a task to resize")
                    }
                }
                .frame(width: 44, height: hitHeight)
                .position(x: gutter - 22, y: y)
                .opacity(resizing == nil || changesThis ? 1 : 0)
                .allowsHitTesting(resizing == nil || changesThis)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func gripIcon(multiple: Bool = false, hitHeight: CGFloat) -> some View {
        HStack(spacing: 1) {
            Image(systemName: multiple ? "rectangle.stack" : "arrow.up.and.down")
                .font(.system(size: 10, weight: .semibold))
            Capsule().frame(width: 13, height: 3)
        }
        .foregroundStyle(Color.trailAmber)
        .padding(.horizontal, 3).padding(.vertical, 3)
        .background(store.sky.ground, in: Capsule())
        .frame(width: 44, height: hitHeight, alignment: .trailing)
        .contentShape(Rectangle())
    }

    private func resizeGrip(_ target: TimelineDurationTarget, secondsPerPoint: Double, hitHeight: CGFloat) -> some View {
        gripIcon(hitHeight: hitHeight)
            .overlay {
                TimelineDurationHandle { translation in
                    guard !savingResize else { return }
                    resizing = target
                    resizeMinutes = target.newMinutes(translation: translation, secondsPerPoint: secondsPerPoint, midnight: day.end)
                } finish: { translation in
                    resizing = nil
                    chosenGrip = nil
                    guard let translation else { return }
                    saveResize(target, minutes: target.newMinutes(translation: translation, secondsPerPoint: secondsPerPoint, midnight: day.end))
                } tap: {
                    editingDuration = target
                    chosenGrip = nil
                }.accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize " + target.title)
            .accessibilityValue("\(resizing?.id == target.id ? resizeMinutes : target.minutes) minutes")
            .accessibilityHint("Drag up to shorten or down to extend. Double tap to enter minutes.")
            .accessibilityIdentifier("timeline-duration-" + target.taskID.uuidString)
            .accessibilityAction { editingDuration = target }
            .accessibilityAdjustableAction { direction in
                let minutes: Int
                switch direction {
                case .increment: minutes = min(target.maxMinutes(before: day.end), target.minutes + 1)
                case .decrement: minutes = max(1, target.minutes - 1)
                @unknown default: return
                }
                saveResize(target, minutes: minutes)
            }
    }

    private func saveResize(_ target: TimelineDurationTarget, minutes: Int) {
        guard !savingResize, minutes != target.minutes else { return }
        savingResize = true
        Task { @MainActor in
            defer { savingResize = false }
            do { try await commitResize(target, minutes: minutes) }
            catch is CancellationError { }
            catch { resizeProblem = error.localizedDescription }
        }
    }

    @MainActor private func commitResize(_ target: TimelineDurationTarget, minutes: Int) async throws {
        guard minutes != target.minutes else { return }
        try await store.resizeTimelineTask(target.taskID, start: target.start, end: target.end, to: minutes)
        savedEnd = target.start.addingTimeInterval(Double(minutes) * 60)
        resizeSuccess += 1
        AccessibilityNotification.Announcement("\(target.title), \(minutes) minutes").post()
    }

    private struct DisplayGroup: Identifiable {
        let id: Date
        var entries: [Entry]
    }

    private func displayGroups(_ entries: [Entry], firstHour: Date) -> [DisplayGroup] {
        var groups: [DisplayGroup] = []
        var free = Array(repeating: Date.distantPast, count: wideEnoughForLanes && !type.isAccessibilitySize ? 2 : 1)
        let minimumSpacing = (DayScaleLayout.compactHeight(hourHeight) + 4) / (2 * hourHeight) * 3600
        for entry in entries {
            let minute = Calendar.current.dateInterval(of: .minute, for: entry.start)?.start ?? entry.start
            let start = max(minute, firstHour)
            if groups.last?.id != start, let lane = free.firstIndex(where: { $0 <= start }) {
                groups.append(DisplayGroup(id: start, entries: [entry]))
                free[lane] = start.addingTimeInterval(minimumSpacing)
            } else {
                groups[groups.count - 1].entries.append(entry)
            }
        }
        return groups
    }

    private func title(of entry: Entry) -> String {
        switch entry.content {
        case .task(let task): task.title
        case .event(let event, _): event.title
        case .rule(let block): block.title
        case .recorded(let title): title
        }
    }

    private func groupMenu(_ group: DisplayGroup) -> some View {
        let first = group.entries[0]
        let menu = Menu {
            ForEach(group.entries) { entry in
                switch entry.content {
                case .task(let task):
                    Menu(clock(entry.start) + " · " + task.title) {
                        taskActions(task, entry: entry)
                    }
                case .rule(let block):
                    if case .timeBlock(let id, _) = block.kind {
                        Button(clock(entry.start) + " · " + block.title) { panel = .timeBlock(id) }
                    } else { Text(timeRange(entry) + " · " + block.title) }
                case .event(let event, let block):
                    if let block {
                        PlanningEventButton(block: block, panel: $panel, editOnTap: store.journal.events.first { $0.id == event.id }) {
                            Text(clock(entry.start) + " · " + event.title)
                        }
                    } else if store.journal.events.contains(where: { $0.id == event.id }) {
                        Button(clock(entry.start) + " · " + event.title) { panel = .commitment(event) }
                    } else { Text(timeRange(entry) + " · " + event.title) }
                case .recorded(let title):
                    Text(timeRange(entry) + " · " + title)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title(of: first)).lineLimit(1)
                if group.entries.count > 1 { Text("+\(group.entries.count - 1)").monospacedDigit().fixedSize() }
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .foregroundStyle(group.entries.contains(where: \.isTask) ? Color.trailAmber : Color.surface)
            .contentShape(Rectangle())
        }
        return Group {
            if group.entries.count == 1, case .task(let task) = first.content, task.id != store.journal.active?.taskID {
                menu.draggable(payload(for: task))
            } else { menu }
        }
        .accessibilityLabel(group.entries.count == 1 ? title(of: first) : "\(group.entries.count) scheduled items at \(clock(first.start))")
    }

    private func hourRow(_ hour: Date, end: Date, active: [Entry], energy: [EnergyPoint]) -> some View {
        let score = energy.first { $0.date >= hour && $0.date < end }
        let targeted = hover.flatMap { $0 >= hour && $0 < end ? $0 : nil }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(clock(hour)).font(.caption.monospacedDigit().weight(.semibold))
                    .accessibilityIdentifier("day-hour-\(Int(hour.timeIntervalSince1970))")
                    .foregroundStyle(Color.surface)
                if let score {
                    Label(score.score.formatted(.number.precision(.fractionLength(0))), systemImage: "waveform.path")
                        .font(.caption2).foregroundStyle(Color.trailAmber)
                        .accessibilityLabel("\(score.source == .rhythm ? "Sleep rhythm estimate" : "Energy") \(Int(score.score.rounded())) out of ten")
                }
            }
            .frame(width: min(clockWidth, type.isAccessibilitySize ? 100 : 74), alignment: .leading)
            .padding(.top, 8)
            .contextMenu {
                if hour > store.now {
                    Button("Adjust expected energy", systemImage: "pencil") {
                        energyEdit = ForecastEditSelection(date: hour, scope: .hour)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.surface.opacity(0.19)).frame(height: 0.7).allowsHitTesting(false)
        }
        .background {
            let rail = min(clockWidth, type.isAccessibilitySize ? 100 : 74) + 2
            Canvas { context, size in
                let seconds = end.timeIntervalSince(hour)
                let available = size.height
                for entry in active {
                    let y = max(0, entry.start.timeIntervalSince(hour)) / seconds * available
                    let bottom = min(seconds, entry.end.timeIntervalSince(hour)) / seconds * available
                    let line = CGRect(x: rail, y: y, width: entry.isTask ? 3 : 1, height: max(1, bottom - y))
                    context.fill(Path(line), with: .color(entry.isTask ? .trailAmber : .surface.opacity(0.48)))
                }
                if store.now >= hour && store.now < end {
                    let y = store.now.timeIntervalSince(hour) / seconds * available
                    context.fill(Path(ellipseIn: CGRect(x: rail - 2, y: y - 3, width: 6, height: 6)), with: .color(.trailAmber))
                }
                if let targeted {
                    let y = targeted.timeIntervalSince(hour) / seconds * available
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(.trailAmber))
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if let targeted {
                GeometryReader { geometry in
                    let fraction = targeted.timeIntervalSince(hour) / end.timeIntervalSince(hour)
                    Text(clock(targeted)).font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.journalInk)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.trailAmber, in: Capsule())
                        .fixedSize()
                        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                        .offset(y: geometry.size.height * fraction)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func label(_ entry: Entry) -> some View {
        switch entry.content {
        case .task(let task):
            HStack(spacing: 6) {
                if week?.projectedTasks.contains(where: { $0.id == task.id }) != true {
                    Button { store.completeFromPlan(task) } label: {
                        Image(systemName: store.needsCompletionPhoto(for: task) ? "camera.circle" : "circle").font(.body)
                            .foregroundStyle(Color.trailAmber).frame(minWidth: 32, minHeight: 44)
                    }.accessibilityLabel("Complete \(task.title)")
                    .accessibilityHint(store.needsCompletionPhoto(for: task) ? "Add a completion photo" : "Marks the task complete")
                    .disabled(store.journal.active?.taskID == task.id)
                }
                let button = Button {
                    if let week { week.pickTime(task.id) } else { panel = .task(task) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        TaskIconTitle(title: task.title, icon: task.icon).font(.headline.weight(.medium))
                        Text(timeRange(entry)).font(.caption.monospacedDigit()).foregroundStyle(Color.surface.opacity(0.78))
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .accessibilityLabel(task.title)
                .accessibilityValue(timeRange(entry))
                .accessibilityIdentifier(week == nil ? "day-axis-task-" + task.id.uuidString : "week-task-\(Int(day.start.timeIntervalSince1970))-\(task.id.uuidString)")
                if task.id == store.journal.active?.taskID { button }
                else {
                    button.draggable(payload(for: task))
                        .contextMenu { taskActions(task, entry: entry) }
                        .accessibilityAction(named: "Choose day and hour") { panel = .weeklyTiming(task.id, date) }
                }
            }
            .padding(.trailing, 4)
        case .event(let event, let block):
            if let block {
                PlanningEventButton(block: block, panel: $panel, editOnTap: store.journal.events.first { $0.id == event.id }) {
                    contextLabel(event.title, icon: "calendar", entry: entry)
                }
            } else if store.journal.events.contains(where: { $0.id == event.id }) {
                Button { panel = .commitment(event) } label: { contextLabel(event.title, icon: "calendar", entry: entry) }
            } else { contextLabel(event.title, icon: "calendar", entry: entry) }
        case .rule(let block):
            if case .timeBlock(let id, let role) = block.kind {
                Button { panel = .timeBlock(id) } label: {
                    contextLabel(block.title, icon: role == .protected ? "lock" : role == .boost ? "leaf" : "scope", entry: entry)
                }
            } else { contextLabel(block.title, icon: "pause", entry: entry) }
        case .recorded(let title):
            contextLabel(title, icon: "timer", entry: entry).accessibilityLabel("Logged time, \(title), \(timeRange(entry))")
        }
    }

    @ViewBuilder private func taskActions(_ task: PlanTask, entry: Entry) -> some View {
        let saved = week?.projectedTasks.contains(where: { $0.id == task.id }) != true
        if let target = durationTarget(entry) {
            Button("Change duration", systemImage: "arrow.up.and.down") { editingDuration = target }
        }
        if let week {
            Button("Set exact time", systemImage: "clock") { week.pickTime(task.id) }
            if task.id != store.journal.active?.taskID {
                Button("Return to Tasks", systemImage: "tray.and.arrow.down") { week.returnToDrawer(task.id) }
            }
        } else {
            Button("Find a better hour", systemImage: "clock") { panel = .taskTiming(task.id) }
        }
        Button("Choose day and hour", systemImage: "calendar") { panel = .weeklyTiming(task.id, date) }
        if saved {
            Button("Edit task", systemImage: "pencil") { panel = .task(task) }
            Button("Change icon", systemImage: "paintbrush") { panel = .taskIcon(task.id) }
            if task.id != store.journal.active?.taskID {
                if entry.start <= Date.now, let candidate = store.skipCandidate(for: task.id) {
                    Button("Skip for today", systemImage: "forward.end") { panel = .taskSkip(candidate) }
                }
                Button("Start now", systemImage: "play.fill") { onStart(task.id) }
                Button(store.needsCompletionPhoto(for: task) ? "Complete with photo" : "Complete", systemImage: store.needsCompletionPhoto(for: task) ? "camera" : "checkmark") { store.completeFromPlan(task) }
                if week == nil {
                    Button("Move to front") { store.change { $0.nextTaskID = task.id } }
                }
                Button("Delete task", systemImage: "trash", role: .destructive) { onDelete(task) }
            }
        }
    }

    private func contextLabel(_ title: String, icon: String, entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.subheadline)
            Text(timeRange(entry)).font(.caption.monospacedDigit())
        }
        .foregroundStyle(Color.surface.opacity(0.8)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func timeRange(_ entry: Entry) -> String {
        "\(clock(entry.start)) – \(clock(entry.end))"
    }

    private func clock(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let hour = calendar.component(.hour, from: date)
        let repeated = [-3600.0, 3600].contains { offset in
            calendar.component(.hour, from: date.addingTimeInterval(offset)) == hour
        }
        return repeated ? time + " " + (calendar.timeZone.abbreviation(for: date) ?? "") : time
    }
}

private struct EntryStart: LayoutValueKey {
    static let defaultValue: Date = .distantPast
}

/// The first child draws the clock. Every other child shares its origin and points per hour.
/// Nearby start times can use two lanes. Dense hours enlarge the whole scale uniformly.
private struct DayScaleLayout: Layout {
    let start: Date
    let end: Date
    let baseUnit: CGFloat
    let gutter: CGFloat
    let allowLanes: Bool

    static func compactHeight(_ base: CGFloat) -> CGFloat { max(44, base * 0.62) }

    struct Placement {
        let origin: CGPoint
        let size: CGSize
    }
    struct Geometry {
        let clockHeight: CGFloat
        let height: CGFloat
        let labels: [Placement]
    }

    private func geometry(width: CGFloat, subviews: Subviews) -> Geometry {
        let labels = subviews.dropFirst()
        let full = max(1, width - gutter)
        let half = max(1, (full - 5) / 2)
        let fullHeights = labels.map { $0.sizeThatFits(.init(width: full, height: nil)).height }
        let halfHeights = labels.map { $0.sizeThatFits(.init(width: half, height: nil)).height }
        let hours = labels.map { $0[EntryStart.self].timeIntervalSince(start) / 3600 }
        let duration = end.timeIntervalSince(start) / 3600
        // Prefer full-size labels and their natural height. The final pass uses each
        // group's compact menu, whose minimum spacing displayGroups already reserved.
        for (multiplier, compact) in [(1.0, false), (1.5, false), (2.0, false), (2.0, true)] {
            let unit = baseUnit * multiplier
            let limit = compact ? Self.compactHeight(baseUnit) : CGFloat.infinity
            var bottom = Array(repeating: CGFloat.zero, count: allowLanes ? 2 : 1)
            var placed: [Placement] = []
            for i in hours.indices {
                let y = hours[i] * unit
                let next = i + 1 < hours.count ? hours[i + 1] * unit : CGFloat.infinity
                let fullHeight = min(fullHeights[i], limit)
                let halfHeight = min(halfHeights[i], limit)
                if bottom.allSatisfy({ $0 <= y + 0.01 }) && (y + fullHeight + 4 <= next + 0.01 || !allowLanes) {
                    placed.append(.init(origin: CGPoint(x: gutter, y: y), size: CGSize(width: full, height: fullHeight)))
                    bottom = Array(repeating: y + fullHeight + 4, count: bottom.count)
                } else if allowLanes, let lane = bottom.firstIndex(where: { $0 <= y + 0.01 }) {
                    placed.append(.init(origin: CGPoint(x: gutter + CGFloat(lane) * (half + 5), y: y),
                                        size: CGSize(width: half, height: halfHeight)))
                    bottom[lane] = y + halfHeight + 4
                } else { break }
            }
            if placed.count == hours.count {
                return Geometry(clockHeight: duration * unit, height: max(duration * unit, bottom.max() ?? 0), labels: placed)
            }
        }
        // Only possible for an empty or transient subview collection outside its day.
        return Geometry(clockHeight: duration * baseUnit, height: duration * baseUnit, labels: [])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: geometry(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let geometry = geometry(width: bounds.width, subviews: subviews)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: .init(width: bounds.width, height: geometry.clockHeight))
        for (item, place) in zip(subviews.dropFirst(), geometry.labels) {
            let point = CGPoint(x: bounds.minX + place.origin.x, y: bounds.minY + place.origin.y)
            item.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(place.size))
        }
    }
}

private struct DayTaskDrop: DropDelegate {
    let start: Date
    let end: Date
    let now: Date
    let height: CGFloat
    let stepMinutes: Int
    @Binding var hover: Date?
    let move: @MainActor (UUID, Date?, Date) -> Void

    private func time(at y: CGFloat) -> Date? {
        guard y >= 0, y < height, height > 0, end > start, end > now else { return nil }
        let step = Double(stepMinutes) * 60
        let steps = end.timeIntervalSince(start) / step
        // Pixel-to-time round trips can land a fraction of an ulp before an exact minute.
        let index = min(ceil(steps) - 1, floor(y / height * steps + 1e-9))
        let time = start.addingTimeInterval(index * step)
        return time >= now && time < end ? time : nil
    }
    func validateDrop(info: DropInfo) -> Bool { end > now && info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { hover = time(at: info.location.y) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover = time(at: info.location.y)
        return DropProposal(operation: hover == nil ? .forbidden : .move)
    }
    func dropExited(info: DropInfo) {
        hover = nil
    }
    func performDrop(info: DropInfo) -> Bool {
        hover = nil
        guard let destination = time(at: info.location.y),
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let move = move
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String else { return }
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard let rawID = parts.first, let id = UUID(uuidString: String(rawID)) else { return }
            let source: Date?
            if parts.count == 1 { source = nil }
            else if parts.count == 2, let stamp = Int(parts[1]) { source = Date(timeIntervalSince1970: Double(stamp)) }
            else { return }
            Task { @MainActor in move(id, source, destination) }
        }
        return true
    }
}
