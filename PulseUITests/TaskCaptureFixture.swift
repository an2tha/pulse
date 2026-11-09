import XCTest

extension XCUIApplication {
    /// Timers and completion flows start with a task explicitly added to this test journal.
    @MainActor func addFocusFixture(_ title: String = "Write a letter") {
        buttons["Quick add"].tap()
        let input = descendants(matching: .any)["quick-capture-input"].firstMatch
        input.tap()
        input.typeText(title + " for 5 minutes")
        buttons["save-quick-capture"].tap()
        XCTAssertTrue(buttons["Start"].waitForExistence(timeout: 5))
    }
}
