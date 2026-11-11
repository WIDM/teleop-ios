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
        XCTAssertLessThan(app.element("buttons.close").frame.midX, app.element("buttons.open").frame.midX, "left hand: Close on the left")
        openSettings()
        app.buttons["Right"].tap()
        done()
        XCTAssertGreaterThan(app.element("buttons.close").frame.midX, app.element("buttons.open").frame.midX, "right hand: Close on the right")
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
        for id in ["settings.rec_status", "settings.address", "settings.connect", "settings.disconnect", "settings.leave_practice", "settings.language", "settings.version"] {
            XCTAssertTrue(app.element(id).exists, id)
        }
        XCTAssertTrue(app.element("stop").isHittable, "the band stays put while the rows scroll")
        attachScreenshot("settings-lower-rows")
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
