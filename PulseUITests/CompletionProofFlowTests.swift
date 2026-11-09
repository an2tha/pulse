import XCTest

@MainActor
final class CompletionProofFlowTests: XCTestCase {
    func testCancellingPhotoLeavesTaskOpenAndSettingCanDisableRequirement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()

        let title = "Photograph the finished shelf"
        app.buttons["tab-Plan"].tap()
        app.buttons["New task"].tap()
        let name = app.textFields["Task name"]
        name.tap()
        name.typeText(title)
        let required = app.switches["task-photo-proof"]
        for _ in 0..<12 where !required.isHittable { app.swipeUp() }
        XCTAssertTrue(required.isHittable)
        required.tap()
        app.buttons["Save"].tap()

        app.buttons["plan-view"].tap()
        app.buttons["All items"].tap()
        let complete = app.buttons["Complete " + title]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        XCTAssertTrue(app.navigationBars["Completion photo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-completion-proof"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5))

        app.buttons["Settings"].tap()
        let enforcement = app.switches["settings-photo-proof"]
        for _ in 0..<5 where !enforcement.isHittable { app.swipeUp() }
        XCTAssertTrue(enforcement.isHittable)
        enforcement.tap()
        app.buttons["Done"].tap()
        complete.tap()
        XCTAssertTrue(app.buttons["plan-completion-undo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Completion photo"].exists)
    }
}
