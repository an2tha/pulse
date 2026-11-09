import XCTest

@MainActor
final class InboxFocusDropTests: XCTestCase {
    func testHeldTaskCanBeDroppedIntoFocusOrOntoADayAndUndone() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.addFocusFixture()
        let title = "Water the tea plant"
        app.buttons["Start"].tap()
        app.buttons["Capture distraction"].tap()
        let field = app.descendants(matching: .any)["quick-capture-input"].firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes")
        app.buttons["save-quick-capture"].tap()
        app.buttons["Finish session"].tap()
        app.buttons["Mark task complete"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()

        app.buttons["Add to plan"].tap()
        app.buttons["add-plan-new-block"].tap()
        let name = app.textFields["Name (optional)"]
        name.tap()
        name.typeText("Afternoon studio")
        app.buttons["Save"].tap()
        // Saving returns to Tomorrow, so the creation sheet may leave the
        // schedule scrolled below its view menu.
        app.buttons["plan-view"].tap()
        app.buttons["Inbox"].tap()

        let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox-schedule-'")).firstMatch
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1,
                                                           to: Calendar.current.startOfDay(for: .now)))
        let day = app.buttons["inbox-day-\(Int(tomorrow.timeIntervalSince1970))"]
        XCTAssertTrue(grip.waitForExistence(timeout: 7))
        day.tap()
        let focus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox-focus-' AND label CONTAINS %@", "Afternoon studio")).firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 5))
        func drop(on target: XCUIElement) {
            let center = CGVector(dx: 0.5, dy: 0.5)
            grip.coordinate(withNormalizedOffset: center).press(forDuration: 0.05,
                thenDragTo: target.coordinate(withNormalizedOffset: center))
        }
        let undo = app.buttons["inbox-drop-undo"]
        let message = app.staticTexts["inbox-drop-result"]
        drop(on: focus)
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("Afternoon studio"))
        undo.tap()
        let held = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plan-edit-' AND label CONTAINS %@ AND label CONTAINS %@", title, "Inbox only"))
        XCTAssertTrue(held.firstMatch.waitForExistence(timeout: 5))

        drop(on: day)
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains(title))
        undo.tap()
        XCTAssertTrue(held.firstMatch.waitForExistence(timeout: 5))
    }
}
