import PulseEngine
import SwiftUI

/// Emit a final tick at the deadline. A paused or expired clock has no repeating work.
private struct FocusTicks: TimelineSchedule {
  let end: Date?
  func entries(from start: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
    sequence(first: start) { current in
      guard let end, current < end else { return nil }
      return min(current.addingTimeInterval(1), end)
    }
  }
}

/// The controls are an overlay on Today's live landscape, including on the return trip.
struct FocusScreen<FinishOptions: View>: View {
  @Environment(Workspace.self) private var store
  @Environment(\.dynamicTypeSize) private var type
  @Environment(\.scenePhase) private var phase
  @ScaledMetric(relativeTo: .largeTitle) private var clockSize = 86
  @AccessibilityFocusState private var clockFocused: Bool
  let session: ActiveSession
  var minimize: () -> Void
  var pullToReturn: AnyGesture<DragGesture.Value>
  var capture: () -> Void
  var skip: (TaskSkipCandidate) -> Void
  @Binding var finishing: Bool
  @ViewBuilder var finishOptions: () -> FinishOptions
  @State private var sound = FocusSound()
  @State private var editingNote = false
  private struct ClockRun: Equatable {
    let started: Date
    let anchor: Date?
    let target: Double
    let active: Bool
    let sound: Bool
  }
  @State private var finishedRun: ClockRun?
  @State private var captureReceipt: UUID?

  private var focusTask: PlanTask? { store.journal.tasks.first { $0.id == session.taskID } }
  private var latestCapture: UUID? {
    guard let id = session.sessionID else { return nil }
    return store.journal.tasks.last { $0.capturedDuringSessionID == id }?.id
  }

