import XCTest

final class ConnectFlowScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // A fresh install: no -startRoute, and the first run not done yet.
        app.launchArguments += ["-appLanguage", "en", "-liveLink", "NO", "-firstRunDone", "NO"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
        element.tap()
    }

    private func expect(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
    }

    /// S2 -> T1 -> P4 -> P5 -> S1 -> P5 -> S1 -> P5 -> S1, Disconnect stays on S1 -> P5
    func testS1ThroughP5() {
        expect("permissions.continue")
        XCTAssertFalse(app.descendants(matching: .any)["standby.settings"].exists, "a fresh install opens on permissions")
        shot("01-S2-permissions")
        tap("permissions.continue")
        answerSystemPrompts(allow: true)

        expect("tutorial.skip")
        shot("02-T1-tutorial")
        tap("tutorial.skip")

        expect("standby.settings")
        shot("03-P4-standby")
        tap("status.chip")

        expect("connection.change_server")
        shot("04-P5-connection")
        tap("connection.change_server")

        expect("connect.connect")
        shot("05-S1-connect")
        tap("connect.connect")

        expect("connection.change_server")
        shot("06-P5-after-connect")
        tap("connection.change_server")

        expect("connect.back")
        tap("connect.back")
        expect("connection.change_server")
        shot("07-P5-after-back")
        tap("connection.change_server")

        expect("connect.disconnect")
        tap("connect.disconnect")
        expect("connect.connect")
        XCTAssertFalse(app.descendants(matching: .any)["connect.connection_lost"].exists, "a chosen disconnect is not a lost connection")
        shot("08-S1-after-disconnect")
        tap("connect.connect")
        expect("connection.change_server")
        shot("09-P5-final")
    }

    func testTutorialWalksThroughAllThreeSteps() {
        tap("permissions.continue")
        answerSystemPrompts(allow: true)
        tap("tutorial.next")
        tap("tutorial.next")
        tap("tutorial.back")
        expect("tutorial.skip")
        tap("tutorial.next")
        expect("tutorial.back")
        tap("tutorial.next")
        expect("standby.settings")
    }

    func testConnectionSheetOpensTheKeyboardAndCloses() {
        app.terminate()
        app.launchArguments = ["-appLanguage", "en", "-liveLink", "NO", "-firstRunDone", "YES"]
        app.launch()
        tap("status.chip")
        tap("connection.address")
        expect("connection.address_field")
        tap("keyboard.done")
        tap("connection.close")
        expect("standby.settings")
    }

    func testLaterLaunchOpensOnStandby() {
        app.terminate()
        app.launchArguments = ["-appLanguage", "en", "-liveLink", "NO", "-firstRunDone", "YES"]
        app.launch()
        expect("standby.settings")
        XCTAssertFalse(app.descendants(matching: .any)["permissions.continue"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["tutorial.skip"].exists)
    }
}
