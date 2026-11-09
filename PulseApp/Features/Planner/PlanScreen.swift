import PulseEngine
import SwiftUI

struct PlanScreen: View {
  @Environment(Workspace.self) var store
  @Environment(\.accessibilityReduceMotion) private var reduced
  @Environment(\.dynamicTypeSize) private var type
  @Binding var panel: Panel?
  @State private var showingPractices = false
  @State private var taskDraft: PlanTask?
  @State private var reviewingInbox = false
  @State private var inboxDrop = InboxDropSession()
  @Binding var mode: PlanMode
  var openFocus: () -> Void
  @State private var deletingTask: TaskDeleteRequest?
  @State private var startingTask: UUID?
  @SceneStorage("pulse.plan.week.day") private var selectedWeekTimestamp: Double?

  @State private var showPlanGuide = false
  @State private var query = ""
  @State private var onlyHeld = false
  @State private var category: PulseEngine.Category?
  @State private var timingSelection: UUID?
  @State private var moveMessage: String?
  @State private var dropAlternative: TimeDropSuggestion?
  @State private var movingTask = false
  @State private var openWeekDay: Date?
  @State private var taskDrawerExpanded = false
  @State private var returnedTask: UUID?
  @State private var drawerTask: UUID?
  @State private var weekScheduled: [Date: Set<UUID>] = [:]
  @State private var editingDayTools = false
  @State private var weekDrag = WeekAgendaDrag()
  @State private var regenerated = false
  @State private var completionFeedback = 0
  private var displayedDate: Date {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: store.now)
    if mode == .tomorrow { return calendar.date(byAdding: .day, value: 1, to: today) ?? today }
    if mode == .week, let selectedWeekTimestamp {
      let day = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: selectedWeekTimestamp))
      if let distance = calendar.dateComponents([.day], from: today, to: day).day,
         (0..<7).contains(distance) { return day }
    }
    return today
  }

  private var isChecklist: Bool { mode == .inbox || mode == .all }
  private var canReviewInbox: Bool {
    let journal = store.journal
    if let receipt = journal.inboxUndo,
       InboxTriage.canUndo(receipt, tasks: journal.tasks, next: journal.nextTaskID, active: journal.active?.taskID) {
      return true
    }
    return InboxTriage.candidate(tasks: journal.tasks, next: journal.nextTaskID, active: journal.active?.taskID,
                                 blocks: store.blocks, now: store.now, inboxOnly: onlyHeld) != nil
  }
  private var visibleTasks: [PlanTask] {
    let source = mode == .archive ? store.journal.tasks : store.offeredTasks
    return source.filter { t in
      (mode != .archive || t.archived == true)
        && (mode != .inbox || (t.belongsToInbox && (!onlyHeld || t.isInboxOnly)))
        && (mode != .routines || (t.repeated ?? .once) != .once)
        && (category == nil || t.category == category)
        && (query.isEmpty
          || [t.title, t.notes ?? "", t.project ?? ""].joined(separator: " ")
            .localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        JournalHeader(
          dateLabel: displayedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
          actionTitle: mode == .timeline ? "New task" : "Add to plan", actionIcon: "plus",
          action: { if mode == .timeline { newDrawerTask() } else { panel = .add(displayedDate) } },
          settings: { panel = .settings })

        LazyVStack(alignment: .leading, spacing: 0) {
          HStack {
            viewMenu
            Spacer(minLength: 8)
            Menu {
              if mode == .timeline {
                Button(editingDayTools ? "Back to day schedule" : "Edit time blocks and forecast", systemImage: "calendar.badge.clock") {
                  editingDayTools.toggle()
                  taskDrawerExpanded = false
                }
                Button("Add to plan", systemImage: "plus") { panel = .add(displayedDate) }
              }
              if mode == .timeline {
                Button("Skip a task…", systemImage: "forward.end") { panel = .dueToSkip }
              }
              Button("How to use Plan", systemImage: "book.pages") { showPlanGuide = true }
                .accessibilityIdentifier("plan-walkthrough")
              Button("Daily limit · \(store.journal.limit) min", systemImage: "hourglass") { panel = .settings }
                .accessibilityIdentifier("plan-daily-limit")
              Button("Rebuild today’s plan", systemImage: "arrow.clockwise") {
                store.regenerate()
                regenerated.toggle()
              }
            } label: {
              Image(systemName: "ellipsis").font(.title3.weight(.medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Planning options")
          }.padding(.bottom, 6)
          if mode == .week || mode == .tomorrow {
            WeeklyPlan(tomorrow: mode == .tomorrow, panel: $panel, onTiming: { id, date in panel = .weeklyTiming(id, date) },
                       selectedTimestamp: $selectedWeekTimestamp, showWeek: { mode = .week },
                       startTask: startFromPlan, deleteTask: requestDeletion, drawerTask: $drawerTask, openWeekDay: $openWeekDay)
          } else if mode == .projects {
            ProjectList(panel: $panel)
          } else if mode != .timeline {
            if mode == .routines {
              let actions = type.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 20))
              actions {
                Button("New repeating task", systemImage: "plus") {
                  var task = PlanTask("", minutes: 15)
                  task.repeated = .daily
                  task.repeatDays = [Calendar.current.component(.weekday, from: store.now)]
                  taskDraft = task
                }.foregroundStyle(Color.trailAmber).frame(minHeight: 44)
                Button("Weekly practices", systemImage: "calendar") { showingPractices = true }
                  .frame(minHeight: 44)
              }
            }
            if mode == .inbox, canReviewInbox {
              Button("Review inbox", systemImage: "tray.full") { reviewingInbox = true }
                .foregroundStyle(Color.trailAmber).frame(minHeight: 44)
            }
            HStack {
              Image(systemName: "magnifyingglass")
              TextField("Search tasks", text: $query, prompt: Text("Search tasks").foregroundColor(Color.surface.opacity(0.72)))
                .foregroundStyle(Color.surface)
                .accessibilityLabel("Search tasks").accessibilityIdentifier("plan-task-search")
              Menu {
                if mode == .inbox {
                  Toggle("Inbox only", isOn: $onlyHeld)
                  Divider()
                }
                Button("All categories") { category = nil }
                ForEach(PulseEngine.Category.allCases, id: \.self) { c in
                  Button(c.rawValue) { category = c }
                }
              } label: {
                Image(
                  systemName: category == nil && !(mode == .inbox && onlyHeld)
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
                ).frame(width: 44, height: 44)
              }.accessibilityLabel("Filter tasks")
            }.padding(.bottom, 12)

            let tasks = visibleTasks
            let matchingEvents =
              mode == .all && category == nil
              ? store.journal.events.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
              : []
            if tasks.isEmpty && matchingEvents.isEmpty {
              let emptyTitle = mode == .inbox && onlyHeld ? "No inbox-only tasks" :
                mode == .routines ? "No fixed routines yet" : "No items yet"
              Text(query.isEmpty && category == nil ? emptyTitle : "No matching items").foregroundStyle(
                .white.opacity(0.74))
            }
            ForEach(tasks) { task in
              taskListRow(task)
                .transition(reduced ? .identity : .opacity)
            }
            ForEach(matchingEvents) { event in
              Button {
                panel = .commitment(event)
              } label: {
                itemRow(
                  event.title, icon: "lock",
                  detail: event.start.formatted(date: .abbreviated, time: .shortened) + " · "
                    + event.recurrence.rawValue)
              }
            }
          } else {
            if editingDayTools {
              Button("Back to day schedule", systemImage: "chevron.backward") { editingDayTools = false }
                .frame(minHeight: 44)
              ForecastTimeline(now: store.now, blocks: store.blocks, energy: store.energyTimeline.projectedHours(on: store.now, sleepWindow: store.plannedSleep, referenceWindow: store.sleepCalibrationWindow),
                               selectedTaskID: timingSelection, onSelect: { panel = .taskTiming($0) },
                               onMove: { id, hour in moveToday(id, to: hour) }, checkingMove: movingTask, panel: $panel)
            } else {
              TaskDayTimeline(date: store.now, blocks: store.blocks, energy: store.energyTimeline.projectedHours(on: store.now, sleepWindow: store.plannedSleep, referenceWindow: store.sleepCalibrationWindow),
                              panel: $panel, onMove: { id, _, time in moveToday(id, to: time, exact: true) },
                              onStart: startFromPlan, onDelete: requestDeletion)
            }
          }
        }
        .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 24)
        .frame(maxWidth: 620).frame(maxWidth: .infinity)
        .buttonStyle(PressStyle())
        .animation(
          reduced ? nil : .snappy(duration: 0.24, extraBounce: 0), value: store.blocks.map(\.kind)
        )
        .animation(reduced ? nil : .easeInOut(duration: 0.19), value: mode)
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .sheet(isPresented: $showPlanGuide) { NavigationStack { PulseWalkthrough(startingAt: .plan) } }
    .modifier(WeekAgendaNavigation(drag: weekDrag))
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if mode == .timeline || mode == .week || mode == .tomorrow {
        VStack(spacing: 0) {
          if mode == .timeline { moveFeedback }
          if mode == .week && !weekScheduled.isEmpty {
            WeekDateDock(dates: weekScheduled.keys.sorted(), selected: openWeekDay, drag: weekDrag)
          } else if mode == .tomorrow { WeekDragDayStrip(drag: weekDrag) }
          if !editingDayTools {
            PlanTaskDrawer(expanded: $taskDrawerExpanded, scheduledIDs: scheduledDrawerIDs,
                           revealTask: returnedTask, selectsDay: mode == .week && openWeekDay == nil, selected: $drawerTask,
                           gripOverDrawer: weekDrag.isOverDrawer, acceptReturn: acceptDrawerDrop,
                           schedule: { id in
                             if mode == .timeline { panel = .taskTiming(id) }
                             else { drawerTask = id; taskDrawerExpanded = false }
                           }, add: newDrawerTask, dump: { panel = .todoDump })
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { weekDrag.drawerFrame = $0 }
              .onAppear { weekDrag.returnToDrawer = returnScheduledTask }
              .onDisappear { weekDrag.drawerFrame = .zero; weekDrag.returnToDrawer = nil }
          }
        }
      } else if mode == .inbox && (inboxDrop.feedback != nil || inboxDrop.working || visibleTasks.contains(where: canDragFromInbox)) {
        InboxDropDock(session: inboxDrop, compare: { panel = .weeklyTiming($0, nil) },
                      editBlock: { panel = .timeBlock($0) })
      }
    }
    .onPreferenceChange(WeekScheduledTasksKey.self) { weekScheduled = $0 }
    .onChange(of: mode) { oldMode, newMode in
      if newMode != .week { openWeekDay = nil }
      if !([PlanMode.week, .tomorrow].contains(oldMode) && [PlanMode.week, .tomorrow].contains(newMode)) {
        taskDrawerExpanded = false
      }
      returnedTask = nil
      drawerTask = nil
      weekDrag.end()
      editingDayTools = false
      if mode != .inbox { inboxDrop = InboxDropSession() }
    }
    .onChange(of: store.journalEpoch) {
      inboxDrop = InboxDropSession()
      deletingTask = nil
      taskDraft = nil
      returnedTask = nil
      drawerTask = nil
      weekScheduled = [:]
      dropAlternative = nil
      moveMessage = nil
      timingSelection = nil
      taskDrawerExpanded = false
    }
    .modifier(TaskDeleteConfirmation(request: $deletingTask))
    .task(id: startingTask) {
      guard let id = startingTask else { return }
      defer { startingTask = nil }
      if await store.quickStartTask(id), !Task.isCancelled { openFocus() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if isChecklist || mode == .timeline, let receipt = store.lastListCompletion, receipt.epoch == store.journalEpoch {
        HStack(spacing: 8) {
          Text("Completed \(receipt.title)").font(.subheadline).lineLimit(2)
          Spacer(minLength: 4)
          Button("Undo") {
            withAnimation(reduced ? nil : .snappy(duration: 0.2)) {
              if store.undoListCompletion(receipt) { completionFeedback += 1 }
            }
          }
          .font(.subheadline.bold()).frame(minWidth: 44, minHeight: 44)
          .accessibilityLabel("Undo completion of " + receipt.title)
          .accessibilityIdentifier("plan-completion-undo")
          Button { store.lastListCompletion = nil } label: {
            Image(systemName: "xmark").font(.footnote).frame(width: 44, height: 44)
          }.accessibilityLabel("Dismiss completion message")
        }
        .padding(.leading, 16).background(store.sky.ground, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.surface.opacity(0.24)).allowsHitTesting(false) }
        .padding(.horizontal, 18).padding(.bottom, 5)
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: completionFeedback)
    .onChange(of: store.lastTimeMove) { previous, current in
      guard current == nil, let previous, previous.taskID == timingSelection,
            moveMessage != nil, dropAlternative == nil else { return }
      moveMessage = previous.wasRestored(in: store.journal.tasks) ? "Previous timing restored." : nil
    }
    .foregroundStyle(Color.surface).background { JournalGround(sky: store.sky) }
    .sheet(item: $taskDraft) { task in
      NavigationStack {
        TaskEditor(task: task, isNew: true)
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { taskDraft = nil } } }
      }.foregroundStyle(Color.journalInk).tint(.journalAccent).preferredColorScheme(store.sky.interfaceScheme)
    }
    .sheet(isPresented: $showingPractices) {
      NavigationStack { WeeklyPracticesScreen() }
        .presentationDragIndicator(.visible)
        .preferredColorScheme(store.sky.interfaceScheme)
    }
    .completionProofSheet(active: panel == nil && !showingPractices)
    .sheet(isPresented: $reviewingInbox) {
      NavigationStack { InboxTriageScreen(inboxOnly: onlyHeld) }
        .presentationDragIndicator(.visible)
        .preferredColorScheme(store.sky.interfaceScheme)
    }

  }

  private func taskListRow(_ task: PlanTask) -> some View {
    HStack(spacing: 5) {
      if isChecklist {
        if task.done {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.trailAmber)
            .frame(width: 44, height: 44).accessibilityHidden(true)
        } else {
          let obstacle = store.completionObstacle(task)
          let needsPhoto = store.needsCompletionPhoto(for: task)
          Button {
            withAnimation(reduced ? nil : .snappy(duration: 0.2)) {
              if store.completeFromPlan(task) { completionFeedback += 1 }
            }
          } label: {
            Image(systemName: obstacle == nil ? (needsPhoto ? "camera.circle" : "circle") : "lock.circle")
              .font(.title3).foregroundStyle(Color.surface.opacity(obstacle == nil ? 0.84 : 0.6))
              .frame(width: 44, height: 44).contentShape(Rectangle())
          }
          .accessibilityLabel("Complete " + task.title)
          .accessibilityHint(obstacle ?? (needsPhoto ? "Add a completion photo" : "Marks the task complete"))
          .accessibilityIdentifier("plan-complete-" + task.id.uuidString)
        }
      }
      if mode == .inbox, canDragFromInbox(task) {
        editTaskButton(task).draggable(task.id.uuidString) {
          Text(task.title).padding(10).background(Color.paper).foregroundStyle(Color.journalInk)
        }
        startTaskButton(task)
        AgendaTaskHandle(title: task.title, tap: { inboxDrop.select(task.id) }, destination: { point in
          guard let target = inboxDrop.target(at: point) else { return nil }
          if case .focus(_, let id) = target {
            return store.journal.timeBlocks?.first(where: { $0.id == id })?.displayTitle
          }
          return target.date.formatted(.dateTime.weekday(.wide))
        }, hover: { point in
          inboxDrop.hover(point.flatMap(inboxDrop.target(at:)))
        }, drop: { point in
          if let target = inboxDrop.target(at: point) { _ = inboxDrop.place(task.id, at: target, in: store) }
        })
        .accessibilityRepresentation {
          Button("Schedule " + task.title) { inboxDrop.select(task.id) }
            .accessibilityHint("Choose a day or a focus block")
            .accessibilityIdentifier("inbox-schedule-" + task.id.uuidString)
        }
      } else {
        editTaskButton(task)
        if !task.done && task.archived != true { startTaskButton(task) }
      }
    }
  }

  private func startTaskButton(_ task: PlanTask) -> some View {
    Button {
      startFromPlan(task.id)
    } label: {
      Group {
        if startingTask == task.id { ProgressView().tint(.trailAmber) }
        else { Image(systemName: "play.fill").foregroundStyle(Color.trailAmber) }
      }.frame(width: 44, height: 44).contentShape(Rectangle())
    }
    .accessibilityLabel("Start " + task.title)
    .accessibilityIdentifier("plan-start-" + task.id.uuidString)
    .disabled(startingTask != nil)
  }

  private func startFromPlan(_ id: UUID) {
    guard startingTask == nil else { return }
    startingTask = id
  }

  private func requestDeletion(_ task: PlanTask) {
    deletingTask = TaskDeleteRequest(task: task, epoch: store.journalEpoch)
  }

  private func canDragFromInbox(_ task: PlanTask) -> Bool {
    !store.journal.tasks.isEmpty && task.belongsToInbox && task.id != store.journal.active?.taskID
  }

  private func editTaskButton(_ task: PlanTask) -> some View {
    Button { panel = .task(task) } label: {
      itemRow(
        task.title, icon: isChecklist || task.icon != nil ? nil : (task.done ? "checkmark.circle" : task.category.symbol),
        customIcon: task.icon,
        detail: task.done ? "Completed"
          : "\(task.minutes) min · \(task.category.rawValue) · Energy \(task.energyCost(at: store.capacity))/10"
            + (mode == .routines ? task.captureRecurrence().map { " · " + $0 } ?? "" : "")
            + (task.isInboxOnly ? " · Inbox only" : "")
            + (scheduleDescription(task).map { " · " + $0 } ?? ""),
        showsChevron: mode != .inbox || !canDragFromInbox(task))
    }
    .modifier(TaskDeleteSwipe(enabled: store.journal.active?.taskID != task.id) { requestDeletion(task) })
    .accessibilityHint("Edit task")
    .accessibilityIdentifier("plan-edit-" + task.id.uuidString)
    .contextMenu {
      if let candidate = store.skipCandidate(for: task.id) {
        Button("Skip for today", systemImage: "forward.end") { panel = .taskSkip(candidate) }
      }
      Button("Change icon", systemImage: "paintbrush") { panel = .taskIcon(task.id) }
      if !task.done && task.archived != true && store.journal.active?.taskID != task.id {
        Button("Find a time this week", systemImage: "calendar.badge.clock") { panel = .weeklyTiming(task.id, nil) }
      }
      if store.journal.active?.taskID != task.id {
        Button("Delete task", systemImage: "trash", role: .destructive) { requestDeletion(task) }
      }
    }
  }

  private func scheduleDescription(_ task: PlanTask) -> String? {
    let effective = task.preparation == nil ? task : task.planningCopy(with: store.planningEvents, bufferMinutes: store.preferences.bufferMinutes)
    if let pin = effective.plannedStart {
      if let id = task.assignedFocusBlockID,
         let rule = store.journal.timeBlocks?.first(where: { $0.id == id && $0.kind == .focus }),
         let day = Calendar.current.dateInterval(of: .day, for: pin),
         rule.blocks(on: day).contains(where: { $0.start <= pin && pin < $0.end }) {
        return rule.displayTitle + " · " + pin.formatted(.dateTime.month(.abbreviated).day().hour().minute())
      }
      return "Scheduled " + pin.formatted(date: .abbreviated, time: .shortened)
    }
    if effective.preparation != nil, let due = effective.due {
      return "Prep due " + due.formatted(date: .abbreviated, time: .shortened)
    }
    return task.after.map { "From " + $0.formatted(date: .abbreviated, time: .shortened) }
  }

  private var scheduledDrawerIDs: Set<UUID> {
    if mode != .timeline { return weekScheduled.values.reduce(into: Set<UUID>()) { $0.formUnion($1) } }
    return Set(store.blocks.compactMap { block in
      if case .task(let id) = block.kind { return id }
      return nil
    })
  }

  private func acceptDrawerDrop(_ payload: String) -> Bool {
    let parts = payload.split(separator: "@", omittingEmptySubsequences: false)
    guard let raw = parts.first, let id = UUID(uuidString: String(raw)) else { return false }
    if parts.count == 1, mode == .timeline {
      return returnScheduledTask(id, from: Calendar.current.startOfDay(for: store.now))
    }
    guard parts.count == 2, let stamp = Int(parts[1]),
          let source = weekScheduled.keys.first(where: { Int($0.timeIntervalSince1970) == stamp }) else { return false }
    return returnScheduledTask(id, from: source)
  }

  private func returnScheduledTask(_ id: UUID, from day: Date) -> Bool {
    guard mode == .timeline ? scheduledDrawerIDs.contains(id) : weekScheduled[day]?.contains(id) == true,
          store.returnToTaskDrawer(id, from: day) else { return false }
    returnedTask = id
    drawerTask = nil
    weekDrag.end()
    taskDrawerExpanded = true
    moveMessage = nil
    dropAlternative = nil
    completionFeedback += 1
    return true
  }

  private func newDrawerTask() {
    var task = PlanTask("", minutes: 25)
    task.inboxOnly = true
    returnedTask = task.id
    drawerTask = nil
    taskDraft = task
    taskDrawerExpanded = true
  }

  @ViewBuilder private var moveFeedback: some View {
    if let moveMessage, !movingTask {
      ViewThatFits(in: .horizontal) {
        HStack { Text(moveMessage); feedbackAction }
        VStack(alignment: .leading) { Text(moveMessage); feedbackAction }
      }
      .font(.footnote).padding(.horizontal, 16).padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(Color.surface).background(store.sky.ground)
      .accessibilityElement(children: .contain)
    }
  }

  @ViewBuilder private var feedbackAction: some View {
    if let alternative = dropAlternative {
      Button(alternative.label(includeDay: false)) {
        moveToday(alternative.taskID, to: alternative.start, exact: true)
      }.accessibilityIdentifier("today-drop-alternative").frame(minHeight: 44)
    } else if let receipt = store.undoableTimeMove(for: timingSelection) {
      Button("Undo") {
        if store.undoTimeMove(receipt) { moveMessage = "Previous timing restored." }
      }.frame(minHeight: 44).accessibilityLabel("Undo time change")
    }
    Button {
      moveMessage = nil
      dropAlternative = nil
    } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
      .accessibilityLabel("Dismiss scheduling message")
  }

  private func moveToday(_ id: UUID, to hour: Date, exact: Bool = false) {
    guard !movingTask else { return }
    movingTask = true
    timingSelection = nil
    dropAlternative = nil
    let epoch = store.journalEpoch
    Task {
      defer { movingTask = false }
      if !store.calendarReadyForStart { _ = await store.refreshLiveCalendar() }
      guard epoch == store.journalEpoch else { return }
      guard store.calendarReadyForStart else {
        moveMessage = "Calendar couldn’t update. Try scheduling again."
        return
      }
      if await store.moveTask(id, toHour: hour, exact: exact),
         let task = store.offeredTasks.first(where: { $0.id == id }), let start = task.plannedStart {
        taskDrawerExpanded = false
        timingSelection = id
        moveMessage = task.title + " scheduled for " + start.formatted(date: .omitted, time: .shortened) + "."
      } else {
        let options = await store.timingOptions(for: id)
        guard epoch == store.journalEpoch else { return }
        dropAlternative = TimeDropSuggestion(for: store.timingTask(id), from: store.now, day: store.now, hour: hour, options: options)
        moveMessage = store.blockedDropMessage(taskID: id, day: store.now, hour: hour, exact: exact)
      }
    }
  }

  private var viewMenu: some View {
    JournalTitleMenu(title: mode == .timeline ? "Today’s plan" : mode.rawValue) {
      Picker("Plan view", selection: $mode) {
        ForEach(PlanMode.allCases, id: \.self) { option in Text(option.rawValue).tag(option) }
      }
      Divider()
      Button("Time blocks", systemImage: "calendar.badge.clock") { panel = .timeBlocks }
      Button("To-do dump", systemImage: "tray.and.arrow.down") { panel = .todoDump }
      Button("Skip history", systemImage: "clock.arrow.circlepath") { panel = .skipHistory }
      Button("Picture log", systemImage: "photo.on.rectangle") { panel = .photoLog }
      Button("Close out today", systemImage: "sunset") { panel = .dayClose }
    }
    .sensoryFeedback(.selection, trigger: regenerated)
    .accessibilityIdentifier("plan-view")
  }

  private func itemRow(_ title: String, icon: String?, customIcon: TaskIcon? = nil, detail: String, showsChevron: Bool = true) -> some View {
    HStack(spacing: 14) {
      if let icon { Image(systemName: icon).foregroundStyle(store.sky[10]).frame(width: 22) }
      VStack(alignment: .leading, spacing: 5) {
        TaskIconTitle(title: title, icon: customIcon).font(.headline.weight(.medium))
        Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.72))
      }
      Spacer()
      if showsChevron { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
    }.padding(.vertical, 14).contentShape(Rectangle())
  }
}

