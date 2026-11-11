import XCTest

/// Buttons found dead by hand on 2026-11-10, and the settings added for them.
final class SettingsAndButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", "p4_standby", "-startConnected", "YES", "-recordHaptics", "YES"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expect(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
    }

    private func openSettings() {
        expect("standby.settings")
        element("standby.settings").tap()
        expect("settings.done")
    }

    func testDebugLogHiddenUntilDeveloperMode() {
        openSettings()
        XCTAssertFalse(element("settings.log").exists)
        XCTAssertFalse(element("settings.clear_log").exists)
        element("settings.developer_mode").switches.firstMatch.tap()
        expect("settings.clear_log")
        XCTAssertTrue(element("settings.log").label.contains("openSettings"))
        element("settings.clear_log").tap()
        XCTAssertTrue(element("settings.log").label.contains("No events yet."))
    }

    func testLogRecordsActions() {
        expect("stop")
        element("standby.reset").tap()
        openSettings()
        element("settings.developer_mode").switches.firstMatch.tap()
        expect("settings.log")
        XCTAssertTrue(element("settings.log").label.contains("resetScene"))
    }

    func testStopOnEStopScreenKeepsOneBuzz() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        element("stop").tap()
        XCTAssertTrue(element("stop.release").exists)
        XCTAssertEqual(element("test.haptics").label, "log:emergencyLoop")
    }

    func testVolumeHintOpensOnScreenControls() {
        expect("volume_hint")
        element("volume_hint").tap()
        expect("fallback.hold")
    }

    func testLanguageSwitchesToChineseAndBack() {
        openSettings()
        element("settings.language").tap()
        app.buttons["中文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["設定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["停止"].exists)
        element("settings.language").tap()
        app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }
}
