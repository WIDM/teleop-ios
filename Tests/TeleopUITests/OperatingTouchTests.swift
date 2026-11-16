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

    /// The gear opens Settings while stopped too, and Settings then says plainly that the robot is stopped and how to
    /// leave the stop, so the stop is never hidden behind it.
    func testSettingsShowsTheStopWhileStopped() {
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        XCTAssertFalse(app.element("settings.stopped").exists, "nothing while not stopped")
        app.element("settings.done").tap()

        app.element("operating.stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        app.element("operating.gear").tap()
        expect(app, "settings.stopped")
        let band = app.element("settings.stopped")
        XCTAssertTrue(band.label.contains("STOPPED"), band.label)
        XCTAssertTrue(band.label.contains("Tap Done, then hold the top edge to reset."), band.label)
        XCTAssertLessThan(band.frame.minY, app.element("settings.done").frame.minY, "above everything else")
        attachScreenshot("settings-stopped")
        app.element("settings.done").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
    }

    func testTheStopBandOnSettingsStopsToo() {
        app.element("operating.gear").tap()
        expect(app, "stop")
        app.element("stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
    }
}