struct AddScreen: View {
  @Environment(Workspace.self) var store
  @Environment(\.dismiss) var dismiss
  let blockDay: Date
  var provider: (any DayInputProvider)?
  @State private var requestedInput: String?
  @State var input = ""
  @State var draft: DayDraft?
  var body: some View {
    Form {
      Section("Add individually") {
        NavigationLink {
          TaskEditor(task: PlanTask("", minutes: 25), isNew: true, closeAll: { dismiss() })
        } label: {
          Label("Task", systemImage: "checklist")
        }
        NavigationLink {
          EventEditor(
            event: Commitment("", start: .now, end: .now.addingTimeInterval(3600)), isNew: true,
            closeAll: { dismiss() })
        } label: {
          Label("Fixed commitment", systemImage: "lock")
        }
        NavigationLink {
          TimeBlockEditor(newOn: blockDay, startHour: store.journal.planningStartHour ?? 9,
                          onSave: input.isEmpty ? { dismiss() } : nil)
        } label: {
          Label("New time block", systemImage: "calendar.badge.plus")
        }.accessibilityIdentifier("add-plan-new-block")
        NavigationLink("Templates and routines") { TaskLibrary(closeAll: { dismiss() }) }
      }
      Section("Describe your day") {
        TextField(
          "I have school until 3, need to study chemistry, and want to work on my app.",
          text: $input,
          axis: .vertical
        )
        .lineLimit(3...6).onChange(of: input) {
          draft = nil
          requestedInput = nil
        }
        Button("Preview plan") { requestedInput = input }.disabled(
          input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let draft {
        Section("Review before adding") {
          ForEach(draft.commitments) { event in
            VStack(alignment: .leading, spacing: 3) {
              Label(event.title, systemImage: "lock")
              Text(
                event.start.formatted(date: .abbreviated, time: .shortened) + " to "
                  + event.end.formatted(
                    date: Calendar.current.isDate(event.start, inSameDayAs: event.end)
                      ? .omitted : .abbreviated, time: .shortened)
                  + (event.recurrence == .once ? "" : " · " + event.recurrence.rawValue)
              )
              .font(.caption).foregroundStyle(Color.moss)
            }
          }
          ForEach(draft.tasks) { task in
            VStack(alignment: .leading, spacing: 3) {
              Label(
                "\(task.title) · \(task.minutes) min" + (task.captureRecurrence().map { " · " + $0 } ?? ""),
                systemImage: task.category.symbol)
              if let timing = task.captureTiming {
                Text(timing).font(.caption).foregroundStyle(Color.moss)
              }
            }
          }
          ForEach(Array(draft.unrecognized.enumerated()), id: \.offset) { _, s in
            Text(draft.clarification(for: s)).foregroundStyle(Color.clay)
          }
          if !draft.tasks.isEmpty || !draft.commitments.isEmpty {
            Button("Add these items") {
              store.change {
                $0.tasks += draft.tasks
                $0.events += draft.commitments
                $0.starterAvailable = false
              }
              dismiss()
            }.disabled(!draft.unrecognized.isEmpty)
          }
        }
      }
      NavigationLink("To-do dump") { TodoDumpScreen { dismiss() } }
      Section("Planning assistant") {
        NavigationLink("Talk through your day") { PlanningAssistantScreen() }
      }
    }
    .task(id: requestedInput) {
      guard let text = requestedInput else { return }
      do {
        let parser = provider ?? LocalDayInput(commitments: store.planningEvents)
        let result = try await parser.draft(text, at: .now, calendar: .current)
        if !Task.isCancelled && text == input { draft = result }
      } catch {
        if !Task.isCancelled {
          store.notice = "The plan couldn’t be prepared. Try again or add an item individually."
          requestedInput = nil
        }
      }
    }
    .formPaper().navigationTitle("Add to plan").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
  }
}
