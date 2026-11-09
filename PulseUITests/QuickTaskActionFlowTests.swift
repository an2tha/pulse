import XCTest

@MainActor final class QuickTaskActionFlowTests: XCTestCase {
    func testStartFromInboxAndQuickDeleteFromTaskList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        let title = "Pack the field map"
        app.buttons["Quick add"].tap()
        let field = app.descendants(matching: .any)["quick-capture-input"].firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes")
        app.buttons["save-quick-capture"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Inbox"].tap()
        let play = app.buttons["Start " + title]
        XCTAssertTrue(play.waitForExistence(timeout: 6))
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists || app.buttons[title].exists)
        app.buttons["Finish session"].tap()
        app.buttons["Mark task complete"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["All items"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plan-edit-' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let confirm = app.alerts.buttons["Delete task"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
        row.swipeLeft()
        confirm.tap()
        XCTAssertFalse(row.exists)
        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["All items"].tap()
        XCTAssertFalse(row.exists)
    }
}
