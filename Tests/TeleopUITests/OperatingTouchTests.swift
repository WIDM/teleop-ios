import XCTest

/// Touches on the operating screen reach the model through the touch surface and the input rules: each test checks
/// what the model did by what the screen then shows.
final class OperatingTouchTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.teleop(["-startRoute", "p4_standby", "-recordHaptics", "YES"])
        app.launch()
        expectLabel(app.element("operating.state"), "Ready")
    }

    func testATapOnTheStopBandStopsAndAHoldOnReleaseLeavesTheStop() {
        app.element("operating.stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        XCTAssertTrue(app.staticTexts["You pressed stop"].exists, "the cause")
        XCTAssertTrue(app.staticTexts["Hold the top edge to reset"].exists)
        // Practice has no recorder, so Release, keep scene is offered (§6.5); a short press does nothing.
        let release = app.element("stop.release")
        XCTAssertTrue(release.waitForExistence(timeout: 2))
        release.press(forDuration: 0.3)
        XCTAssertEqual(app.element("operating.state").label, "STOPPED")
        release.press(forDuration: 1.3)
        expectLabel(app.element("operating.state"), "Ready")
        XCTAssertFalse(release.exists)
    }

    func testATapOnTheGearOpensSettings() {
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        app.element("settings.done").tap()
        expectLabel(app.element("operating.state"), "Ready")
    }

    func testTheStopBandOnSettingsStopsToo() {
        app.element("operating.gear").tap()
        expect(app, "stop")
        app.element("stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
    }
}
