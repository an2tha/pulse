import Observation
import PulseEngine
import SwiftUI

@MainActor @Observable
final class PrivacySession {
    private let defaults: UserDefaults
    static var connectionsLocked: Bool { preferences.bool(forKey: "lockConnections") }
    var lockConnections: Bool { didSet { defaults.set(lockConnections, forKey: "lockConnections") } }
    var automaticHealthPlanning: Bool {
        didSet { defaults.set(automaticHealthPlanning, forKey: "automaticHealthPlanning") }
    }
    var sleepSetupFinished: Bool { didSet { defaults.set(sleepSetupFinished, forKey: "sleepSetupFinished") } }
    var sleepConnected: Bool { didSet { defaults.set(sleepConnected, forKey: "sleepConnected") } }
    var welcomed: Bool { didSet { defaults.set(welcomed, forKey: "welcomed") } }
    var welcomeBackEnabled: Bool { didSet { defaults.set(welcomeBackEnabled, forKey: "welcomeBack") } }
    var diagnosticsEnabled: Bool {
        didSet {
            defaults.set(diagnosticsEnabled, forKey: "diagnostics")
            PrivacyDiagnostics.shared.setEnabled(diagnosticsEnabled)
        }
    }
    var lastVisit: Date? {
        get { defaults.object(forKey: "lastVisit") as? Date }
        set { defaults.set(newValue, forKey: "lastVisit") }
    }
    var demo = false
    var returnPrompt = false

    static var preferences: UserDefaults {
        #if DEBUG
            if let token = ProcessInfo.processInfo.environment["PULSE_TEST_JOURNAL"], UUID(uuidString: token) != nil,
                let prefs = UserDefaults(suiteName: "app.pulseplanner.test." + token)
            {
                return prefs
            }
            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1",
                let prefs = UserDefaults(suiteName: "app.pulseplanner.preview")
            {
                return prefs
            }
        #endif
        return .standard
    }
    init(defaults source: UserDefaults? = nil) {
        let prefs = source ?? Self.preferences
        defaults = prefs
        lockConnections = prefs.bool(forKey: "lockConnections")
        automaticHealthPlanning = !prefs.bool(forKey: "lockConnections") && prefs.bool(forKey: "automaticHealthPlanning")
        sleepSetupFinished = prefs.bool(forKey: "sleepSetupFinished")
        sleepConnected = prefs.bool(forKey: "sleepConnected")
        welcomed = prefs.bool(forKey: "welcomed")
        welcomeBackEnabled = prefs.object(forKey: "welcomeBack") as? Bool ?? true
        diagnosticsEnabled = prefs.bool(forKey: "diagnostics")
        #if DEBUG
            if ProcessInfo.processInfo.environment["PULSE_SKIP_ONBOARDING"] == "1" { welcomed = true }
        #endif
        PrivacyDiagnostics.shared.setEnabled(diagnosticsEnabled)
    }

    func visit(_ journal: Journal) {
        let date = Date.now
        if let lastVisit, ReleaseFeatures.returnAfterAbsence, welcomeBackEnabled, journal.active == nil,
            Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: lastVisit), to: date).day
                ?? 0 >= 7
        {
            returnPrompt = true
        }
        self.lastVisit = date
    }

    /// A chosen shortcut is already the person's decision about how to return.
    func followDirectAction() {
        guard !demo else { return }
        returnPrompt = false
        lastVisit = .now
    }

    func erase() {
        sleepSetupFinished = false
        sleepConnected = false
        automaticHealthPlanning = false
        diagnosticsEnabled = false
        lockConnections = false
        returnPrompt = false
        lastVisit = nil
        welcomeBackEnabled = true
        welcomed = false
    }
}

struct JournalHost: View {
    @Environment(Workspace.self) private var personal
    @Environment(\.scenePhase) private var phase
    @State private var privacy = PrivacySession()
    @State private var example: Workspace?
    @State private var visited = false

