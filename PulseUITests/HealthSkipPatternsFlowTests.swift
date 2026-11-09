import XCTest

@MainActor
final class HealthSkipPatternsFlowTests: XCTestCase {
    func testHealthExplainsWhenRepeatedSkipsAppearInAFreshJournal() {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.buttons["tab-Health"].tap()

        let jump = app.buttons["health-jump-skipped tasks"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let chapters = app.scrollViews.containing(.button, identifier: "health-jump-energy").firstMatch
        for _ in 0..<3 where !jump.isHittable { chapters.swipeLeft() }
        jump.tap()

        let heading = app.staticTexts["health-skip-patterns-heading"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Tasks appear here after two skips in this period."].exists)
        XCTAssertFalse(app.buttons["health-apply-skip-suggestion"].exists)
    }
}
