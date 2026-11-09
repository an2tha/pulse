import XCTest

@MainActor
final class CommitmentPreparationFlowTests: XCTestCase {
    func testTomorrowPrepCanBeUndoneAndDetachedWithoutDeletingItsTask() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["Planning options"].tap()
        app.buttons["Add to plan"].tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        field.tap()
        field.typeText("Studio visit tomorrow from 10am to 11am")
        app.buttons["Preview plan"].tap()
        app.buttons["Add these items"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Studio visit", "60 min")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        if !row.isHittable { app.swipeUp() }
        row.tap()
        let add = app.buttons["add-event-prep"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let undo = app.buttons["Undo added prep"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compare-event-prep"].exists)
        try app.performAccessibilityAudit(for: .all)
        undo.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        app.buttons["edit-event-prep"].tap()
        app.buttons["Unlink commitment"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["edit-event-prep"].waitForExistence(timeout: 5))
        app.buttons["edit-event-prep"].tap()
        app.buttons["Unlink commitment"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Inbox"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Prepare for Studio visit").firstMatch.waitForExistence(timeout: 5))
    }
}
