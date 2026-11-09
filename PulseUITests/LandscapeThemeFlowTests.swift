import XCTest

@MainActor
final class LandscapeThemeFlowTests: XCTestCase {
    func testThemeSelectionPersistsAcrossLaunches() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        openThemes(in: app)
        XCTAssertEqual(app.buttons["landscape-theme-pastel-painting"].value as? String, "Selected")
        capture("Theme packs, default")
        for theme in ["calm", "mellow", "low-poly"] {
            let choice = app.buttons["landscape-theme-\(theme)"]
            if !choice.isHittable { app.swipeUp() }
            choice.tap()
            XCTAssertEqual(choice.value as? String, "Selected")
            capture("Theme packs, \(theme)")
            app.navigationBars.buttons["Settings"].tap()
            app.buttons["Done"].tap()
            capture("Today, \(theme)")
            app.buttons["check-in"].tap()
            XCTAssertTrue(app.buttons["Save check-in"].waitForExistence(timeout: 5))
            capture("Check-in, \(theme)")
            app.buttons["Skip"].tap()
            openThemes(in: app)
        }
        app.terminate()
        app.launch()
        openThemes(in: app)
        let lowPoly = app.buttons["landscape-theme-low-poly"]
        if !lowPoly.isHittable { app.swipeUp() }
        XCTAssertEqual(lowPoly.value as? String, "Selected")
    }

    private func openThemes(in app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let themes = app.buttons["settings-landscape-theme"]
        if !themes.isHittable { app.swipeUp() }
        themes.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
