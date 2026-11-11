import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The scripted pick-and-place of `ServerMotionTests`, the same script through the app's own model and link,
/// against the server model on a local socket. It runs in every default test run; the live one does not.
final class LocalPickAndPlaceTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!

    override func setUpWithError() throws {
        // Three and a half times the lab server's pace, so the script's waits shrink by about as much.
        server = LocalTeleopServer(config: .s4Simulator(stepsPerSecond: 60))
        try server.start()
        hand = ScriptedOperator(address: server.address, smoothing: 0.3, pace: 0.3)
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
    }

    override func tearDown() {
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
    }

    func testPickAndPlaceByScript() throws {
        try hand.pickAndPlace(warmUpHolds: 0)
        XCTAssertEqual(server.inspect { $0.episode }, 1, "the scene reset once, after the success")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false)
    }
}
