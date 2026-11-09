#if DEBUG
    import SwiftUI
    import PulseEngine

    /// Xcode preview fixtures only. These never enter a device journal.
    @MainActor
    private struct DemoToday: View {
        @State private var workspace: Workspace = {
            let w = Workspace()
            w.isDemo = true
            w.ready = true
            w.journal.atmosphere = Atmosphere.dawn.rawValue
            w.journal.tasks = [
                PlanTask("Sketch the garden", minutes: 15, category: .personal),
                PlanTask("Read a chapter", minutes: 10, category: .study),
                PlanTask("Water the herbs", minutes: 3, category: .personal),
            ]
            w.journal.events = [
                Commitment(
                    "Meet at the library", start: .now.addingTimeInterval(3600), end: .now.addingTimeInterval(5400))
            ]
            w.journal.reports = (0..<7).map { i in
                CheckIn(
                    date: Calendar.current.date(byAdding: .day, value: i - 6, to: .now)!,
                    energy: Double([4, 6, 5, 8, 4, 6, 7][i]), clarity: 6, interest: 7)
            }
            return w
        }()
        var body: some View {
            VStack(spacing: 0) {
                Text("Demonstration journal").font(.caption)
                RootView().environmentObject(QuickActionSceneDelegate()).environmentObject(ReminderDelegate()).environment(workspace).environment(PrivacySession())
            }.foregroundStyle(Color.journalInk).tint(.journalAccent).preferredColorScheme(workspace.sky.interfaceScheme)
        }
    }
    #Preview("Today · demonstration data") { DemoToday() }
#endif
