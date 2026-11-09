import XCTest

@MainActor
final class TaskSkipSurveyFlowTests: XCTestCase {
    func testStartedTaskRequiresReasonAndEnergyBeforeSkipAndKeepsHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        let title = "Sort the samples"
        app.addFocusFixture(title)
        app.buttons["Start"].tap()

        func openSurvey() {
            XCTAssertTrue(app.buttons["Finish session"].waitForExistence(timeout: 5))
            app.buttons["Finish session"].tap()
            let skip = app.buttons["Skip for today"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5))
            skip.tap()
            XCTAssertTrue(app.navigationBars["Skip task"].waitForExistence(timeout: 5))
        }

        openSurvey()
        let save = app.buttons["save-task-skip"]
        XCTAssertFalse(save.isEnabled)
        app.buttons["Low energy"].tap()
        XCTAssertFalse(save.isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))

        openSurvey()
        XCTAssertFalse(save.isEnabled)
        let energy = app.buttons["skip-energy"]
        for _ in 0..<4 where !energy.isHittable { app.swipeUp() }
        XCTAssertTrue(energy.isHittable)
        energy.tap()
        app.buttons["3"].tap()
        XCTAssertFalse(save.isEnabled)
        let reason = app.buttons["Low energy"]
        for _ in 0..<4 where !reason.isHittable { app.swipeDown() }
        reason.tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars["Skip task"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pause"].exists)

        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Skip history"].tap()
        XCTAssertTrue(app.navigationBars["Skip history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists)
        XCTAssertTrue(app.staticTexts["Low energy"].exists)
        XCTAssertTrue(app.staticTexts["Energy 3/10"].exists)
    }
}
