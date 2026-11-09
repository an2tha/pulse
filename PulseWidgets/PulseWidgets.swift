import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PulseWidgets: WidgetBundle {
    var body: some Widget {
        DayWidget()
        FocusActivityWidget()
        if #available(iOSApplicationExtension 18.0, *) { StartSmallControl() }
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct StartSmallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.pulseplanner.pulse.start-small") {
            ControlWidgetButton(action: StartSmallIntent()) {
                Label("Start small", systemImage: "figure.walk")
            }
        }
        .displayName("Start small")
        .description("Start a two-minute step or return to Focus.")
    }
}

private let pine = Color(red: 0.095, green: 0.17, blue: 0.19)
private let cream = Color(red: 0.99, green: 0.96, blue: 0.84)

private struct Entry: TimelineEntry {
    let date: Date
    let snapshot: DayWidgetSnapshot?
    var next: DayWidgetEntry? { snapshot?.entries.first { $0.end > date } }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: SurfaceData.currentDay()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let snapshot = SurfaceData.currentDay()
        let tomorrow = Calendar.current.dateInterval(of: .day, for: now)!.end
        let dates = Set((snapshot?.entries.flatMap { [$0.start, $0.end] } ?? []).filter { $0 > now && $0 < tomorrow })
        let entries =
            ([now] + dates.sorted()).map { Entry(date: $0, snapshot: snapshot) } + [
                Entry(date: tomorrow, snapshot: nil)
            ]
        completion(Timeline(entries: entries, policy: .after(tomorrow)))
    }
}

private struct DayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SurfaceData.widgetKind, provider: Provider()) { entry in DayFace(entry: entry) }
            .configurationDisplayName("Today")
            .description("Your next planned block, or a shortcut to Today.")
            .supportedFamilies([
                .systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular, .accessoryCircular,
            ])
    }
}

private struct DayFace: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private var title: String {
        entry.snapshot?.rest == true
            ? "Rest day" : entry.next?.title ?? (entry.snapshot == nil ? "Open Today" : "Open time")
    }
    private var symbol: String { entry.snapshot?.rest == true ? "moon.horizon" : "sun.horizon" }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(title, systemImage: symbol).privacySensitive(entry.next != nil)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: symbol).font(.title2)
                }.accessibilityLabel("Open Pulse")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("Pulse", systemImage: symbol).font(.caption)
                    Text(title).font(.headline).lineLimit(2).privacySensitive(entry.next != nil)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: symbol)
                        Spacer()
                        Text(entry.date, format: .dateTime.weekday(.abbreviated).day())
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(cream)
                    Spacer()
                    Text(title).font(.title3.weight(.medium)).lineLimit(2).privacySensitive(entry.next != nil)
                    if let next = entry.next, entry.snapshot?.rest != true {
                        HStack(spacing: 5) {
                            Text(next.start, style: .time)
                            Text("· \(next.minutes) min")
                        }.font(.caption).privacySensitive()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.29, green: 0.36, blue: 0.43), pine], startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                Canvas { ctx, size in
                    var ridge = Path()
                    ridge.move(to: .init(x: 0, y: size.height * 0.48))
                    ridge.addQuadCurve(
                        to: .init(x: size.width, y: size.height * 0.43),
                        control: .init(x: size.width * 0.68, y: size.height * 0.83))
                    ridge.addLine(to: .init(x: size.width, y: size.height))
                    ridge.addLine(to: .init(x: 0, y: size.height))
                    ridge.closeSubpath()
                    ctx.fill(ridge, with: .color(pine))
                }
            }
        }
        .widgetURL(SurfaceData.today)
    }
}

private struct FocusActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusAttributes.self) { context in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    timer(context.state).font(.title.monospacedDigit().weight(.semibold))
                    if context.state.resumeDeclined == true {
                        Text("Couldn’t resume").font(.caption)
                    } else {
                        Text(context.state.title).font(.caption).lineLimit(1).privacySensitive()
                    }
                }
                Spacer(minLength: 0)
                controls(context)
            }
            .padding(16).foregroundStyle(.white).activityBackgroundTint(pine)
            .activitySystemActionForegroundColor(cream)
            .widgetURL(SurfaceData.focusURL(session: context.attributes.session))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    timer(context.state).font(.title2.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) { Text(status(context)).font(.caption) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.state.title).font(.headline).lineLimit(1).privacySensitive()
                        Spacer(minLength: 0)
                        controls(context)
                    }
                }
            } compactLeading: {
                Image(systemName: "sun.horizon").foregroundStyle(cream)
            } compactTrailing: {
                timer(context.state).font(.caption.monospacedDigit()).frame(maxWidth: 54)
            } minimal: {
                Image(systemName: context.state.deadline == nil ? "pause.fill" : "hourglass")
            }
            .widgetURL(SurfaceData.focusURL(session: context.attributes.session))
        }
    }
    @ViewBuilder private func controls(_ context: ActivityViewContext<FocusAttributes>) -> some View {
        if let revision = context.state.timerRevision,
           !context.isStale, context.state.secondsLeft > 0,
           context.state.deadline.map({ $0 > Date.now }) ?? true {
            let paused = context.state.deadline == nil
            Button(intent: SetFocusTimerIntent(session: context.attributes.session, revision: revision, resuming: paused)) {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .frame(width: 44, height: 44)
                    .background(cream, in: Circle()).foregroundStyle(pine)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Resume focus" : "Pause focus")
        }
        Link(destination: SurfaceData.distractionURL(session: context.attributes.session)) {
            Image(systemName: "tray.and.arrow.down")
                .font(.title3).foregroundStyle(cream).frame(width: 44, height: 44)
                .background(cream.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("Capture distraction")
    }

    private func status(_ context: ActivityViewContext<FocusAttributes>) -> String {
        if context.isStale || context.state.secondsLeft == 0 { return "Block complete" }
        if context.state.resumeDeclined == true { return "Couldn’t resume" }
        return context.state.deadline == nil ? "Paused" : "In focus"
    }
    @ViewBuilder private func timer(_ state: FocusAttributes.ContentState) -> some View {
        let now = Date.now
        if let deadline = state.deadline, deadline > now {
            Text(timerInterval: now...deadline, countsDown: true, showsHours: false).monospacedDigit()
        } else {
            let left = state.deadline == nil ? state.secondsLeft : 0
            Text(String(format: "%02d:%02d", left / 60, left % 60))
        }
    }
}
