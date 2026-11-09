import PulseEngine
import SwiftUI

struct TodayScreen: View {
  @Environment(PrivacySession.self) private var privacy
  @Environment(Workspace.self) var store
  @Environment(\.dynamicTypeSize) var type
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 38
  @Binding var panel: Panel?
  let openPlan: (PlanMode) -> Void
  @Binding var focusVisible: Bool
  @Environment(\.accessibilityReduceMotion) private var reduced
  private var inFocus: Bool { store.journal.active != nil && focusVisible }
  @State private var deferMenu = false
  @State private var easier: EasierSuggestion?
  @AccessibilityFocusState private var suggestionFocused: Bool
  @State private var photoSession: ActiveSession?
  @State private var finishing = false
  @State private var sleepSetup = false
  @State private var walkthrough = false
  @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.22, extraBounce: 0)))
  private var focusPull: CGFloat = 0

  @State private var boostToLog: EnergyActivity?

  private var activeTimeBlock: Block? {
    guard store.journal.active == nil, !store.isRestDay, !(store.journal.timeBlocks ?? []).isEmpty else { return nil }
    let active = store.blocks.filter { $0.start <= store.now && store.now < $0.end }
    for desired in [WeeklyTimeBlock.Role.protected, .boost] {
      if let block = active.first(where: { if case .timeBlock(_, let role) = $0.kind { role == desired } else { false } }) { return block }
    }
    return nil
  }

  private enum TodayAction: Hashable {
    case recovery
    case timeBlock(String)
    case easier(UUID)
    case session(UUID)
    case task(UUID, available: Bool)
    case rest, open
  }

  private var actionIdentity: TodayAction {
    if let session = store.journal.active { return .session(session.taskID) }
    if store.liveRecovery != nil && !store.isRestDay { return .recovery }
    if let block = activeTimeBlock { return .timeBlock(block.id) }
    if let visibleSuggestion { return .easier(visibleSuggestion.taskID) }
    if let (task, block) = store.next { return .task(task.id, available: store.canStart(block)) }
    return store.isRestDay ? .rest : .open
  }

  private var visibleSuggestion: EasierSuggestion? {
    guard let easier, store.journal.active == nil, !store.isRestDay, store.liveRecovery == nil,
          store.next?.0.id == easier.originalID else { return nil }
    return easier
  }

  private var pullToReturn: AnyGesture<DragGesture.Value> {
    AnyGesture(
      DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .updating($focusPull) { value, pulled, transaction in
          transaction.animation = nil
          pulled = reduced ? 0 : max(0, value.translation.height)
        }
        .onEnded { value in
          if value.translation.height > 72
            || (value.translation.height > 20 && value.predictedEndTranslation.height > 130)
          {
            focusVisible = false
          }
        }
    )
  }

  var body: some View {
    GeometryReader { viewport in
      let reveal = min(1, focusPull / max(120, viewport.size.height * 0.24))
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          controls.opacity(inFocus ? reveal : 1)
          if !inFocus && !store.isDemo && !privacy.sleepSetupFinished {
            let estimate = store.energyTimeline.estimate(at: store.now)
            Button { sleepSetup = true } label: {
              HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                  Capsule().fill(Color.surface.opacity(0.24))
                  if let estimate {
                    Capsule().fill(Color.trailAmber).frame(height: 84 * estimate.score / 10)
                  }
                }.frame(width: 12, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                  Text(estimate?.source == .reported ? "Reported energy" : estimate?.source == .corrected ? "Corrected energy" : "Estimated energy").font(.caption.weight(.semibold))
                  if let estimate {
                    Text("\(Int(estimate.score.rounded())) / 10").font(.title2.monospacedDigit())
                  } else { Label("Sleep setup", systemImage: "moon.stars").font(.headline) }
                }
              }.padding(12).foregroundStyle(Color.surface)
                .background(store.sky.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityIdentifier("sleep-setup-badge").padding(.horizontal, 26)
          }
          Spacer(minLength: type.isAccessibilitySize ? 60 : viewport.size.height * 0.23)
          VStack(alignment: .leading, spacing: 0) {
            if let recovery = store.liveRecovery, !store.isRestDay, store.journal.active == nil {
              VStack(alignment: .leading, spacing: 6) {
                Text("Breathing room").font(displayFont).tracking(-0.7)
                Text("Until \(recovery.end.formatted(date: .omitted, time: .shortened))")
                  .font(.subheadline).foregroundStyle(Color.surface.opacity(0.86))
                if store.canNameIntention {
                  let actions = type >= .xLarge || viewport.size.width < 365
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 16))
                  actions { intentionBreakActions }.padding(.top, 12)
                } else {
                  SceneButton(title: "End break", icon: "forward.end.fill") {
                    store.change { $0.recovery = nil }
                  }.padding(.top, 12)
                }
              }
            } else if let block = activeTimeBlock, case .timeBlock(_, let role) = block.kind {
              timeBlockAction(block, role: role)
            } else if let visibleSuggestion {
              easierAction(visibleSuggestion)
            } else {
              action
            }
            if store.journal.active == nil, let last = store.journal.sessions.last,
               Calendar.current.isDate(last.finishedAt ?? last.start, inSameDayAs: store.now) {
              SprintCapturesButton(sessionID: last.id, onLandscape: true) { panel = .sprintCaptures(last.id) }
            }
          }
          .id(actionIdentity)
          .transition(.opacity)
          .animation(reduced || inFocus ? nil : .easeOut(duration: 0.18), value: actionIdentity)
          .foregroundStyle(Color.surface)
          .frame(maxWidth: 580, alignment: .leading)
          .padding(.horizontal, 26)
          .padding(.bottom, 25)
          .frame(maxWidth: .infinity)
          .background(alignment: .bottom) {
            LinearGradient(colors: [store.sky.ground.opacity(0), store.sky.ground.opacity(0.93), store.sky.ground],
                           startPoint: .top, endPoint: .bottom)
              .padding(.top, -62)
          }
          .opacity(inFocus ? reveal : 1)
        }
        .frame(minHeight: viewport.size.height, alignment: .top)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .scrollDisabled(inFocus)
      .accessibilityHidden(inFocus)
      .allowsHitTesting(!inFocus)
      .background(alignment: .top) {
        LookoutLandscape(sky: store.sky, energy: store.latest?.energy ?? 5, theme: store.landscapeTheme)
          .equatable()
          .frame(width: viewport.size.width, height: max(220, viewport.size.height * 0.88))
          .allowsHitTesting(false)
      }
      .overlay {
        ZStack {
          if inFocus, let session = store.journal.active {
            FocusScreen(
              session: session, minimize: { focusVisible = false }, pullToReturn: pullToReturn,
              capture: { panel = .distraction(session) }, skip: { panel = .taskSkip($0) }, finishing: $finishing
            ) {
              let needsPhoto = store.needsCompletionPhoto(for: session)
              Button(needsPhoto ? "Complete with photo" : (session.stepID == nil ? "Mark task complete" : "Finish step")) {
                store.finish(done: true)
              }
              Button("Save progress for later") { store.finish(done: false) }
              if let candidate = store.skipCandidate(for: session.taskID) {
                Button("Skip for today") { panel = .taskSkip(candidate) }
              }
              if !needsPhoto { Button("Finish with a photo") { photoSession = session } }
              Button("Leave a note and finish") { panel = .resumeNote(session) }
              Button("Cancel", role: .cancel) {}
            }
            .offset(y: focusPull)
            .opacity(1 - 0.8 * reveal)
            .transition(reduced ? .identity : .opacity.combined(with: .offset(y: 14)))
          }
        }
        .allowsHitTesting(inFocus)
        .accessibilityHidden(!inFocus)
      }
      .animation(reduced ? nil : .easeInOut(duration: 0.26), value: inFocus)
    }
    .background(store.sky.ground)
    .completionProofSheet(active: panel == nil && photoSession == nil)
    .sheet(isPresented: $sleepSetup) { SleepOnboarding {} }
    .sheet(isPresented: $walkthrough) { NavigationStack { PulseWalkthrough() } }
    .sheet(item: $boostToLog) { activity in NavigationStack { EnergyActivityLogEditor(activity: activity) } }
    .onChange(of: store.now) {
      if let easier, store.easierSuggestion(for: easier.originalID) != easier { self.easier = nil }
    }
    .onChange(of: store.journal.active?.started) { easier = nil }
    .onChange(of: store.next?.0.id) { if store.next?.0.id != easier?.originalID { easier = nil } }
    .sheet(isPresented: Binding(get: { photoSession != nil }, set: { if !$0 { photoSession = nil } })) {
      if let photoSession { NavigationStack { CompletionPhotoScreen(session: photoSession) } }
    }

  }

  private func easierAction(_ choice: EasierSuggestion) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(choice.title)
        .font(displayFont).tracking(-0.7).lineSpacing(-2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader).accessibilityFocused($suggestionFocused)
      Text(choice.detail)
        .font(.subheadline).foregroundStyle(Color.surface.opacity(0.86))
        .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 20) { easierButtons(choice) }
        VStack(alignment: .leading, spacing: 4) { easierButtons(choice) }
      }.padding(.top, 11)
    }
    .onAppear { suggestionFocused = true }
  }

  @ViewBuilder private func easierButtons(_ choice: EasierSuggestion) -> some View {
    SceneButton(title: "Start · \(choice.minutes) min", icon: "play.fill") {
      let started = store.startEasierSuggestion(choice)
      easier = nil
      if started { focusVisible = true }
      else { store.notice = "This option no longer fits. Your plan has been refreshed." }
    }
    Button { easier = nil } label: {
      Text("Undo").font(.subheadline.weight(.semibold))
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
      .accessibilityHint("Return to the previous suggestion")
  }

  private var displayFont: Font { .system(size: titleSize, weight: .regular) }

  @ViewBuilder private var intentionBreakActions: some View {
    SceneButton(title: "Add your task", icon: "plus") { panel = .nameIntention }
    Button { store.change { $0.recovery = nil } } label: {
      Text("End break").font(.subheadline.weight(.medium))
        .foregroundStyle(Color.surface).padding(.horizontal, 12).padding(.vertical, 6)
        .background(store.sky.ground, in: Capsule())
        .frame(minHeight: 48).contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(Color.surface)
  }

  private var controls: some View {
    let ink = store.sky.usesLightHeaderInk ? Color.surface : Color.pine
    return HStack(spacing: 2) {
      Button {
        panel = .overview
      } label: {
        HStack(spacing: 4) {
          if type >= .xxLarge {
            Image(systemName: "calendar").font(.system(size: 23, weight: .medium))
          } else {
            Text(store.journal.preferredName.flatMap { $0.isEmpty ? nil : "Hi, " + $0 }
              ?? store.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
              .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down").font(.caption2)
          }
        }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
      }.accessibilityLabel("Day overview")
        .accessibilityValue(store.now.formatted(date: .complete, time: .omitted))
      Spacer(minLength: 4)
      Button {
        panel = .checkIn
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "waveform.path").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          if type < .xxLarge {
            Text(store.latest.map { "\(Int($0.energy))/10" } ?? "Check in").fixedSize()
          }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(ink.opacity(0.08), in: Capsule())
        .frame(minHeight: 44).contentShape(Rectangle())
      }
      .accessibilityLabel("Check in")
      .accessibilityValue(store.latest.map { "Energy \(Int($0.energy)) out of 10" } ?? "")
      .accessibilityIdentifier("check-in")
      Button {
        panel = .capture
      } label: {
        Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge).frame(width: 44, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("Quick add")
      Button {
        panel = .settings
      } label: {
        Image(systemName: "slider.horizontal.3").font(.body.weight(.medium)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .frame(width: 44, height: 44).contentShape(Circle())
      }.accessibilityLabel("Settings")
    }
    .foregroundStyle(ink).buttonStyle(PressStyle())
    .padding(.leading, 26).padding(.trailing, 16).padding(.top, 4)
  }

  private func startSmall(_ task: PlanTask) {
    if store.startSmall(taskID: task.id) {
      focusVisible = true
    } else {
      store.notice = "This block is no longer available. Your plan has been refreshed."
    }
  }

  private func openSprintButton(seconds: Double) -> some View {
    let duration = Int(seconds / 60)
    let title = "Open sprint · \(duration) min"
    return SceneButton(title: title, icon: "play.fill") {
      if store.startOpenSprint() { focusVisible = true }
      else { store.notice = "This opening has changed. Check your timeline." }
    }
    .accessibilityLabel("Start open sprint")
    .accessibilityValue("\(duration) minutes")
    .accessibilityHint("Focus without choosing a task")
    .accessibilityIdentifier("start-open-sprint")
  }

  private func timeBlockAction(_ block: Block, role: WeeklyTimeBlock.Role) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(block.title).font(displayFont).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      let end = block.end.formatted(date: .omitted, time: .shortened)
      Text(block.title == role.label ? "Until " + end : role.label + " · Until " + end)
        .font(.subheadline).foregroundStyle(Color.surface)
      if role == .boost, case .timeBlock(let id, _) = block.kind,
         let rule = store.journal.timeBlocks?.first(where: { $0.id == id }),
         let activity = store.energyActivities.first(where: { $0.id == rule.boostActivityID }),
         !(store.journal.energyActivityLogs ?? []).contains(where: { $0.activity.id == activity.id && block.start <= $0.started && $0.started < block.end }) {
        SceneButton(title: "Log activity", icon: "leaf") { boostToLog = activity }.padding(.top, 8)
      } else {
        SceneButton(title: "View plan", icon: "calendar") { openPlan(.timeline) }.padding(.top, 8)
      }
    }
  }

  @ViewBuilder private var action: some View {
    let active = store.journal.active
    let next = store.next
    let newJournal = store.journal.tasks.isEmpty && store.journal.sessions.isEmpty && store.journal.events.isEmpty
    VStack(alignment: .leading, spacing: 0) {
      Text(
        active?.title ?? next?.0.title ?? (store.isRestDay ? "A day to rest" : newJournal ? "Your first task" : "Room to breathe")
      )
      .font(displayFont).tracking(-0.7).lineSpacing(-2)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
      if let active {
        Text("\(Int(active.target/60)) min · \(active.wallAnchor == nil ? "Paused" : "In focus")")
          .font(.subheadline).foregroundStyle(Color.white.opacity(0.78))
        SceneButton(title: "Return to focus", icon: "play.fill", action: { focusVisible = true })
          .padding(
            .top, 11)
      } else if let (task, block) = next {
        let available = store.canStart(block)
        let openSeconds = available ? 0 : store.openSprintSeconds(at: store.now)
        if let cue = task.resumeNote ?? task.resumeStep?.title {
          Label(cue, systemImage: "bookmark")
            .font(.subheadline).foregroundStyle(Color.surface.opacity(0.9))
            .lineLimit(type.isAccessibilitySize ? nil : 2)
            .padding(.top, 5)
            .accessibilityLabel("Pick up here: " + cue)
            .accessibilityIdentifier("today-return-cue").privacySensitive()
        }
        let detailLayout = type.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
          : AnyLayout(HStackLayout(spacing: 12))
        detailLayout {
          Button {
            panel = .focusSetup(task.id)
          } label: {
            HStack(spacing: 7) {
              TaskIconView(icon: task.icon, fallback: task.category.symbol).font(.caption).foregroundStyle(Color.trailAmber)
              Text(
                "\(block.minutes) min · \(task.category.rawValue)"
                  + (available ? "" : " · \(block.start.formatted(date:.omitted,time:.shortened))"))
              Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline).foregroundStyle(Color.surface).frame(minHeight: 44)
          }.accessibilityLabel("Focus options and smaller steps")
          if !type.isAccessibilitySize { Spacer(minLength: 4) }
          Button { deferMenu = true } label: {
            Text("Not now").font(.subheadline.weight(.medium))
              .foregroundStyle(Color.surface).padding(.horizontal, 12).padding(.vertical, 6)
              .background(store.sky.ground, in: Capsule())
              .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
          }
            .buttonStyle(.plain).foregroundStyle(Color.surface)
            .confirmationDialog("Not now", isPresented: $deferMenu) {
              if let candidate = store.skipCandidate(for: task.id) {
                Button("Skip for today") { panel = .taskSkip(candidate) }
              }
              if available {
                Button("Something easier") {
                  store.now = .now
                  if let choice = store.easierSuggestion(for: task.id) { easier = choice }
                  else { store.notice = "This block is no longer available." }
                }
              }
              Button("Find a shorter task") { panel = .spareMoment }
              Button("Try a smaller step") { panel = .focusSetup(task.id, tiny: true) }
              Button("In 30 minutes") {
                store.recordVote(.later, task: task)
                store.deferTask(task, to: .now.addingTimeInterval(1800))
              }
              Button("Tomorrow") {
                store.deferTask(task, to: Calendar.current.dateInterval(of: .day, for: .now)!.end)
              }
              Button("Rest for today") { store.change { $0.restDate = .now } }
              Button("Cancel", role: .cancel) {}
            }
        }
        let actionLayout = type >= .xLarge
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
          : AnyLayout(HStackLayout(spacing: 20))
        actionLayout {
          if store.canNameIntention {
            SceneButton(title: "Add your task", icon: "plus") { panel = .nameIntention }
          } else if openSeconds >= 60 {
            openSprintButton(seconds: openSeconds)
            Button("View plan") { openPlan(.timeline) }
              .font(.subheadline.weight(.medium)).frame(minHeight: 48)
          } else if !available {
            SceneButton(title: "View plan", icon: "calendar") { openPlan(.timeline) }
          }
          if available {
            let duration = min(2, block.minutes)
            let shortTitle = "\(duration) min sprint"
            if store.canNameIntention {
              Button { startSmall(task) } label: {
                Text(shortTitle).font(.subheadline.weight(.medium))
                  .frame(minHeight: 48).contentShape(Rectangle())
              }
              .accessibilityLabel("Start small").accessibilityIdentifier("start-small")
            } else {
              SceneButton(title: shortTitle, icon: "play.fill") { startSmall(task) }
                .fixedSize(horizontal: type < .xLarge, vertical: true)
                .accessibilityLabel("Start small")
                .accessibilityInputLabels([Text(shortTitle), Text("Start small")])
                .accessibilityHint(task.resumeStep.map { "Return to " + $0.title }
                  ?? "Focus on the first step for up to \(duration) minutes")
                .accessibilityIdentifier("start-small")
              Button {
                store.start(task, block: block)
                if store.journal.active?.taskID == task.id { focusVisible = true }
              } label: {
                Text("Start \(block.minutes) min")
                  .font(.subheadline.weight(.medium))
                  .padding(.horizontal, 8).frame(minHeight: 48).contentShape(Rectangle())
              }
              .buttonStyle(PressStyle())
              .accessibilityLabel("Start")
              .accessibilityValue("Full \(block.minutes)-minute block")
            }
          }
        }.padding(.top, 11)

      } else {
        let needsTask = store.journal.tasks.allSatisfy { $0.done || $0.archived == true }
        let wrappedUp = store.journal.wrapUpMinute != nil && store.now >= store.preferences.workEnd(on: store.now)
        let nextAction = needsTask ? "Add a task" : (wrappedUp ? "See tomorrow" : "Open planner")
        let openSeconds = store.isRestDay ? 0 : store.openSprintSeconds(at: store.now)
        let openPlannerOrCapture = {
          if needsTask { panel = .capture }
          else { openPlan(wrappedUp ? .tomorrow : .timeline) }
        }
        if newJournal && !store.isRestDay {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { firstActions(openSeconds: openSeconds) }
            VStack(alignment: .leading, spacing: 4) { firstActions(openSeconds: openSeconds) }
          }.padding(.top, 11)
          Button("Take the walkthrough") { walkthrough = true }
            .font(.subheadline).frame(minHeight: 44)
        } else if openSeconds >= 60 {
          let layout = type >= .xLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
            AnyLayout(HStackLayout(spacing: 18))
          layout {
            openSprintButton(seconds: openSeconds)
            Button(nextAction, action: openPlannerOrCapture).font(.subheadline.weight(.medium)).frame(minHeight: 48)
          }.padding(.top, 11)
        } else {
          SceneButton(title: store.isRestDay ? "Resume planning" : nextAction,
                      icon: !store.isRestDay && needsTask ? "plus" : "calendar") {
            if store.isRestDay { store.change { $0.restDate = nil } }
            else { openPlannerOrCapture() }
          }.padding(.top, 11)
        }
      }
    }
    .foregroundStyle(Color.surface)
  }

  @ViewBuilder private func firstActions(openSeconds: Double) -> some View {
    SceneButton(title: "Add a task", icon: "plus") { panel = .capture }
    if openSeconds >= 60 {
      Button("Open sprint") {
        if store.startOpenSprint() { focusVisible = true }
        else { store.notice = "This opening has changed. Check your timeline." }
      }.font(.subheadline.weight(.medium)).frame(minWidth: 48, minHeight: 48)
        .accessibilityLabel("Start open sprint").accessibilityIdentifier("start-open-sprint")
    }
  }

}

struct SceneButton: View {
  var title: String
  var icon: String
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Text(title).font(.headline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        Image(systemName: icon).font(.subheadline.weight(.semibold))
      }
      .padding(.horizontal, 22).frame(minWidth: 130, minHeight: 50)
      .background(Color.trailAmber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .foregroundStyle(Color.pine)
    }.buttonStyle(PressStyle())
  }
}
