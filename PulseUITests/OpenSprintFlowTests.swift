import XCTest

@MainActor
final class OpenSprintFlowTests: XCTestCase {
    func testHeldThoughtsStayInInboxDuringAnOpenSprint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.addFocusFixture()

        func capture(_ title: String) {
            app.buttons["Capture distraction"].tap()
            let field = app.descendants(matching: .any).matching(identifier: "quick-capture-input").firstMatch
            field.tap()
            field.typeText(title)
            app.buttons["save-quick-capture"].tap()
        }

        app.buttons["Start"].tap()
        capture("Find the rehearsal notes")
        app.buttons["Finish session"].tap()
        app.buttons["Mark task complete"].tap()
        if app.buttons["End break"].waitForExistence(timeout: 2) { app.buttons["End break"].tap() }

        let start = app.buttons["start-open-sprint"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        start.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        capture("Ask about the microphone")
        app.buttons["Pause"].tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 6))
        app.buttons["Finish session"].tap()

        let review = app.buttons["Review 1 capture"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.buttons["Schedule Ask about the microphone"].exists)
        XCTAssertFalse(app.buttons["Schedule Find the rehearsal notes"].exists)
        app.buttons["Done"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Inbox"].tap()
        let inbox = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan-edit-"))
        XCTAssertEqual(inbox.count, 2)
        XCTAssertTrue(inbox.allElementsBoundByIndex.allSatisfy { $0.label.contains("Inbox only") })
    }
}
