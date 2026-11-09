import Foundation
import Testing

@testable import Pulse

@Suite @MainActor struct SystemSurfaceTests {
    @Test func directActionsPassTheWelcomeBackPromptInEitherLaunchOrder() throws {
        let name = "pulse-return-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let privacy = PrivacySession(defaults: defaults)
        privacy.welcomed = false
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -9, to: .now))
        privacy.lastVisit = earlier
        privacy.visit(Journal())
        #expect(privacy.returnPrompt)
        privacy.followDirectAction()
        #expect(!privacy.returnPrompt && !privacy.welcomed)
        privacy.lastVisit = earlier
        privacy.followDirectAction()
        privacy.visit(Journal())
        #expect(!privacy.returnPrompt)
        privacy.demo = true
        privacy.lastVisit = earlier
        privacy.followDirectAction()
        #expect(privacy.lastVisit == earlier)
    }

    @Test func widgetAndLiveActivityLinksResolveOnce() throws {
        let router = PulseSystemRouter()
        router.open(SurfaceData.today)
        #expect(router.take() == .today)
        #expect(router.take() == nil)
        router.open(SurfaceData.focus)
        #expect(router.take() == .focus)
        let identity = SurfaceData.focusID(task: UUID(), started: .now)
        router.open(SurfaceData.focusURL(session: identity))
        #expect(router.take() == .focusSession(identity))
        router.open(try #require(URL(string: "pulseplanner://focus?session=")))
        #expect(router.take() == nil)
        router.open(try #require(URL(string: "pulseplanner://check-in")))
        #expect(router.take() == .checkIn)
        router.open(try #require(URL(string: "https://example.com/focus")))
        #expect(router.take() == nil)
        router.open(try #require(URL(string: "pulseplanner://unknown")))
        #expect(router.take() == nil)
    }

    @Test func repeatedSmallStartsDeliverOneRequestToTheVisibleJournal() async throws {
        let router = PulseSystemRouter.shared
        _ = try await StartSmallIntent().perform()
        _ = try await StartSmallIntent().perform()
        #expect(router.take(inDemo: true) == .startSmall)
        #expect(router.take() == nil)
        router.send(.focus)
        #expect(router.take(inDemo: true) == nil)
        #expect(router.take() == .focus)
    }

    @Test func liveDistractionLinkRequiresOneSessionAndWaitsForThePersonalJournal() throws {
        let router = PulseSystemRouter()
        let task = UUID()
        let start = Date.now
        let identity = SurfaceData.focusID(task: task, started: start)
        let next = SurfaceData.focusID(task: task, started: start.addingTimeInterval(1))
        #expect(identity != next)
        router.open(SurfaceData.distractionURL(session: identity))
        #expect(router.take(inDemo: true) == nil)
        #expect(router.take() == .captureDistraction(identity))
        #expect(router.take() == nil)
        for query in ["", "?session=", "?session=one&session=two"] {
            router.open(try #require(URL(string: "pulseplanner://focus/capture" + query)))
            #expect(router.take() == nil)
        }
        router.open(SurfaceData.focusURL(session: next))
        #expect(router.take() == .focusSession(next))
    }

    @Test func pausedActivityStateRoundTripsWithoutCountingDown() throws {
        let state = FocusAttributes.ContentState(deadline: nil, secondsLeft: 83, title: "Focus")
        let decoded = try JSONDecoder().decode(FocusAttributes.ContentState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.deadline == nil)
    }

    @Test func widgetKeepsSmallDriftUntilItWouldShowTheWrongTask() {
        let day = Calendar.current.startOfDay(for: .now)
        func snapshot(_ offset: Double) -> DayWidgetSnapshot {
            let start = day.addingTimeInterval(3600 + offset)
            let first = DayWidgetEntry(title: "Read", start: start, end: start.addingTimeInterval(1800), minutes: 30)
            let next = DayWidgetEntry(title: "Write", start: first.end, end: first.end.addingTimeInterval(600), minutes: 10)
            return DayWidgetSnapshot(day: day, entries: [first, next], rest: false)
        }
        let published = snapshot(0)
        #expect(published.canKeepTimeline(for: snapshot(60), at: day))
        #expect(!published.canKeepTimeline(for: snapshot(900), at: day))
        #expect(!published.canKeepTimeline(for: snapshot(60), at: published.entries[0].end))
    }
}
