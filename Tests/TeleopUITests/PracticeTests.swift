import XCTest

/// Practice can never be taken for the real thing (§7.4): entered only from Connect or Settings, marked on every
/// screen, never "Connected", and gone after a relaunch.
final class PracticeTests: XCTestCase {
    /// On the real server at an address where nothing answers (the discard port), so the app stays unconnected.
    private func launchOnTheRealServer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            XCUIApplication.quiet + [
                "-appLanguage", "en", "-serverAddress", "127.0.0.1:9", "-startRoute", "s1_connect",
                "-controlMode", "screenTurns", "-hand", "right", "-firstRunDone", "YES",
            ]
        app.launch()
        return app
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testPracticeFromConnectIsMarkedOnEveryScreenUntilLeft() {
        let app = launchOnTheRealServer()
        expect(app, "connect.practice")
        XCTAssertFalse(app.element("practice.mark").exists, "not the default")
        app.element("connect.practice").tap()

        expectLabel(app.element("operating.state"), "Ready")
        XCTAssertTrue(app.element("practice.mark").exists)
        XCTAssertEqual(app.element("operating.rec").label, "Practice: nothing is recorded")
        XCTAssertEqual(app.element("operating.link").label, "No robot")
        assertNoConnectedWord(app)
        attachScreenshot("practice-operating")

        app.element("operating.gear").tap()
        expect(app, "settings.done")
        XCTAssertTrue(app.element("practice.mark").exists, "Settings")
        assertNoConnectedWord(app)
        attachScreenshot("practice-settings")

        app.element("stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        XCTAssertTrue(app.element("practice.mark").exists, "stopped")
        app.element("stop.release").press(forDuration: 1.3)
        expectLabel(app.element("operating.state"), "Ready")

        app.element("operating.gear").tap()
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.element("settings.server_practice").exists, "Connect would reach no server in practice")
        XCTAssertFalse(app.element("settings.connect").exists)
        app.element("settings.leave_practice").tap()
        XCTAssertTrue(app.element("practice.mark").waitForNonExistence(timeout: 3))
        expect(app, "settings.start_practice")
        XCTAssertTrue(app.element("settings.connect").exists)
        XCTAssertTrue(app.element("settings.disconnect").exists)
    }

    /// While the stop is latched the link cannot change, so practice is offered greyed out with the reason, and
    /// tapping it never opens the real server.
    func testPracticeIsRefusedWhileStoppedAndSaysWhy() {
        let app = launchOnTheRealServer()
        expect(app, "stop")
        app.element("stop").tap()
        // No server answers, so the STOP reached no robot: the screen says Not connected, never STOPPED (J7), and
        // the stop stays latched in the app until it is sent or released. The reason says so too.
        let reason = "Not while a STOP is waiting to reach the robot. Connect, then release the stop or reset."
        expectLabel(app.element("operating.state"), "Not connected")
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        app.swipeUp()
        app.swipeUp()
        expect(app, "settings.start_practice")
        XCTAssertFalse(app.element("settings.start_practice").isEnabled)
        XCTAssertTrue(app.element("settings.practice_stopped").exists, "the reason")
        XCTAssertEqual(app.element("settings.practice_stopped").label, reason)
        app.element("settings.start_practice").tap()
        XCTAssertFalse(app.element("practice.mark").exists)
        app.element("settings.disconnect").tap()

        expect(app, "connect.practice")
        XCTAssertFalse(app.element("connect.practice").isEnabled)
        XCTAssertTrue(app.element("connect.practice_stopped").exists, "the reason")
        XCTAssertEqual(app.element("connect.practice_stopped").label, reason)
        attachScreenshot("practice-refused-while-stopped")
        app.element("connect.practice").tap()
        XCTAssertTrue(app.element("connect.practice").waitForExistence(timeout: 2), "still on Connect")
        XCTAssertFalse(app.element("practice.mark").exists)
    }

    func testPracticeIsNotKeptAcrossALaunch() {
        let app = launchOnTheRealServer()
        expect(app, "connect.practice")
        app.element("connect.practice").tap()
        XCTAssertTrue(app.element("practice.mark").waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments =
            XCUIApplication.quiet + [
                "-appLanguage", "en", "-serverAddress", "127.0.0.1:9", "-startRoute", "p4_standby",
                "-controlMode", "screenTurns", "-hand", "right", "-firstRunDone", "YES",
            ]
        app.launch()
        expect(app, "operating.state")
        XCTAssertFalse(app.element("practice.mark").exists)
        XCTAssertNotEqual(app.element("operating.link").label, "No robot")
    }

    func testTheTutorialPagesAreMarkedInPractice() {
        let app = XCUIApplication.teleop(["-startRoute", "t1_tutorial"])
        app.launch()
        expect(app, "tutorial.next")
        XCTAssertTrue(app.element("practice.mark").exists)
        assertNoConnectedWord(app)
    }
}
