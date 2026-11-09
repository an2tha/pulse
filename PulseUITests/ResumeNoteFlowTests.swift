import XCTest

@MainActor
final class ResumeNoteFlowTests: XCTestCase {
    func testStopAtAnotherStepAndFinishItAfterRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.addFocusFixture()
        app.buttons["start-small"].tap()
        app.buttons["focus-task-menu"].tap()
        app.buttons["Stop and pick up at"].tap()
        let second = "Write a letter"
        app.buttons[second].tap()
        let cue = app.descendants(matching: .any).matching(identifier: "today-return-cue").firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 5))
        XCTAssertTrue(cue.label.contains(second))
        app.terminate()
        app.launch()
        app.buttons["start-small"].tap()
        XCTAssertTrue(app.buttons["focus-task-menu"].label.contains(second))
        app.buttons["Finish step"].tap()
        XCTAssertTrue(app.buttons["End break"].waitForExistence(timeout: 5))
        app.buttons["End break"].tap()
        app.buttons["start-small"].tap()
        XCTAssertTrue(app.buttons["focus-task-menu"].label.contains("Write the first sentence"))
    }

    func testLeaveNoteAndResumeAfterRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.addFocusFixture()
        app.buttons["Start"].tap()
        app.buttons["Finish session"].tap()
        app.buttons["Leave a note and finish"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "resume-note-input").firstMatch
        field.tap()
        field.typeText("Pick up at page 12.")
        app.buttons["Save and finish"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let todayCue = app.descendants(matching: .any).matching(identifier: "today-return-cue").firstMatch
        XCTAssertTrue(todayCue.waitForExistence(timeout: 5))
        XCTAssertTrue(todayCue.label.contains("Pick up at page 12."))
        app.buttons["Start"].tap()
        let cue = app.buttons["focus-resume-note"]
        XCTAssertTrue(cue.waitForExistence(timeout: 5))
        XCTAssertTrue(cue.label.contains("Pick up at page 12."))
        cue.tap()
        app.buttons["Clear note"].tap()
        app.buttons["Save"].tap()
        XCTAssertFalse(cue.exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
    }
}
