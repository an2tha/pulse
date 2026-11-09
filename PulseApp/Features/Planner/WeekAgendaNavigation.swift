import SwiftUI

/// Keep every date within reach during a drag, even when the week strip has scrolled away.
@MainActor @Observable final class WeekAgendaDrag {
    struct Jump: Equatable { let date: Date; var animated = true; let id = UUID() }
    var jump: Jump?
    var dates: [Date] = []
    var highlighted: Date?
    var frames: [Date: CGRect] = [:]
    var pinnedFrames: [Date: CGRect] = [:]
    var drawerFrame = CGRect.zero
    var isOverDrawer = false
    @ObservationIgnored var returnToDrawer: ((UUID, Date) -> Bool)?

    @ObservationIgnored var openDate: ((Date) -> Void)?
    @ObservationIgnored var previewDate: ((Date) -> Void)?
    @ObservationIgnored var dropOnDate: (([String], Date) -> Bool)?
    @ObservationIgnored private var pendingPreview: Task<Void, Never>?

    func hoverDate(_ date: Date, inside: Bool) {
        if !inside && highlighted != date { return }
        pendingPreview?.cancel()
        pendingPreview = nil
        highlighted = inside ? date : nil
        guard inside else { return }
        pendingPreview = Task {
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            guard highlighted == date else { return }
            previewDate?(date)
        }
    }

    func end() {
        pendingPreview?.cancel()
        pendingPreview = nil
        dates = []
        highlighted = nil
        isOverDrawer = false
        frames = [:]
    }
}

struct WeekAgendaAnchor: Hashable { let day: Date }

struct WeekAgendaNavigation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    let drag: WeekAgendaDrag

    func body(content: Content) -> some View {
        ScrollViewReader { reader in
            content.environment(\.revealTimelineActions) { day in
                withAnimation(reduced ? nil : .easeOut(duration: 0.22)) {
                    reader.scrollTo(TimelineActionsAnchor.day(day), anchor: .top)
                }
            }.task(id: drag.jump?.id) {
                guard let target = drag.jump else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(reduced || !target.animated ? nil : .easeOut(duration: 0.22)) {
                    reader.scrollTo(WeekAgendaAnchor(day: target.date), anchor: .top)
                }
            }
        }
        .environment(drag)
    }
}

struct WeekDragDayStrip: View {
    @Environment(Workspace.self) private var store
    let drag: WeekAgendaDrag

    var body: some View {
        if !drag.dates.isEmpty {
            VStack(spacing: 2) {
                Text("Move to day").font(.caption.weight(.semibold))
                HStack(spacing: 0) {
                    ForEach(drag.dates, id: \.self) { date in
                        let active = date == drag.highlighted
                        VStack(spacing: 1) {
                            Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                            Text(date.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(active ? store.sky.ground : Color.surface)
                        .background(active ? Color.trailAmber : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            drag.frames[date] = $0
                        }
                    }
                }
            }
            .foregroundStyle(Color.surface)
            .padding(6)
            .frame(maxWidth: 590)
            .background(store.sky.ground, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.surface.opacity(0.4)) }
            .padding(.horizontal, 8).padding(.bottom, 4)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// The targets live outside the scrolling timeline, so they survive a day switch mid-drag.
struct WeekDateDock: View {
    @Environment(Workspace.self) private var store
    let dates: [Date]
    let selected: Date?
    let drag: WeekAgendaDrag

    var body: some View {
        HStack(spacing: 1) {
            ForEach(dates, id: \.self) { day in
                let active = day == selected
                Button { drag.openDate?(day) } label: {
                    VStack(spacing: 1) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                        Text(day.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                    }
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(active ? store.sky.ground : Color.surface)
                    .background(active ? Color.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if drag.highlighted == day {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.trailAmber, lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityAddTraits(active ? .isSelected : [])
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.pinnedFrames[day] = $0 }
                .accessibilityHint("Open day timeline")
                .accessibilityIdentifier("plan-day-\(Int(day.timeIntervalSince1970))")
                .dropDestination(for: String.self) { items, _ in
                    drag.hoverDate(day, inside: false)
                    return drag.dropOnDate?(items, day) ?? false
                } isTargeted: { drag.hoverDate(day, inside: $0) }
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(store.sky.ground)
        .onDisappear { drag.end(); drag.pinnedFrames = [:] }
    }
}
