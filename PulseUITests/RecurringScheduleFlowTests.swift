import XCTest

@MainActor
final class RecurringScheduleFlowTests: XCTestCase {
    func testDrawnProtectedBlockRetainsRepeatPatternAndLastDateAcrossLaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()

        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()
        app.buttons["week-day-tools"].tap()
        app.buttons["timeline-draw-toggle"].tap()
        app.buttons["Protected"].tap()
        app.buttons["review-timeline-block"].tap()
        app.descendants(matching: .any)["schedule-repeat"].firstMatch.tap()
        app.buttons["Every day"].tap()
        app.buttons["Add end date"].tap()
        XCTAssertTrue(app.buttons["Remove end date"].waitForExistence(timeout: 5))
        app.buttons["save-timeline-block"].tap()

        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Time blocks"].tap()
        let zone = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Protected time' AND label CONTAINS 'Every day' AND label CONTAINS 'Through'")).firstMatch
        XCTAssertTrue(zone.waitForExistence(timeout: 5))
        zone.tap()
        XCTAssertTrue(app.buttons["Remove end date"].exists)
    }
}
