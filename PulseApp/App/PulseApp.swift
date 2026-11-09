import PulseEngine
import SwiftUI

@main
struct PulseApp: App {
    @State private var workspace = Workspace.live
    @UIApplicationDelegateAdaptor(ReminderDelegate.self) private var reminders
    var body: some Scene {
        WindowGroup {
            JournalHost().environmentObject(reminders).environment(workspace).disabled(
                workspace.restoring
            )
                .foregroundStyle(Color.journalInk).tint(.journalAccent)
                .onOpenURL { PulseSystemRouter.shared.open($0) }
        }
    }
}

enum SectionTab: String, CaseIterable {
    case today = "Today"
    case plan = "Plan"
    case health = "Health"
    var symbol: String {
        switch self {
        case .today: "sun.horizon"
        case .plan: "calendar.day.timeline.left"
        case .health: "heart"
        }
    }
}

enum Panel: Identifiable {
    case add(Date)
    case checkIn, settings, overview, capture, nameIntention, spareMoment, dayClose, photoLog, todoDump
    case focusSetup(UUID, tiny: Bool = false)
    case resumeNote(ActiveSession)
    case distraction(ActiveSession)
    case sprintCaptures(UUID)
    case timeBlocks, timeBlock(UUID)
    case taskSkip(TaskSkipCandidate), skipHistory, dueToSkip
    case weeklyTiming(UUID, Date?)
    case taskTiming(UUID)
    case taskIcon(UUID)
    case task(PlanTask)
    case commitment(Commitment, occurrence: TaskPreparation? = nil)
    case preparation(PreparationPresentation)

