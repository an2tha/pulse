import XCTest

@MainActor
final class PrivacyFlowTests: XCTestCase {
    private func freshJournal() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launch()
        return app
    }

    func testDemoFocusStaysOutOfPersonalJournal() {
        let app = freshJournal()
        app.buttons["Explore a demo"].tap()
        app.buttons["Start"].tap()
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].exists)
        app.buttons["Exit demo"].tap()
        app.buttons["Open my journal"].tap()
        XCTAssertTrue(app.buttons["Add a task"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Resume"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Add a task"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Exit demo"].exists)
    }

    func testWalkthroughPracticeAndReplayLeaveRealJournalEmpty() {
        let app = freshJournal()
        app.buttons["Start walkthrough"].tap()
        app.buttons["Try capture"].tap()
        app.buttons["Next"].tap()
        app.buttons["Tomorrow"].tap()
        app.buttons["Next"].tap()
        app.buttons["Next"].tap()
        app.buttons["Try sprint"].tap()
        app.buttons["Pause"].tap()
        app.buttons["Next"].tap()
        app.buttons["finish-pulse-walkthrough"].tap()
        XCTAssertTrue(app.buttons["Add a task"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Read a chapter"].exists)
        XCTAssertFalse(app.buttons["Return to focus"].exists)
        app.buttons["Settings"].tap()
        app.buttons["replay-pulse-walkthrough"].tap()
        XCTAssertTrue(app.staticTexts["Catch a to-do"].waitForExistence(timeout: 5))
        app.buttons["Walkthrough topics"].tap()
        app.buttons["Focus"].tap()
        XCTAssertTrue(app.buttons["Try sprint"].exists)
        app.buttons["Close walkthrough"].tap()
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Add a task"].waitForExistence(timeout: 5))
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["All items"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plan-edit-'")).firstMatch.exists)
        app.buttons["Planning options"].tap()
        app.buttons["plan-walkthrough"].tap()
        XCTAssertTrue(app.staticTexts["Give it a time"].waitForExistence(timeout: 5))
        app.buttons["Close walkthrough"].tap()
    }

    func testSleepOnboardingAndReset() {
        let app = freshJournal()
        app.buttons["Set up energy"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Your nightly sleep need"].exists)
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Your sleep debt"].exists)
        app.buttons["Continue"].tap()
        app.buttons["Open Today"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sleep-setup-badge"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sleep-setup-badge"].exists)
        app.buttons["tab-Plan"].tap()
        app.buttons["Sleep window"].tap()
        XCTAssertTrue(app.datePickers["Bedtime"].exists)
        XCTAssertTrue(app.datePickers["Wake time"].exists)
        app.buttons["Done"].tap()
        app.buttons["tab-Today"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Reset onboarding"].tap()
        XCTAssertTrue(app.buttons["Set up energy"].waitForExistence(timeout: 5))
    }

    func testWelcomeAccessibility() throws {
        let app = freshJournal()
        XCTAssertTrue(app.buttons["Open my journal"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [
            .contrast, .hitRegion, .dynamicType, .textClipped, .sufficientElementDescription,
        ])
    }
}
