import XCTest

final class ConnectFlowScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-appLanguage", "en", "-liveLink", "NO"]
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

    /// P1 -> S2 -> T1 -> P4 -> P5 -> S1 -> P5 -> S1 -> P5 -> S1, Disconnect stays on S1 -> P5
    func testS1ThroughP5() {
        expect("mode.next")
        shot("01-P1-mode-select")
        tap("mode.next")

        expect("permissions.continue")
        shot("02-S2-permissions")
        tap("permissions.continue")
        answerSystemPrompts(allow: true)

        expect("tutorial.skip")
        shot("03-T1-tutorial")
        tap("tutorial.skip")

        expect("standby.settings")
        shot("04-P4-standby")
        tap("status.chip")

        expect("connection.change_server")
        shot("05-P5-connection")
        tap("connection.change_server")

        expect("connect.connect")
        shot("06-S1-connect")
        tap("connect.connect")

        expect("connection.change_server")
        shot("07-P5-after-connect")
        tap("connection.change_server")

        expect("connect.back")
        tap("connect.back")
        expect("connection.change_server")
        shot("08-P5-after-back")
        tap("connection.change_server")

        expect("connect.disconnect")
        tap("connect.disconnect")
        expect("connect.connect")
        XCTAssertFalse(app.descendants(matching: .any)["connect.connection_lost"].exists, "a chosen disconnect is not a lost connection")
        shot("09-S1-after-disconnect")
        tap("connect.connect")
        expect("connection.change_server")
        shot("11-P5-final")
    }
}