    var body: some View {
        Group {
            if let example, privacy.demo {
                VStack(spacing: 0) {
                    HStack {
                        Label("Demo journal", systemImage: "book.closed")
                        Spacer()
                        Button("Exit demo") { privacy.demo = false }
                    }
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 20).frame(minHeight: 44)
                    .foregroundStyle(example.sky.usesLightHeaderInk ? Color.surface : Color.pine).background(example.sky.upperSky)
                    RootView(demo: true).environment(example)
                }
            } else if !personal.ready {
                if let failure = personal.loadFailure {
                    ContentUnavailableView {
                        Label("Open your journal", systemImage: "book.closed")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Opening your journal")
                }
            } else if !privacy.welcomed {
                WelcomeScreen(privacy: privacy)
            } else {
                RootView()
            }
        }
        .preferredColorScheme((privacy.demo ? example?.sky : personal.sky)?.interfaceScheme ?? .light)
        .environment(privacy)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.paper)
        .task { await load() }
        .onChange(of: privacy.demo) {
            if privacy.demo {
                let sample = Workspace()
                sample.isDemo = true
                sample.ready = true
                sample.change { $0 = Self.sampleJournal() }
                example = sample
            } else {
                example = nil
            }
        }
        .onChange(of: phase) {
            if phase == .active, personal.ready, !privacy.demo { privacy.visit(personal.journal) }
        }
        .alert("Welcome back", isPresented: $privacy.returnPrompt) {
            Button("Plan from now") { personal.now = .now }
            Button("Rest today") { personal.change { $0.restDate = .now } }
        } message: {
            Text("Your unfinished tasks are ready when you are.")
        }
    }

    private func load() async {
        await personal.load()
        guard personal.ready, !visited else { return }
        visited = true
        if personal.journal != Journal(), PrivacySession.preferences.object(forKey: "welcomed") == nil {
            privacy.welcomed = true
        }
        privacy.visit(personal.journal)
    }

    private static func sampleJournal() -> Journal {
        var journal = Journal()
        journal.starterAvailable = false
        journal.tasks = [
            PlanTask("Sketch the garden", minutes: 15, category: .personal),
            PlanTask("Read a chapter", minutes: 10, category: .study),
            PlanTask("Water the herbs", minutes: 3, category: .personal),
        ]
        journal.events = [
            Commitment("Meet at the library", start: .now.addingTimeInterval(3600), end: .now.addingTimeInterval(5400))
        ]
        journal.reports = [4, 6, 5, 8, 4, 6, 7].enumerated().map { i, value in
            CheckIn(
                date: Calendar.current.date(byAdding: .day, value: i - 6, to: .now)!, energy: Double(value), clarity: 6,
                interest: 7)
        }
        return journal
    }
}

private struct WelcomeScreen: View {
    let privacy: PrivacySession
    @State private var walking = false
    @State private var sleepSetup = false
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        Button { privacy.welcomed = true } label: {
                            Text("Open my journal").font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.surface).padding(.horizontal, 11).padding(.vertical, 5)
                                .background(store.sky.ground, in: Capsule())
                                .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 26)
                    Spacer(minLength: viewport.size.height * 0.35)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Welcome to Pulse")
                            .font(.largeTitle.weight(.medium))
                            .tracking(-1)
                            .accessibilityAddTraits(.isHeader)
                        Text("Plan around your energy. Your journal starts on this device, and you choose what to share.")
                            .font(.subheadline).foregroundStyle(Color.surface)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) { welcomeActions }.padding(.top, 5)
                    }
                    .foregroundStyle(Color.surface)
                    .padding(.horizontal, 26).padding(.bottom, 25)
                    .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
                    .background {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, store.sky.ground], startPoint: .top, endPoint: .bottom)
                                .frame(height: 85)
                            store.sky.ground
                        }.padding(.top, -85)
                    }
                }.frame(minHeight: viewport.size.height)
            }
            .background(alignment: .top) {
                LookoutLandscape(sky: store.sky, energy: 5, theme: store.landscapeTheme)
                    .frame(width: viewport.size.width, height: viewport.size.height * 0.92)
            }
            .scrollBounceBehavior(.basedOnSize)
        }.background(store.sky.canvasBackground.ignoresSafeArea())
        .accessibilityHidden(walking || sleepSetup)
        .sheet(isPresented: $sleepSetup) { SleepOnboarding { privacy.welcomed = true } }
        .sheet(isPresented: $walking) {
            NavigationStack {
                PulseWalkthrough {
                    walking = false
                    privacy.welcomed = true
                }
            }
        }
    }

    @ViewBuilder private var welcomeActions: some View {
        SceneButton(title: "Set up energy", icon: "moon.stars") { sleepSetup = true }
        Button("Start walkthrough") { walking = true }.frame(minHeight: 44)
        if ReleaseFeatures.demo {
            Button { privacy.demo = true } label: {
                Text("Explore a demo").font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
            }
        }
    }
}
