import XCTest

@MainActor
final class TaskIconFlowTests: XCTestCase {
    func testChooseChangeAndRemoveAnIconAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["New task"].tap()
        let name = app.textFields["Task name"]
        name.tap()
        name.typeText("Rehearse the duet")
        let choose = app.buttons["task-icon-picker"]
        choose.tap()
        app.buttons["task-icon-music.note"].tap()
        XCTAssertEqual(choose.value as? String, "Music")
        app.buttons["Save"].tap()
        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["All items"].tap()
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plan-edit-' AND label CONTAINS %@", "Rehearse the duet")).firstMatch
        task.tap()
        XCTAssertEqual(choose.value as? String, "Music")
        choose.tap()
        let entry = app.textFields["task-icon-character"]
        entry.tap()
        entry.typeText("R")
        app.buttons["Use"].tap()
        XCTAssertEqual(choose.value as? String, "R")
        choose.tap()
        app.buttons["Use category icon"].tap()
        XCTAssertEqual(choose.value as? String, "Category icon")
        app.buttons["Save"].tap()
        task.tap()
        XCTAssertEqual(choose.value as? String, "Category icon")
        app.buttons["Cancel"].tap()
        task.press(forDuration: 0.8)
        app.buttons["Change icon"].tap()
        app.buttons["task-icon-book"].tap()
        task.tap()
        XCTAssertEqual(choose.value as? String, "Book")
    }
}
