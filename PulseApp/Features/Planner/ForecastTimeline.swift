import PulseEngine
import SwiftUI

enum TimelineActionsAnchor: Hashable {
    case day(Date)
}

extension EnvironmentValues {
    @Entry var revealTimelineActions: @MainActor (Date) -> Void = { _ in }
}

/// One local-time ruler for energy samples, scheduled durations and move targets.
struct ForecastTimeline: View {
    let now: Date
    let blocks: [Block]
    let energy: [EnergyPoint]
    let selectedTaskID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Date) -> Void
    var displayedDay: Date? = nil
    var compactWeekDay = false
    var movableTaskIDs: Set<UUID>? = nil
    var hoverDay: ((CGPoint?) -> Void)? = nil
    var dropOnDay: ((UUID, CGPoint) -> Bool)? = nil
    var acceptWeeklyDrag: (([String], Date) -> Bool)? = nil
    var acceptFocusDrag: (([String], Block) -> Bool)? = nil
    var checkingMove = false
    @Binding var panel: Panel?

    @State private var targetHour: Date?
    @State private var touchingTask: UUID?
    @State private var rulerFrame = CGRect.zero
    @State private var overviewFrame = CGRect.zero
    @State private var energyEdit: ForecastEditSelection?
    @State private var leadingHours: CGFloat = 0
    @State private var measuredHourWidth: CGFloat?
    @State private var showMoveProgress = false
    @State private var showHours = false
    @State private var openingHour: Date?
    private var hoursVisible: Bool { drawing || showHours }
    @State private var drawing = false
    @State private var drawKind: WeeklyTimeBlock.Kind = .focus
    @State private var drawnBlock: DrawnTimeBlock?
    @State private var taskForBlock: UUID?
    @State private var pickingTask = false
    @State private var review: DrawnTimeBlock?
    @State private var viewport: CGFloat = 0
    @State private var plotOffset: CGFloat = 0
    @Namespace private var rulerSpace
    @ScaledMetric(relativeTo: .caption) private var unit: CGFloat = 118
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var titleCharacterWidth: CGFloat = 6
    @ScaledMetric(relativeTo: .caption) private var hourLabelHeight: CGFloat = 28
    @Environment(Workspace.self) private var store
    @Environment(\.revealTimelineActions) private var revealTimelineActions
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The overview uses dates for its tick labels. Scroll targets must identify only ruler cells.
    private struct RulerHour: Hashable { let date: Date }
    private struct Quarter: Hashable { let index: Int }
    private struct RulerPosition: Equatable {
        let offset: CGFloat
        let hourWidth: CGFloat
    }

    private var selectedHour: Date? {
        guard let selectedTaskID, let block = blocks.first(where: { $0.kind == .task(selectedTaskID) }) else { return nil }
        return Calendar.current.dateInterval(of: .hour, for: block.start)?.start
    }

    private var day: DateInterval { Calendar.current.dateInterval(of: .day, for: displayedDay ?? now)! }
    private var hours: [Date] {
        stride(from: day.start.timeIntervalSinceReferenceDate, to: day.end.timeIntervalSinceReferenceDate, by: 3600)
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }
    private func x(_ date: Date) -> CGFloat { date.timeIntervalSince(day.start) * unit / 3600 }
    private func score(at hour: Date) -> EnergyPoint? {
        energy.first { $0.date >= hour && $0.date < hour.addingTimeInterval(3600) }
    }
    private func hourLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let text = date.formatted(date: .omitted, time: .shortened)
        // Repeated clocks on the autumn transition identify different drop targets.
        for adjacent in [-3600.0, 3600] {
            if calendar.component(.hour, from: date) == calendar.component(.hour, from: date.addingTimeInterval(adjacent)) {
                return text + " " + (calendar.timeZone.abbreviation(for: date) ?? "")
            }
        }
        return text
    }

    private struct PlotBlock: Identifiable {
        let block: Block
        let left, duration, width: CGFloat
        let lane: Int
        var id: String { block.id }
    }

    // The daily projection omits elapsed blocks. The ruler also shows authored time earlier today.
    private var timelineBlocks: [Block] {
        let projected = blocks.filter { block in
            if case .timeBlock(_, let role) = block.kind { return role == .boost }
            return true
        }
        let authored = (store.journal.timeBlocks ?? []).flatMap { $0.blocks(on: day) }
        return projected + authored
    }

    private func arranged(_ blocks: [Block]) -> [PlotBlock] {
        let width = x(day.end)
        var ends: [CGFloat] = []
        var result: [PlotBlock] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) where block.start < day.end && block.end > day.start {
            let left = max(0, x(block.start))
            let span = min(width, x(block.end)) - left
            guard span > 0 else { continue }
            let badge = min(width, max(span, min(unit * 0.92, max(46, CGFloat(block.title.count) * titleCharacterWidth + 18))))
            let labelLeft = min(left, width - badge)
            let lane = ends.firstIndex { $0 + 3 <= labelLeft } ?? ends.count
            if lane == ends.count { ends.append(0) }
            ends[lane] = labelLeft + badge
            result.append(PlotBlock(block: block, left: left, duration: span, width: badge, lane: lane))
        }
        return result
    }

    var body: some View {
        let timelineBlocks = timelineBlocks
        let items = arranged(timelineBlocks)
        let coordinateSpace = rulerSpace
        let hourWidth = unit
        let tracksFinger = drawing || touchingTask != nil
        let lanes = max(1, (items.map(\.lane).max() ?? -1) + 1)
        let firstLane = hourLabelHeight + 51
        let height = firstLane + CGFloat(lanes) * laneHeight + 1
        VStack(alignment: .leading, spacing: 5) {
            let actions = type.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            actions {
                if drawing {
                    Text(drawnBlock?.original == nil ? "New block" : "Resize block")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                } else {
                    Button {
                        showHours.toggle()
                    } label: {
                        Label(hoursVisible ? "Hide hours" : "Show hours", systemImage: hoursVisible ? "chevron.up" : "clock")
                            .font(.subheadline.weight(.medium)).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityValue(day.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .accessibilityIdentifier("timeline-hours-toggle")
                }
                if !type.isAccessibilitySize { Spacer(minLength: 0) }
                drawButton
            }.id(TimelineActionsAnchor.day(day.start))
            if drawing, let draft = drawnBlock {
                if draft.original == nil {
                    Picker("Block type", selection: Binding(get: { drawKind }, set: { kind in
                        drawKind = kind
                        drawnBlock?.kind = kind
                        if kind == .protected { taskForBlock = nil }
                    })) {
                        Text("Focus").tag(WeeklyTimeBlock.Kind.focus)
                        Text("Protected").tag(WeeklyTimeBlock.Kind.protected)
                    }
                    .pickerStyle(.segmented).environment(\.colorScheme, .dark)
                    .accessibilityIdentifier("timeline-block-kind")
                }
                timeActions
                if draft.original == nil && draft.kind == .focus {
                    Button { pickingTask = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "checklist").accessibilityHidden(true)
                            Text(taskForBlock.map { id in store.journal.tasks.first { $0.id == id }?.title ?? "Task unavailable" } ?? "Choose a task")
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                        }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("timeline-choose-block-task")
                }
                Button {
                    review = draft
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.trailAmber, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Color.pine)
                }
                .buttonStyle(PressStyle()).accessibilityIdentifier("review-timeline-block")
                Text("Drag across the timeline to draw, or pull either end to resize.")
                    .font(.caption).foregroundStyle(Color.surface.opacity(0.80)).padding(.top, 4)
            }
            ScrollViewReader { reader in
                if !compactWeekDay || hoursVisible {
                    if !energy.isEmpty && !drawing {
                        Text("Energy forecast").font(.caption).foregroundStyle(Color.surface.opacity(0.8))
                    }
                    DayForecastNavigator(day: day, hours: hours, energy: energy, blocks: timelineBlocks, leadingHours: leadingHours,
                                     unit: unit, showsViewport: hoursVisible, currentTime: now, jump: { hour in
                                         if hoursVisible { reader.scrollTo(RulerHour(date: hour), anchor: .leading) }
                                         else { openingHour = hour; showHours = true }
                                     }, drop: accept)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { overviewFrame = $0 }
                    .onDisappear { overviewFrame = .zero }
                }
                if hoursVisible {
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            HStack(spacing: 0) {
                                ForEach(hours, id: \.self) { hour in
                                    hourTarget(hour, height: height).id(RulerHour(date: hour))
                                }
                            }
                            if drawing {
                                HStack(spacing: 0) {
                                    ForEach(0..<(hours.count * 4), id: \.self) { index in
                                        Color.clear.frame(width: unit / 4, height: 1).id(Quarter(index: index))
                                    }
                                }.allowsHitTesting(false).accessibilityHidden(true)
                            }
                            trace.frame(width: x(day.end), height: 43)
                                .offset(y: hourLabelHeight).allowsHitTesting(false).accessibilityHidden(true)
                            ForEach(items) { item in
                                let left = min(item.left, x(day.end) - item.width)
                                plotted(item)
                                    .focusDropFrame(item.block, clippedTo: rulerFrame)
                                    .dropDestination(for: String.self) { ids, location in
                                        if case .timeBlock(_, .focus) = item.block.kind, let acceptFocusDrag {
                                            return acceptFocusDrag(ids, item.block)
                                        }
                                        let hour = day.start.addingTimeInterval(floor((left + location.x) / unit) * 3600)
                                        return accept(ids, at: hour)
                                    }
                                    .offset(x: left,
                                            y: firstLane + CGFloat(item.lane) * laneHeight)
                            }
                            if drawing {
                                TimelineDrawingLayer(day: day, unit: unit, height: height, viewport: viewport,
                                                     offset: plotOffset, kind: drawKind, selection: $drawnBlock) { point in
                                    guard let item = items.first(where: { item in
                                        let left = min(item.left, x(day.end) - item.width)
                                        let top = firstLane + CGFloat(item.lane) * laneHeight
                                        return CGRect(x: left, y: top, width: item.width, height: laneHeight).contains(point)
                                    }) else { return nil }
                                    return existingSelection(for: item.block)
                                } pan: { direction in
                                    let next = Int((plotOffset / unit * 4).rounded()) + direction
                                    reader.scrollTo(Quarter(index: min(hours.count * 4 - 1, max(0, next))), anchor: .leading)
                                }
                            }
                        }.frame(width: x(day.end), height: height)
                            .onGeometryChange(for: RulerPosition.self) { geometry in
                                let offset = max(0, -geometry.frame(in: .named(coordinateSpace)).minX)
                                let step = tracksFinger ? 1 : hourWidth / 8
                                return RulerPosition(offset: (offset / step).rounded() * step, hourWidth: hourWidth)
                            } action: { position in
                                plotOffset = position.offset
                                if let measuredHourWidth, measuredHourWidth != position.hourWidth,
                                   let hour = hours.dropFirst(Int(leadingHours)).first {
                                    // Changing text size changes the width of each hour. Keep the same time in view.
                                    reader.scrollTo(RulerHour(date: hour), anchor: .leading)
                                } else {
                                    leadingHours = (position.offset / hourWidth * 8).rounded() / 8
                                }
                                measuredHourWidth = position.hourWidth
                            }
                    }
                    .coordinateSpace(name: rulerSpace)
                    .scrollDisabled(drawing)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rulerFrame = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
                    .scrollIndicators(.visible)
                    .onAppear {
                        let anchor = openingHour ?? selectedHour ?? (day.contains(now) ? now : blocks.map(\.start).min())
                            ?? Calendar.current.date(bySettingHour: store.journal.planningStartHour ?? 9, minute: 0, second: 0, of: day.start)
                            ?? day.start
                        if let hour = Calendar.current.dateInterval(of: .hour, for: max(day.start, anchor))?.start {
                            reader.scrollTo(RulerHour(date: hour), anchor: .leading)
                        }
                    }
                    .onDisappear { openingHour = nil; rulerFrame = .zero }
                    .onChange(of: selectedHour) { _, hour in
                        guard !drawing, let hour else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            reader.scrollTo(RulerHour(date: hour), anchor: .leading)
                        }
                    }
                }
            }
            if showMoveProgress && checkingMove {
                Label("Finding an opening…", systemImage: "clock").font(.caption)
            } else if hoursVisible && !drawing {
                HStack {
                    if !energy.isEmpty { Text("Energy out of 10").font(.caption) }
                    Spacer()
                    editButton
                }
            }
        }
        .task(id: checkingMove) {
            showMoveProgress = false
            guard checkingMove else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            showMoveProgress = true
        }
        .preference(key: TimelineHourTargetsKey.self, value: drawing || (compactWeekDay && !hoursVisible) ? nil : hourTargets)
        .onChange(of: showHours) { _, visible in
            if visible && !drawing { revealTimelineActions(day.start) }
        }
        .onChange(of: drawing) { _, editing in
            if editing { revealTimelineActions(day.start) }
        }
        .onChange(of: drawnBlock?.original?.id) {
            if let rule = drawnBlock?.original { drawKind = rule.kind; taskForBlock = nil }
        }
        .onChange(of: day) { endDrawing(); endTaskDrag() }
        .onDisappear { endTaskDrag() }
        .onChange(of: store.journalEpoch) { endDrawing(); endTaskDrag() }
        .sheet(item: $review) { value in
            NavigationStack {
                TimelineBlockReview(kind: value.kind, interval: value.interval, original: value.original,
                                    displayedSlice: value.displayedSlice, selectedTask: $taskForBlock) { showHours = true; endDrawing() }
            }
        }
        .sheet(isPresented: $pickingTask) {
            NavigationStack { FocusBlockTaskPicker(selection: $taskForBlock, presentedAsSheet: true) }
                .foregroundStyle(Color.journalInk).tint(.journalAccent).preferredColorScheme(store.sky.interfaceScheme)
        }
        .sheet(item: $energyEdit) { ForecastExpectationEditor(selection: $0) }
    }

    private func existingSelection(for block: Block) -> DrawnTimeBlock? {
        guard case .timeBlock(let id, let role) = block.kind, role != .boost,
              let rule = store.journal.timeBlocks?.first(where: { $0.id == id }) else { return nil }
        let range = DateInterval(start: max(block.start, day.start), end: min(block.end, day.end))
        return DrawnTimeBlock(interval: range, kind: rule.kind, original: rule, displayedSlice: range)
    }

    private var drawButton: some View {
        Button {
            if drawing { endDrawing() } else { beginBlock() }
        } label: {
            Label(drawing ? "Cancel" : "New block", systemImage: drawing ? "xmark" : "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 15).frame(minHeight: 44)
                .foregroundStyle(drawing ? Color.surface : compactWeekDay ? Color.trailAmber : Color.pine)
                .background(drawing ? Color.surface.opacity(0.10) : compactWeekDay ? Color.clear : Color.trailAmber, in: Capsule())
                .overlay {
                    if compactWeekDay && !drawing {
                        Capsule().strokeBorder(Color.trailAmber.opacity(0.64), lineWidth: 1).allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityValue(day.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .accessibilityIdentifier("timeline-draw-toggle")
    }

    private func beginBlock() {
        let calendar = Calendar.current
        let usualStart = calendar.date(bySettingHour: store.journal.planningStartHour ?? 9, minute: 0,
                                       second: 0, of: day.start) ?? day.start
        let visibleStart = day.start.addingTimeInterval(leadingHours * 3600)
        let reference = showHours ? visibleStart : max(now, usualStart)
        let rounded = ceil(reference.timeIntervalSince(day.start) / 900) * 900
        let start = day.start.addingTimeInterval(min(day.duration - 900, max(0, rounded)))
        drawKind = .focus
        drawnBlock = DrawnTimeBlock(interval: DateInterval(start: start, end: min(day.end, start.addingTimeInterval(1800))),
                                   kind: .focus)
        openingHour = calendar.dateInterval(of: .hour, for: start)?.start
        drawing = true
    }

    private func endDrawing() {
        drawing = false
        taskForBlock = nil
        pickingTask = false
        drawnBlock = nil
        review = nil
    }

    @ViewBuilder private var timeActions: some View {
        if let draft = drawnBlock {
            let layout = type >= .xxLarge
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                ForEach([TimelineRangeEdge.start, .end], id: \.self) { edge in
                    if draft.hasHandle(edge) {
                        let isStart = edge == .start
                        let bound = isStart ? (draft.original == nil ? day.end : draft.interval.end).addingTimeInterval(-60) : day.end
                        let lower = isStart ? day.start : draft.interval.start.addingTimeInterval(60)
                        let date = isStart ? draft.interval.start : draft.interval.end
                        DatePicker(isStart ? "Start" : "End", selection: Binding {
                            date
                        } set: { time in
                            guard var edited = drawnBlock else { return }
                            if isStart && edited.original == nil && time >= edited.interval.end {
                                edited.interval = DateInterval(start: time, end: min(day.end, time.addingTimeInterval(edited.interval.duration)))
                            } else {
                                edited.move(edge, to: time, within: day)
                            }
                            drawnBlock = edited
                        }, in: lower...bound, displayedComponents: .hourAndMinute)
                        .font(.subheadline)
                        .accessibilityValue(draft.clockLabel(date, day: day))
                        .accessibilityIdentifier(isStart ? "timeline-block-start-time" : "timeline-block-end-time")
                        .environment(\.colorScheme, .dark)
                    }
                }
            }
        }
    }

    @ViewBuilder private var editButton: some View {
        if let upcoming = hours.first(where: { $0 > now }) {
            Button {
                let futureDay = day.start > now
                energyEdit = ForecastEditSelection(date: futureDay ? day.start : upcoming, scope: futureDay ? .day : .hour)
            } label: {
                Label("Adjust forecast", systemImage: "pencil").font(.caption).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(PressStyle()).accessibilityLabel("Adjust energy forecast")
        }
    }

    private func hourTarget(_ hour: Date, height: CGFloat) -> some View {
        let isPast = hour.addingTimeInterval(3600) <= now
        let point = score(at: hour)
        return VStack(alignment: .leading, spacing: 0) {
            let time = Text(hourLabel(hour)).font(.caption.monospacedDigit())
            Group {
                if let point {
                    let score = Text(point.score.formatted(.number.precision(.fractionLength(0...1))) + "/10")
                        .font(.caption2.monospacedDigit()).foregroundStyle(Color.trailAmber)
                    Text("\(time)  \(score)")
                } else {
                    time
                }
            }
            .fixedSize()
            .padding(.leading, 5)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hourLabel(hour))
            .accessibilityValue(point.map { "Energy \($0.score.formatted(.number.precision(.fractionLength(1)))) out of ten" } ?? "No estimate")
            .contextMenu { editHourAction(hour) }

            // The rest of the column remains a touch and drop target. VoiceOver
            // visits the hour above, followed by the individual plotted tasks.
            Color.clear.contentShape(Rectangle())
                .contextMenu { editHourAction(hour) }
                .accessibilityHidden(true)
        }
        .frame(width: unit, height: height, alignment: .topLeading)
        .background(targetHour == hour ? Color.trailAmber.opacity(0.16) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.surface.opacity(0.13)).frame(width: 0.6)
        }
        .foregroundStyle(Color.surface.opacity(isPast ? 0.60 : 0.85))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            accept(ids, at: hour)
        } isTargeted: { active in
            if active && !isPast { targetHour = hour } else if targetHour == hour { targetHour = nil }
        }
    }

    @ViewBuilder private func editHourAction(_ hour: Date) -> some View {
        if hour > now {
            Button("Adjust expected energy", systemImage: "pencil") {
                energyEdit = ForecastEditSelection(date: hour, scope: .hour)
            }
        }
    }

    private func accept(_ ids: [String], at hour: Date) -> Bool {
        guard hour >= day.start, hour < day.end, hour.addingTimeInterval(3600) > now else { return false }
        if acceptWeeklyDrag?(ids, hour) == true { return true }
        guard let raw = ids.first, let id = UUID(uuidString: raw), movableTaskIDs?.contains(id) != false,
              blocks.contains(where: { $0.kind == .task(id) }) else { return false }
        onMove(id, hour)
        return true
    }

    private var hourTargets: TimelineHourTargets {
        TimelineHourTargets(day: day, overview: overviewFrame, ruler: hoursVisible ? rulerFrame : .zero,
                            offset: plotOffset, hourWidth: unit)
    }

    private func endTaskDrag() {
        touchingTask = nil
        targetHour = nil
        hoverDay?(nil)
    }

    private var trace: some View {
        Canvas { context, size in
            var previous: CGPoint?
            for hour in hours {
                guard let point = score(at: hour) else { previous = nil; continue }
                let origin = x(hour)
                let y = 3 + (10 - point.score) / 10 * (size.height - 6)
                let color = Color.trailAmber
                let fill = CGRect(x: origin, y: y, width: unit, height: size.height - y)
                context.fill(Path(fill), with: .linearGradient(
                    Gradient(colors: [color.opacity(0.30), color.opacity(0.04)]),
                    startPoint: CGPoint(x: origin, y: y), endPoint: CGPoint(x: origin, y: size.height)))
                var path = Path()
                path.move(to: previous ?? CGPoint(x: origin, y: y))
                path.addLine(to: CGPoint(x: origin, y: y))
                path.addLine(to: CGPoint(x: origin + unit, y: y))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, dash: point.source == .forecast ? [5, 3] : []))
                previous = CGPoint(x: origin + unit, y: y)
            }
        }
    }

    @ViewBuilder private func plotted(_ item: PlotBlock) -> some View {
        if case .task(let id) = item.block.kind, movableTaskIDs?.contains(id) != false {
            Button { onSelect(id) } label: {
                blockLabel(item, color: .trailAmber, selected: id == selectedTaskID)
            }
            .buttonStyle(.plain)
            .overlay {
                if !drawing {
                    TimelineTaskTouch(title: item.block.title, destination: { point in
                        hourTargets.hour(at: point).map(hourLabel)
                    }, tap: { onSelect(id) }, moved: { point in
                        touchingTask = id
                        targetHour = hourTargets.hour(at: point)
                        hoverDay?(point)
                    }, released: { point in
                        defer { endTaskDrag() }
                        guard let point, touchingTask == id else { return }
                        if dropOnDay?(id, point) == true { return }
                        if let hour = hourTargets.hour(at: point) { _ = accept([id.uuidString], at: hour) }
                    }).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(item.block.title)
            .accessibilityValue(item.block.start.formatted(date: .omitted, time: .shortened))
            .accessibilityHint("Show placement and moving options")
            .accessibilityAction(named: "Move task") { onSelect(id) }
        } else if case .timeBlock(let id, let role) = item.block.kind {
            Button { panel = .timeBlock(id) } label: {
                blockLabel(item, color: role == .focus ? .trailAmber : .surface, selected: false)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let value = existingSelection(for: item.block) {
                    Button("Resize on timeline", systemImage: "arrow.left.and.right") {
                        drawKind = value.kind
                        drawing = true
                        drawnBlock = value
                    }
                }
            }
            .accessibilityLabel(item.block.title)
            .accessibilityValue(item.block.start.formatted(date: .omitted, time: .shortened))
        } else if case .fixed = item.block.kind {
            PlanningEventButton(block: item.block, panel: $panel) {
                blockLabel(item, color: store.sky[6], selected: false)
            }
            .accessibilityLabel(item.block.title)
            .accessibilityValue(item.block.start.formatted(date: .omitted, time: .shortened))
        } else {
            blockLabel(item, color: item.block.kind == .rest ? .surface.opacity(0.6) : store.sky[6], selected: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func blockLabel(_ item: PlotBlock, color: Color, selected: Bool) -> some View {
        let left = min(item.left, x(day.end) - item.width)
        return VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(color).frame(width: max(1, item.duration), height: selected ? 4 : 2)
                .offset(x: item.left - left)
            Text(item.block.title).font(.caption.weight(selected ? .bold : .regular))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(selected ? Color.trailAmber : Color.surface)
        }
        .frame(width: item.width, height: laneHeight, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}
