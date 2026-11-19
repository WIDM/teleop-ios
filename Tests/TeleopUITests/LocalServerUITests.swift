import TeleopServerHost
import TeleopServerModel
import XCTest

/// The app with its live link on, against the server model this test process serves on 127.0.0.1.
final class LocalServerUITests: XCTestCase {
    private var server: LocalTeleopServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = LocalTeleopServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func launchOnTheLocalServer(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.teleop(["-liveLink", "YES", "-serverAddress", server.address] + extra)
        app.launch()
        return app
    }

    func testLaunchWithASavedAddressReachesTheLocalServer() {
        let app = launchOnTheLocalServer(["-startRoute", "s1_connect"])
        // With a saved address the app opens the socket at launch, so there is no Connect to press. The operating
        // screen comes up only once the server has answered hello with welcome and a state.
        let state = app.element("operating.state")
        XCTAssertTrue(state.waitForExistence(timeout: 5), "the app did not connect to \(server.address)")
        expectLabel(state, "Ready")
        XCTAssertEqual(app.element("operating.link").label, "Link up")
        // The control connection, and the listening one the app opens right after its welcome.
        let deadline = Date().addingTimeInterval(3)
        while server.inspect({ $0.welcomedClients }) < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(server.inspect { $0.welcomedClients }, 2)
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false)
    }

    /// In real use the guide draws the arm the server reports, while connected and after a hold: scheme B's far half
    /// opens the jaws, and the jaw read-out follows.
    func testTheGuideIsOnScreenWhileConnectedAndAfterAHold() {
        let app = launchOnTheLocalServer(["-startRoute", "p4_standby", "-controlMode", "keyTurns"])
        expectLabel(app.element("operating.state"), "Ready")
        expect(app, "guide")
        expect(app, "guide.above")
        expect(app, "guide.behind")
        let jaws = app.element("readout.jaws")
        XCTAssertTrue(jaws.waitForExistence(timeout: 5))
        let before = jaws.label
        attachScreenshot("guide-local-server-before")

        // The far half for a right hand is the left one: hold it to open the jaws.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(forDuration: 2)
        expect(app, "guide")
        let opened = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: jaws)],
            timeout: 5
        )
        XCTAssertEqual(opened, .completed, "the jaw read-out still says \(before) after the hold")
        XCTAssertGreaterThan(server.inspect { $0.world.jaw }, 10, "the hold opened the jaws")
        attachScreenshot("guide-local-server-after")
    }
}
