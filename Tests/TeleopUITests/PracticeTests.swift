import XCTest

/// Practice can never be taken for the real thing (§7.4): entered only from Connect or Settings, marked on every
/// screen, never "Connected", and gone after a relaunch.
final class PracticeTests: XCTestCase {
    /// On the real server at an address where nothing answers (the discard port), so the app stays unconnected.
    private func launchOnTheRealServer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
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
        app.element("settings.leave_practice").tap()
        XCTAssertTrue(app.element("practice.mark").waitForNonExistence(timeout: 3))
        expect(app, "settings.start_practice")
    }

    func testPracticeIsNotKeptAcrossALaunch() {
        let app = launchOnTheRealServer()
        expect(app, "connect.practice")
        app.element("connect.practice").tap()
        XCTAssertTrue(app.element("practice.mark").waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = [
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
