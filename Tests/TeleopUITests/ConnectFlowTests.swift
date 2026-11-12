import XCTest

/// First run, the tutorial pages, later launches and the Connect screen.
final class ConnectFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A fresh install: permissions, the three tutorial pages (back and forth), then the operating screen.
    func testFirstRunWalksThroughTheTutorialToTheOperatingScreen() {
        let app = XCUIApplication.teleop(["-firstRunDone", "NO"])
        app.launch()
        expect(app, "permissions.continue")
        attachScreenshot("01-permissions")
        app.element("permissions.continue").tap()
        answerSystemPrompts(allow: true)

        expect(app, "tutorial.skip")
        XCTAssertEqual(app.element("tutorial.title").label, "The two keys")
        XCTAssertTrue(text(app, "One thing at a time"), "rule O8")
        attachScreenshot("02-tutorial-keys")
        app.element("tutorial.next").tap()
        expectLabel(app.element("tutorial.title"), "Thumb and turn")
        attachScreenshot("03-tutorial-thumb")
        app.element("tutorial.next").tap()
        expectLabel(app.element("tutorial.title"), "Stop, reset, and what you feel")
        XCTAssertFalse(app.element("tutorial.skip").exists, "the last page has Back, not Skip")
        XCTAssertTrue(text(app, "a purr means it is still on its way"), "rule O3, the cue the pause rests on")
        attachScreenshot("04-tutorial-cues")
        app.element("tutorial.back").tap()
        expectLabel(app.element("tutorial.title"), "Thumb and turn")
        app.element("tutorial.next").tap()
        app.element("tutorial.next").tap()
        expect(app, "operating.state")
    }

    private func text(_ app: XCUIApplication, _ part: String) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", part)).firstMatch.exists
    }

    func testTheTutorialTeachesTheChosenMode() {
        let keyTurns = XCUIApplication.teleop(["-startRoute", "t1_tutorial", "-controlMode", "keyTurns"])
        keyTurns.launch()
        expect(keyTurns, "tutorial.title")
        XCTAssertTrue(keyTurns.staticTexts.containing(NSPredicate(format: "label CONTAINS 'turn the phone: the wrist turns'")).firstMatch.exists)
        keyTurns.element("tutorial.next").tap()
        expectLabel(keyTurns.element("tutorial.title"), "The two halves of the screen")
        keyTurns.terminate()

        let buttons = XCUIApplication.teleop(["-startRoute", "t1_tutorial", "-controlMode", "buttons"], language: "zh-Hant")
        buttons.launch()
        expect(buttons, "tutorial.title")
        XCTAssertEqual(buttons.element("tutorial.title").label, "按住按鈕")
        attachScreenshot("tutorial-buttons-zh")
    }

    func testALaterLaunchOpensOnTheOperatingScreen() {
        let app = XCUIApplication.teleop()
        app.launch()
        expect(app, "operating.state")
        XCTAssertFalse(app.element("permissions.continue").exists)
        XCTAssertFalse(app.element("tutorial.skip").exists)
    }

    /// Nothing answers at the discard port: Connect says so and still offers practice.
    func testConnectShowsWhyItFailedAndOffersPractice() {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.quiet + [
            "-appLanguage", "en", "-serverAddress", "127.0.0.1:9", "-startRoute", "s1_connect", "-firstRunDone", "YES",
        ]
        app.launch()
        expect(app, "connect.failure", timeout: 8)
        // The link gives no reason of its own yet: the screen says only what it knows.
        XCTAssertEqual(app.element("connect.failure").label, "Could not connect to that address.")
        expect(app, "connect.practice")
        XCTAssertEqual(app.element("connect.practice").label, "Practice without a robot")
        attachScreenshot("connect-failed")
    }

    /// A later launch whose saved server does not answer lands on Not connected; tapping the word opens Connect (§7.2).
    func testTheNotConnectedWordOpensConnect() {
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.quiet + [
            "-appLanguage", "en", "-serverAddress", "127.0.0.1:9", "-startRoute", "p4_standby", "-firstRunDone", "YES",
            "-controlMode", "screenTurns",
        ]
        app.launch()
        expectLabel(app.element("operating.state"), "Not connected", timeout: 8)
        XCTAssertTrue(app.staticTexts["Tap here to choose a server"].exists)
        attachScreenshot("not-connected")
        app.element("operating.connect").tap()
        expect(app, "connect.address_field")
    }
}
