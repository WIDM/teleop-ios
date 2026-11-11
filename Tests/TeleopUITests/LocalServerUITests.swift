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

    func testLaunchWithASavedAddressReachesTheLocalServer() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-appLanguage", "en", "-liveLink", "YES", "-serverAddress", server.address, "-startRoute", "s1_connect",
        ]
        app.launch()
        // With a saved address the app opens the socket at launch, so there is no Connect to press.
        // P5 comes up only once the server has answered hello with welcome and a state.
        XCTAssertTrue(app.descendants(matching: .any)["connection.change_server"].firstMatch.waitForExistence(timeout: 5),
                      "the app did not connect to \(server.address)")
        // The control connection, and the listening one the app opens right after its welcome.
        let deadline = Date().addingTimeInterval(3)
        while server.inspect({ $0.welcomedClients }) < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(server.inspect { $0.welcomedClients }, 2)
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false)
    }
}