  var body: some View {
    let task = focusTask
    let remaining = max(0, session.target - store.elapsed(session))
    let run = ClockRun(started: session.started, anchor: session.wallAnchor, target: session.target,
                       active: phase == .active, sound: store.journal.ambientSound == true)
    let end: Date? =
      phase == .active && session.wallAnchor != nil && remaining > 0
      ? Date.now.addingTimeInterval(remaining + 0.12) : nil
    let savedInPlan = captureReceipt.flatMap { id in store.journal.tasks.first { $0.id == id } }
      .map { !$0.isInboxOnly && $0.hasSchedulingInstruction } ?? false
    TimelineView(FocusTicks(end: end)) { context in
      let elapsed = session.elapsed(
        now: context.date, tick: SessionClock.tick, boot: SessionClock.boot)
      let seconds = finishedRun == run ? 0 : max(0, Int(ceil(session.target - elapsed)))
      VStack(spacing: 0) {
        Button(action: minimize) {
          Capsule().fill(.white.opacity(0.62)).frame(width: 32, height: 4)
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to Today")
        .simultaneousGesture(pullToReturn)
        GeometryReader { area in
          ScrollView {
            VStack(spacing: 0) {
              let face = clock(seconds)
              FocusSweep(progress: elapsed / max(1, session.target))
                .frame(maxWidth: 340).frame(height: 49)
                .padding(.bottom, 2)
              Text(verbatim: face)
                .font(.system(size: clockSize, weight: .light, design: .rounded))
                .monospacedDigit().tracking(-3)
                .lineLimit(1).minimumScaleFactor(0.42)
                .accessibilityLabel("\(seconds / 60) minutes, \(seconds % 60) seconds remaining")
                .accessibilityFocused($clockFocused)
              if session.isOpenSprint {
                Text(session.title).font(.headline.weight(.medium)).multilineTextAlignment(.center)
                  .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
              } else {
                Menu {
                  if let url = task?.sourceURL {
                    Link(destination: url) { Label("Open source", systemImage: "arrow.up.right.square") }
                  }
                  if let candidate = store.skipCandidate(for: session.taskID) {
                    Button("Skip for today", systemImage: "forward.end") { skip(candidate) }
                  }
                  if task != nil {
                    Button("Resume note", systemImage: "note.text") { editingNote = true }
                  }
                  Divider()
                  Button("Stop and save progress", systemImage: "stop") { store.finish(done: false) }
                  if let choices = task?.steps?.filter({ !$0.done && $0.id != session.stepID }),
                     !choices.isEmpty {
                    Menu("Stop and pick up at", systemImage: "bookmark") {
                      ForEach(choices) { step in
                        Button(step.title) { store.finish(done: false, pickUpAt: step.id) }
                      }
                    }
                  }
                  if session.stepID != nil {
                    Button("More finish options", systemImage: "ellipsis.circle") { finishing = true }
                  }
                } label: {
                  HStack(spacing: 7) {
                    TaskIconTitle(title: session.title, icon: task?.icon)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                  }
                  .frame(minHeight: 44)
                }
                .accessibilityIdentifier("focus-task-menu")
                .font(.headline.weight(.medium)).tint(.surface)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
              }
              if let note = task?.resumeNote {
                Button { editingNote = true } label: {
                  Label(note, systemImage: "note.text").font(.subheadline)
                    .multilineTextAlignment(.center).lineLimit(2)
                }
                .buttonStyle(.plain).foregroundStyle(Color.surface)
                .accessibilityLabel("Resume note: " + note)
                .accessibilityHint("Edit note").accessibilityIdentifier("focus-resume-note")
                .privacySensitive()
              } else if session.stepID == nil, let step = task?.resumeStep {
                Label(step.title, systemImage: "bookmark")
                  .font(.subheadline).multilineTextAlignment(.center).lineLimit(2)
                  .accessibilityLabel("Pick up here: " + step.title).privacySensitive()
              }
              Text(seconds == 0 ? "Block complete" : "Paused")
                .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.88))
                .opacity(seconds == 0 || session.wallAnchor == nil ? 1 : 0)
                .accessibilityHidden(seconds > 0 && session.wallAnchor != nil)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: area.size.height)
          }
          .scrollBounceBehavior(.basedOnSize)
        }
        Button(action: capture) {
          Label(captureReceipt == nil ? "Capture distraction" : savedInPlan ? "Added to plan" : "Saved to inbox",
                systemImage: captureReceipt == nil ? "tray.and.arrow.down" : "checkmark")
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(Color.surface)
        .accessibilityLabel("Capture distraction")
        .accessibilityHint("Save a thought to your inbox and return to this sprint")
        let actionLayout = type.isAccessibilitySize
          ? AnyLayout(VStackLayout(spacing: 8))
          : AnyLayout(HStackLayout(spacing: 16))
        actionLayout { buttons(seconds: seconds) }
        .padding(.horizontal, 24).padding(.vertical, 18)
      }
    }
    .id(session.wallAnchor)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(Color.surface)
    .background(
      LinearGradient(
        stops: [
          .init(color: store.sky.ground.opacity(0), location: 0),
          .init(color: store.sky.ground.opacity(0.69), location: 0.38),
          .init(color: store.sky.ground.opacity(0.86), location: 0.51),
          .init(color: store.sky.ground.opacity(0.84), location: 0.61),
          .init(color: store.sky.ground.opacity(0.12), location: 0.82),
          .init(color: store.sky.ground, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    )
    .accessibilityAction(.escape, minimize)
    .onChange(of: latestCapture) { _, id in captureReceipt = id }
    .sensoryFeedback(.success, trigger: latestCapture) { _, new in new != nil }
    .task(id: captureReceipt) {
      guard captureReceipt != nil else { return }
      do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
      captureReceipt = nil
    }
    .sensoryFeedback(.selection, trigger: session.wallAnchor == nil)
    .task(id: run) {
      guard run.active, run.anchor != nil else { sound.stop(); return }
      if run.sound && remaining > 0 {
        do { try await sound.play() } catch is CancellationError { return } catch {
          store.notice = "Rain sound is unavailable."
        }
      } else {
        sound.stop()
      }
      // SwiftUI can render its final timeline entry just before the monotonic
      // deadline. Commit the terminal display once the session clock reaches it.
      while !Task.isCancelled {
        let left = session.target - store.elapsed(session)
        if left <= 0 {
          finishedRun = run
          sound.stop()
          return
        }
        do { try await Task.sleep(for: .seconds(left)) } catch { return }
      }
    }
    .sheet(isPresented: $editingNote) {
      NavigationStack {
        FocusResumeNoteScreen(session: session, finishAfterSaving: false)
      }
    }
    .onDisappear { sound.stop() }
    .onAppear { clockFocused = true }
  }

  @ViewBuilder private func buttons(seconds: Int) -> some View {
    if seconds > 0 {
      SceneButton(
        title: session.wallAnchor == nil ? "Resume" : "Pause",
        icon: session.wallAnchor == nil ? "play.fill" : "pause.fill"
      ) { store.toggleTimer() }
    }
    if seconds == 0, session.stepID != nil || session.isOpenSprint {
      let extra = store.sprintExtensionSeconds(at: .now)
      if extra >= 1 {
        Button { store.extendSprint() } label: {
          Label("Keep going · " + clock(Int(extra.rounded(.down))), systemImage: "play.fill")
            .font(.headline).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).foregroundStyle(Color.trailAmber)
      }
    }
    let finishingStep = session.stepID != nil
    Button {
      if session.isOpenSprint { store.finish(done: false) }
      else if finishingStep { store.finish(done: true) }
      else { finishing = true }
    } label: {
      Text(finishingStep ? "Finish step" : "Finish").font(.headline).padding(.horizontal, 22).frame(minWidth: 108, minHeight: 48)
        .overlay { Capsule().strokeBorder(.white.opacity(0.48), lineWidth: 1) }.contentShape(
          Capsule())
    }.buttonStyle(PressStyle()).accessibilityLabel(finishingStep ? "Finish step" : "Finish session")
      .accessibilityHint(session.isOpenSprint ? "Save this sprint and return to Today" : finishingStep ? "Marks this step complete and ends focus" : "Choose how to finish")
      .confirmationDialog("Finish session?", isPresented: $finishing, titleVisibility: .visible, actions: finishOptions)
  }

  private func clock(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

/// A shallow dial traces the elapsed share of the current focus block.
private struct FocusSweep: View {
  let progress: Double

  var body: some View {
    Canvas { context, size in
      let fraction = min(1, max(0, progress))
      let width = size.width - 10
      let rise = size.height - 18
      func point(_ position: Double, inset: Double = 0) -> CGPoint {
        let angle = (1 - position) * Double.pi
        return CGPoint(x: size.width / 2 + (width / 2 - inset) * cos(angle),
                       y: size.height - 4 - (rise - inset) * sin(angle))
      }

      var rail = Path()
      var traveled = Path()
      rail.move(to: point(0))
      traveled.move(to: point(0))
      for index in 1...80 {
        let position = Double(index) / 80
        rail.addLine(to: point(position))
        if position < fraction { traveled.addLine(to: point(position)) }
      }
      traveled.addLine(to: point(fraction))
      context.stroke(rail, with: .color(Color.surface.opacity(0.42)), lineWidth: 0.8)
      context.stroke(traveled, with: .color(.trailAmber), lineWidth: 1.6)
      for index in 0...40 {
        let position = Double(index) / 40
        let long = index.isMultiple(of: 5)
        var tick = Path()
        tick.move(to: point(position, inset: -2))
        tick.addLine(to: point(position, inset: long ? -9 : -5))
        context.stroke(tick, with: .color(position <= fraction ? .trailAmber : .surface.opacity(long ? 0.8 : 0.40)),
                       lineWidth: long ? 1.25 : 0.75)
      }
      let mark = point(fraction)
      context.fill(Path(ellipseIn: CGRect(x: mark.x - 3.5, y: mark.y - 3.5, width: 7, height: 7)),
                   with: .color(.trailAmber))
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
