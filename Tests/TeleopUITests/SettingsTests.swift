import XCTest

/// Settings (§7.3): version 1 rows only, and each one changes what the operating screen does.
final class SettingsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.teleop(["-startRoute", "p4_standby"])
        app.launch()
        expectLabel(app.element("operating.state"), "Ready")
    }

    private func openSettings() {
        app.element("operating.gear").tap()
        expect(app, "settings.done")
    }

    private func done() {
        app.element("settings.done").tap()
        expect(app, "operating.state")
    }

    func testModeSwitchesBetweenButtonsAndTheTwoSchemes() {
        XCTAssertEqual(app.element("operating.mode").label, "Screen turns (A)")
        openSettings()
        app.buttons["Buttons"].tap()
        done()
        expect(app, "buttons.forward")
        XCTAssertEqual(app.element("operating.mode").label, "Buttons")
        attachScreenshot("settings-buttons-mode")

        openSettings()
        app.buttons["Key turns (B)"].tap()
        done()
        XCTAssertEqual(app.element("operating.mode").label, "Key turns (B)")
        XCTAssertFalse(app.element("buttons.forward").exists)
        expect(app, "operating.hint_close")

        openSettings()
        app.buttons["Screen turns (A)"].tap()
        done()
        XCTAssertEqual(app.element("operating.mode").label, "Screen turns (A)")
        expect(app, "operating.hint")
    }

    func testHandPutsTheNearSideControlsUnderTheThumb() {
        openSettings()
        app.buttons["Buttons"].tap()
        app.buttons["Left"].tap()
        done()
        expect(app, "buttons.close")
        XCTAssertLessThan(
            app.element("buttons.close").frame.midX, app.element("buttons.open").frame.midX,
            "left hand: Close on the left")
        openSettings()
        app.buttons["Right"].tap()
        done()
        XCTAssertGreaterThan(
            app.element("buttons.close").frame.midX, app.element("buttons.open").frame.midX,
            "right hand: Close on the right")
    }

    func testOnlyTheVersionOneRowsAreThere() {
        openSettings()
        for row in ["Mode", "Hand", "Arm speed", "Smoothing", "Show the guide"] {
            XCTAssertTrue(app.staticTexts[row].exists, row)
        }
        for gone in ["Deadband", "Real server", "Voice", "Export log", "Sensitivity"] {
            XCTAssertFalse(app.staticTexts[gone].exists, gone)
        }
        XCTAssertTrue(app.element("stop").exists, "a STOP band is pinned to the bottom")
        app.swipeUp()
        app.swipeUp()
        // These tests run in practice, where Connect would reach no server: the row says so instead.
        for id in [
            "settings.rec_status", "settings.address", "settings.server_practice", "settings.leave_practice",
            "settings.language", "settings.version",
        ] {
            XCTAssertTrue(app.element(id).exists, id)
        }
        XCTAssertFalse(app.element("settings.connect").exists)
        XCTAssertFalse(app.element("settings.disconnect").exists)
        XCTAssertTrue(app.element("stop").isHittable, "the band stays put while the rows scroll")
        attachScreenshot("settings-lower-rows")
    }

    /// After the first run the tutorial is still there: Settings opens it, and its last page comes back to the
    /// operating screen.
    func testTheTutorialOpensAgainFromSettingsAndComesBack() {
        openSettings()
        let replay = app.element("settings.replay_tutorial")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(replay.waitForExistence(timeout: 3))
        replay.tap()
        expectLabel(app.element("tutorial.title"), "The two keys")
        app.element("tutorial.next").tap()
        expectLabel(app.element("tutorial.title"), "Thumb and turn")
        app.element("tutorial.next").tap()
        expectLabel(app.element("tutorial.title"), "Stop, reset, and what you feel")
        app.element("tutorial.next").tap()
        expectLabel(app.element("operating.state"), "Ready")
        XCTAssertFalse(app.element("tutorial.title").exists)
    }

    /// While the robot is stopped the tutorial is not offered: its pages do not show the stop.
    func testTheTutorialIsNotOfferedWhileStopped() {
        app.element("operating.stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        openSettings()
        expect(app, "settings.stopped")
        app.swipeUp()
        app.swipeUp()
        expect(app, "settings.language")
        XCTAssertFalse(app.element("settings.replay_tutorial").exists)
    }

    func testFiveTapsOnTheVersionShowTheDeveloperLog() {
        openSettings()
        app.swipeUp()
        app.swipeUp()
        let version = app.element("settings.version")
        XCTAssertTrue(version.waitForExistence(timeout: 3))
        XCTAssertTrue(version.label.hasPrefix("Version "))
        for _ in 0..<4 { version.tap() }
        XCTAssertFalse(app.element("settings.clear_log").exists)
        version.tap()
        app.swipeUp()
        expect(app, "settings.clear_log")
        XCTAssertTrue(app.element("settings.log").label.contains("openSettings"))
    }

    func testLanguageSwitchesToChineseAndBack() {
        openSettings()
        app.swipeUp()
        app.swipeUp()
        app.element("settings.language").tap()
        app.buttons["中文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["設定"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("stop").label, "STOP 急停")
        app.swipeUp()
        app.swipeUp()
        app.element("settings.language").tap()
        app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }
}
