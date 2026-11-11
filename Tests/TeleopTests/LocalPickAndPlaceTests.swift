import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The pick-and-place done with each mode's own raw inputs (`ScriptedOperator`) through the app's model and link,
/// against the server model on a local socket. It runs in every default test run; `OperatorLiveTests` runs the same
/// scripts against the lab simulator.
final class LocalPickAndPlaceTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!

    override func tearDown() {
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
    }

    private func start(_ mode: ControlMode) throws {
        // Three and a half times the lab server's pace, so the script's waits shrink by about as much.
        server = LocalTeleopServer(config: .s4Simulator(stepsPerSecond: 60))
        try server.start()
        hand = ScriptedOperator(address: server.address, mode: mode, smoothing: 0.3, pace: 0.3)
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
        // The script skips without these, which suits the live server; against the local one it is a failure.
        _ = try XCTUnwrap(hand.model.link.cubePosition, "the local server reported no cube")
        _ = try XCTUnwrap(hand.model.link.goalPosition, "the local server reported no goal")
        _ = try XCTUnwrap(hand.model.link.armPosition, "the local server reported no arm position")
    }

    private func finishedTheTask() {
        XCTAssertEqual(server.inspect { $0.episode }, 1, "the scene reset once, after the success")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false)
    }

    func testPickAndPlaceSchemeA() throws {
        try start(.screenTurns)
        try hand.pickAndPlace(warmUpHolds: 0)
        finishedTheTask()
    }

    func testPickAndPlaceSchemeB() throws {
        try start(.keyTurns)
        try hand.pickAndPlace(warmUpHolds: 0)
        finishedTheTask()
    }

    func testPickAndPlaceButtons() throws {
        try start(.buttons)
        try hand.pickAndPlace(warmUpHolds: 0)
        finishedTheTask()
    }
}
