import XCTest

@MainActor
final class StimulantFlowTests: XCTestCase {
    func testLabeledIntakeAndLabResultSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        func reveal(_ element: XCUIElement) {
            for _ in 0..<14 where !element.exists || !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.waitForExistence(timeout: 5))
        }
        func openHealth() {
            app.buttons["tab-Health"].tap()
            let shortcut = app.buttons["health-jump-stimulants"]
            let chapters = app.scrollViews.containing(.button, identifier: "health-jump-energy").firstMatch
            for _ in 0..<4 where !shortcut.isHittable || shortcut.frame.midX > app.frame.maxX {
                let y = app.buttons["health-jump-energy"].frame.midY / app.frame.height
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: y))
                from.press(forDuration: 0.08, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: y)))
                if !chapters.exists { break }
            }
            shortcut.tap()
            XCTAssertTrue(app.staticTexts["health-stimulants-heading"].waitForExistence(timeout: 5))
        }
        app.launch()
        openHealth()
        let log = app.buttons["health-log-intake"]
        reveal(log)
        log.tap()
        let amount = app.textFields["Labeled amount in mg (optional)"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: .contrast)
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped])
        amount.tap()
        amount.typeText("80")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Modeled amount remaining"].waitForExistence(timeout: 5))
        let add = app.buttons["health-add-stimulant-lab"]
        reveal(add)
        add.tap()
        let field = app.textFields["Measured concentration"]
        field.tap()
        field.typeText("125")
        app.buttons["Save"].tap()
        app.terminate()
        app.launch()
        openHealth()
        XCTAssertTrue(app.staticTexts["Modeled amount remaining"].waitForExistence(timeout: 5))
        let sample = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "125 ng/mL")).firstMatch
        reveal(sample)
        XCTAssertTrue(sample.exists)
    }
}