    var id: String {
        switch self {
        case .resumeNote(let session): "resume-note-" + session.taskID.uuidString
        case .taskSkip(let candidate): "skip-" + candidate.taskID.uuidString
        case .skipHistory: "skip-history"
        case .dueToSkip: "due-to-skip"
        case .spareMoment: "spare-moment"
        case .todoDump: "todo-dump"
        case .photoLog: "picture-log"
        case .dayClose: "close-day"
        case .overview: "overview"
        case .capture: "capture"
        case .nameIntention: "name-intention"
        case .distraction(let session): "distraction-" + SurfaceData.focusID(task: session.taskID, started: session.started)
        case .sprintCaptures(let id): "sprint-captures-" + id.uuidString
        case .focusSetup(let id, let tiny): (tiny ? "step-" : "start-") + id.uuidString
        case .checkIn: "check-in"
        case .settings: "settings"
        case .timeBlocks: "time-blocks"
        case .timeBlock(let id): "time-block-" + id.uuidString
        case .add: "add"
        case .weeklyTiming(let id, let day): "week-timing-" + id.uuidString + (day.map { String($0.timeIntervalSinceReferenceDate) } ?? "")
        case .taskTiming(let id): "timing-" + id.uuidString
        case .taskIcon(let id): "task-icon-" + id.uuidString
        case .task(let task): "task-" + task.id.uuidString
        case .commitment(let event, let occurrence): "event-" + event.id.uuidString + "-" + String(occurrence?.occurrenceIndex ?? -1)
        case .preparation(let route): "prep-" + route.link.commitmentID.uuidString + "-" + String(route.link.occurrenceIndex)
        }
    }
}
struct RootView: View {
    @Environment(PrivacySession.self) private var privacy
    @Environment(Workspace.self) var store
    @EnvironmentObject private var reminders: ReminderDelegate
    @EnvironmentObject private var homeActions: QuickActionSceneDelegate
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) var phase
    @SceneStorage var tab: String
    @SceneStorage private var planMode: PlanMode
    @SceneStorage var focusVisible: Bool
    private let demo: Bool
    @State var panel: Panel?
    @State private var tabDirection: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var tabIconSize: CGFloat = 22
    @Namespace private var navigationMark
    @ObservedObject private var surfaces = PulseSystemRouter.shared
    @State private var tabBarHeight: CGFloat = 55
    private struct PlanningActivity: Equatable {
        let phase: ScenePhase
        let automatic: Bool
    }
    private var navigationGround: Color { store.sky.ground }
    private var inFocus: Bool {
        focusVisible && tab == SectionTab.today.rawValue && store.journal.active != nil
    }

    init(demo: Bool = false) {
        self.demo = demo
        var prefix = "pulse"
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["PULSE_TEST_JOURNAL"], let journalID = UUID(uuidString: value) {
            prefix += "." + journalID.uuidString
        }
        #endif
        if demo { prefix += ".demo" }
        _tab = SceneStorage(wrappedValue: SectionTab.today.rawValue, prefix + ".section")
        _planMode = SceneStorage(wrappedValue: PlanMode.timeline, prefix + ".plan.mode")
        _focusVisible = SceneStorage(wrappedValue: true, prefix + ".focus.visible")
    }

    var body: some View {
        Group {
            if store.ready {
                VStack(spacing: 0) {
                    ZStack {
                        Group {
                            switch SectionTab(rawValue: tab) ?? .today {
                            case .today:
                                TodayScreen(
                                    panel: $panel, openPlan: { mode in
                                        planMode = mode
                                        selectTab(SectionTab.plan.rawValue)
                                    },
                                    focusVisible: $focusVisible)
                            case .plan: PlanScreen(panel: $panel, mode: $planMode, openFocus: showFocus)
                            case .health: NavigationStack { HealthEnergyScreen() }
                            }
                        }
                        .id(tab)
                        .transition(
                            reduced
                                ? .identity
                                : .asymmetric(
                                    insertion: .opacity.combined(with: .offset(x: 22 * tabDirection)),
                                    removal: .opacity.combined(with: .offset(x: -14 * tabDirection))))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .animation(reduced ? nil : .snappy(duration: 0.26, extraBounce: 0), value: tab)
                    ZStack {
                        if inFocus {
                            Color.clear.frame(height: tabBarHeight).accessibilityHidden(true)
                        } else {
                            tabBar
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.size.height
                                } action: {
                                    tabBarHeight = $0
                                }
                                .transition(.opacity)
                        }
                    }
                    .animation(reduced ? nil : .easeOut(duration: 0.18), value: inFocus)

                }
            } else if let failure = store.loadFailure {
                ContentUnavailableView {
                    Label("Open your journal", systemImage: "book.closed")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { Task { await store.load() } }
                }
            } else {
                ProgressView("Opening your journal")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if store.ready {
                store.sky.canvasBackground.ignoresSafeArea()
            } else {
                Color.paper.ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            if store.ready {
                GeometryReader { viewport in
                    store.sky.upperSky.frame(height: viewport.safeAreaInsets.top)
                        .offset(y: -viewport.safeAreaInsets.top)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay { TaskCompletionCue().frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true) }
        .onChange(of: privacy.automaticHealthPlanning && !privacy.lockConnections && !store.isDemo, initial: true) {
            store.automaticallyPlanEnergy = privacy.automaticHealthPlanning && !privacy.lockConnections && !store.isDemo
            store.now = .now
        }
        .onChange(of: store.healthController.revision) {
            if store.automaticallyPlanEnergy || store.healthPlanningToday { store.now = .now }
        }
        .task(id: surfaces.request) {
            await store.load()
            guard !Task.isCancelled else { return }
            await openSurface()
        }
        .task {
            await store.load()
            openReminder()
        }
        .onAppear {
            if demo { tab = SectionTab.today.rawValue; planMode = .timeline; focusVisible = true }
            else if tab == "Insights" { tab = SectionTab.health.rawValue }
        }
        .task(id: homeActions.request) {
            guard let id = homeActions.request else { return }
            await store.load()
            guard store.ready, !Task.isCancelled, let action = homeActions.take(id) else { return }
            privacy.followDirectAction()
            panel = nil
            tab = SectionTab.today.rawValue
            switch action {
            case .capture: panel = .capture
            case .checkIn: panel = .checkIn
            case .startSmall: await openSmallFocus()
            }
        }
        .onChange(of: store.journal.photos?.count ?? 0) { previous, current in
            if current < previous && store.waitingForPhotoSpace { Task { await store.receiveSharedCaptures() } }
        }
        .onChange(of: reminders.destination) { openReminder() }
        .onChange(of: phase) { if phase != .active { store.flushCaptureDrafts() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if phase == .active && store.ready { store.regenerate() }
        }
        .modifier(LiveCalendarUpdates())
        .modifier(LiveReminderUpdates())
        .task(id: PlanningActivity(phase: phase, automatic: store.automaticallyPlanEnergy)) {
            guard phase == .active else { return }
            store.recheckSystemSurfacesOnActivation()
            await store.receiveSharedCaptures()
            if store.ready && store.canSync { PrivateSync.shared.refresh(store: store) }
            while !Task.isCancelled {
                store.now = .now
                if privacy.sleepConnected && !privacy.lockConnections && !store.isDemo {
                    await store.healthController.refreshSleep()
                }
                if store.automaticallyPlanEnergy && !privacy.lockConnections && !store.isDemo {
                    await store.healthController.refresh()
                }
                do {
                    try await Task.sleep(
                        for: .seconds(60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)))
                } catch { return }
            }
        }
        .task(id: store.liveRecovery?.end) {
            guard let end = store.liveRecovery?.end else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
            store.now = .now
        }
        .sheet(item: $panel) { item in
            NavigationStack {
                switch item {
                case .checkIn: CheckInScreen()
                case .settings: SettingsScreen()
                case .timeBlocks: TimeBlocksScreen(shownAsSheet: true)
                case .timeBlock(let id):
                    if let block = store.journal.timeBlocks?.first(where: { $0.id == id }) { TimeBlockEditor(block: block) }
                    else { TimeBlocksScreen(shownAsSheet: true) }
                case .add(let day): AddScreen(blockDay: day)
                case .capture: QuickCaptureScreen()
                case .distraction(let session): QuickCaptureScreen(focusSession: session)
                case .sprintCaptures(let id): SprintCapturesScreen(sessionID: id)
                case .nameIntention: QuickCaptureScreen(namingIntention: true)
                case .overview: DayOverviewScreen(openFocus: showFocus)
                case .spareMoment:
                    SpareMomentScreen(onStart: showFocus).toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { panel = nil } }
                    }
                case .todoDump: TodoDumpScreen { panel = nil }
                case .photoLog:
                    PictureLogScreen().toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { panel = nil } label: {
                                Image(systemName: "checkmark").font(.headline).frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel("Done")
                        }
                    }
                case .dayClose:
                    DayCloseScreen().toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } }
                    }
                case .resumeNote(let session): FocusResumeNoteScreen(session: session, finishAfterSaving: true)
                case .focusSetup(let id, let tiny):
                    FocusSetupScreen(
                        taskID: id, initiallyTiny: tiny,
                        opened: showFocus)
                case .taskSkip(let candidate): TaskSkipSurvey(candidate: candidate)
                case .dueToSkip:
                    DueTaskSkipList { panel = .taskSkip($0) }.toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { panel = nil } }
                    }
                case .skipHistory:
                    TaskSkipHistory(taskID: nil).toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } }
                    }
                case .weeklyTiming(let id, let day): WeeklyTimingSheet(taskID: id, day: day)
                case .taskTiming(let id): TaskTimingSheet(taskID: id)
                case .taskIcon(let id): SavedTaskIconPicker(taskID: id)
                case .task(let task): TaskEditor(task: task)
                case .commitment(let event, let occurrence): EventEditor(event: event, occurrence: occurrence)
                case .preparation(let route): CommitmentPreparationScreen(presentation: route)
                }
            }.foregroundStyle(Color.journalInk).tint(.journalAccent).presentationDragIndicator(.visible)
                .preferredColorScheme(store.sky.interfaceScheme)
        }
        .alert(
            "Pulse",
            isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })
        ) {
            if store.notice == Workspace.sharedPhotoSpaceNotice {
                Button("Open picture log") { panel = .photoLog }
            }
            if store.notice?.contains("saved") == true { Button("Retry save") { store.persist() } }
            Button("Close", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SectionTab.allCases, id: \.self) { item in tabButton(item) }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Color.surface.opacity(0.12)).frame(height: 0.5).allowsHitTesting(false) }
        .background(navigationGround)
    }

    private func tabButton(_ item: SectionTab) -> some View {
        let selected = tab == item.rawValue
        return Button {
            selectTab(item.rawValue)
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: min(tabIconSize, 29), weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.trailAmber : Color.surface.opacity(0.86))
                .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if selected {
                    Rectangle().fill(Color.trailAmber).frame(width: 32, height: 2)
                        .matchedGeometryEffect(id: "tab-indicator", in: navigationMark)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label(item.rawValue, systemImage: item.symbol) }
        .accessibilityIdentifier("tab-" + item.rawValue)
    }

    private func showFocus() {
        panel = nil
        tab = SectionTab.today.rawValue
        focusVisible = true
    }
    private func selectTab(_ value: String) {
        let all = SectionTab.allCases.map(\.rawValue)
        tabDirection = (all.firstIndex(of: value) ?? 0) >= (all.firstIndex(of: tab) ?? 0) ? 1 : -1
        withAnimation(reduced ? nil : .snappy(duration: 0.26, extraBounce: 0)) { tab = value }
    }
    private func openSmallFocus() async {
        panel = nil
        tab = SectionTab.today.rawValue
        if store.journal.active == nil {
            await store.refreshLiveCalendar()
            guard !Task.isCancelled else { return }
            store.regenerate()
            await store.waitForCurrentPlan()
            guard !Task.isCancelled else { return }
            if store.journal.active == nil && !store.startSmall() { store.notice = "No focus block fits right now." }
        }
        focusVisible = store.journal.active != nil
    }

    private func openSurface() async {
        guard store.ready, let request = surfaces.take(inDemo: store.isDemo) else { return }
        privacy.followDirectAction()
        switch request {
        case .startSmall: await openSmallFocus()
        case .today:
            panel = nil
            focusVisible = false
            tab = SectionTab.today.rawValue
        case .plan:
            panel = nil
            focusVisible = false
            planMode = .timeline
            tab = SectionTab.plan.rawValue
        case .focus:
            panel = nil
            focusVisible = true
            tab = SectionTab.today.rawValue
        case .focusSession(let identity), .captureDistraction(let identity):
            guard let session = store.journal.active,
                  SurfaceData.focusID(task: session.taskID, started: session.started) == identity else { return }
            if case .captureDistraction = request {
                guard store.systemPreferences.liveTimer else { return }
                panel = .distraction(session)
            } else {
                panel = nil
            }
            focusVisible = true
            tab = SectionTab.today.rawValue
        case .checkIn:
            focusVisible = false
            tab = SectionTab.today.rawValue
            panel = .checkIn
        case .taskReminder(let id, let original, let snooze):
            if snooze {
                store.snoozeSystemReminder(id, original: original)
            } else if let task = store.taskForReminder(id, original: original) {
                focusVisible = false
                tab = SectionTab.plan.rawValue
                panel = .task(task)
            }
        }
    }
    private func openReminder() {
        guard store.ready, !store.isDemo, let destination = reminders.destination else { return }
        reminders.destination = nil
        guard store.matchesFinishedFocus(task: destination.task, started: destination.started) else { return }
        panel = nil
        tab = SectionTab.today.rawValue
        focusVisible = true
    }

}
