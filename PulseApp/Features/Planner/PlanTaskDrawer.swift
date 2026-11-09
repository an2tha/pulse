import PulseEngine
import SwiftUI

struct PlanTaskDrawer: View {
    @Environment(Workspace.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.verticalSizeClass) private var verticalSize
    @Binding var expanded: Bool
    let scheduledIDs: Set<UUID>
    let revealTask: UUID?
    let selectsDay: Bool
    @Binding var selected: UUID?
    let gripOverDrawer: Bool
    let acceptReturn: (String) -> Bool
    @State private var dropTarget = false
    let schedule: (UUID) -> Void
    let add: () -> Void
    let dump: () -> Void

    private var tasks: [PlanTask] {
        store.journal.tasks.filter { task in
            guard !task.done, task.archived != true, task.id != store.journal.active?.taskID,
                  (task.isInboxOnly || !scheduledIDs.contains(task.id)) else { return false }
            // A missed pin can be placed again. A future pin already has a home.
            return task.plannedStart.map { $0 < store.now } ?? true
        }
    }

    var body: some View {
        let available = tasks
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "tray").foregroundStyle(Color.trailAmber)
                        Text(dropTarget || gripOverDrawer ? "Return to Tasks" : "Tasks").font(.headline)
                        Text(available.count.formatted()).font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color.surface.opacity(0.78))
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Tasks")
                .accessibilityValue("\(available.count) unscheduled, \(expanded ? "expanded" : "collapsed")")
                .accessibilityIdentifier("day-task-drawer")
                Menu {
                    Button("New task", systemImage: "plus", action: add)
                    Button("To-do dump", systemImage: "tray.and.arrow.down", action: dump)
                } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Add tasks")
            }
            if let id = selected, let task = available.first(where: { $0.id == id }) {
                HStack {
                    Text("Tap a day for " + task.title).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Cancel") { selected = nil }.font(.subheadline).frame(minHeight: 44)
                }.padding(.trailing, 10)
            }
            if expanded {
                if available.isEmpty {
                    if !scheduledIDs.isEmpty {
                        Text("Drag a scheduled task back here to free its time.")
                            .font(.footnote).foregroundStyle(Color.surface.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Add an unscheduled task", systemImage: "plus", action: add)
                        .font(.subheadline).foregroundStyle(Color.trailAmber)
                        .frame(minHeight: 44)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                Text(selectsDay ? "Drag to a day, or tap a task to choose a time." : "Drag a task to a time, or tap to schedule.")
                                    .font(.footnote).foregroundStyle(Color.surface.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.vertical, 3)
                                ForEach(available) { task in drawerRow(task).id(task.id) }
                            }
                        }
                        .onChange(of: revealTask.flatMap { id in available.contains(where: { $0.id == id }) ? id : nil }, initial: true) { _, id in
                            if let id { reader.scrollTo(id, anchor: .center) }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: listHeight(count: available.count))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 3)
        .frame(maxWidth: 600)
        .foregroundStyle(Color.surface)
        .background(store.sky.ground, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(dropTarget || gripOverDrawer ? Color.trailAmber : Color.surface.opacity(0.25),
                              lineWidth: dropTarget || gripOverDrawer ? 2 : 1).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard items.count == 1, let payload = items.first else { return false }
            return acceptReturn(payload)
        } isTargeted: { dropTarget = $0 }
        .onChange(of: available.map(\.id)) {
            if let selected, !available.contains(where: { $0.id == selected }) { self.selected = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private func listHeight(count: Int) -> CGFloat {
        if verticalSize == .compact { return 76 }
        if type.isAccessibilitySize { return 158 }
        return min(172, 28 + 48 * CGFloat(count))
    }

    private func drawerRow(_ task: PlanTask) -> some View {
        Button { schedule(task.id) } label: {
            HStack(spacing: 9) {
                TaskIconView(icon: task.icon, fallback: task.category.symbol)
                    .foregroundStyle(Color.trailAmber).frame(width: 23)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(task.minutes) min").font(.caption.monospacedDigit())
                        .foregroundStyle(Color.surface.opacity(0.78))
                }
                Spacer(minLength: 2)
                Image(systemName: "line.3.horizontal").font(.footnote)
                    .foregroundStyle(Color.surface.opacity(0.65))
            }
            .padding(.trailing, 14).padding(.vertical, 4)
            .frame(minHeight: 48).contentShape(Rectangle())
        }
        .draggable(task.id.uuidString) {
            TaskIconTitle(title: task.title, icon: task.icon)
                .padding(10).foregroundStyle(Color.journalInk)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Schedule " + task.title)
        .accessibilityValue("\(task.minutes) minutes")
        .accessibilityHint(selectsDay ? "Choose a day, then a time" : "Choose a start time")
        .accessibilityIdentifier("day-drawer-task-" + task.id.uuidString)
    }
}
