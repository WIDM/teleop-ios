import XCTest
@testable import Teleop

/// The raw-input pick-and-place of `LocalPickAndPlaceTests`, one test per mode, against a real server on this Mac
/// (port 8765: Isaac Sim behind the relay). It moves the simulated arm, so it runs only in the Live test plan and only
/// when asked, as `ServerMotionTests` does:
///
///     TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test ... -testPlan Live
///
/// It needs the simulator's scene at its reset pose with nobody else driving it, and no recording session (a
/// success there pauses for the save).
final class OperatorLiveTests: XCTestCase {
    private var hand: ScriptedOperator!

    private func start(_ mode: ControlMode) throws {
        guard ProcessInfo.processInfo.environment["TELEOP_MOTION"] != nil else {
            throw XCTSkip("set TEST_RUNNER_TELEOP_MOTION=1 to drive the server")
        }
        hand = ScriptedOperator(address: "127.0.0.1:8765", mode: mode, smoothing: 0.3)
        guard hand.connect(within: 4) else { throw XCTSkip("no server on 127.0.0.1:8765") }
        let model = hand.model!
        // The reset as a hand makes it: hold the top band 2 s. In the stop state the reset also releases the stop.
        let band = hand.topBand
        let touch = hand.touchDown(x: band.x, y: band.y)
        _ = hand.wait(2.3, until: { false })
        hand.touchUp(touch, x: band.x, y: band.y)
        _ = hand.wait(15, until: { !model.session.state.emergencyStop && !model.link.resetPending })
        hand.pump(6)
    }

    override func tearDown() {
        hand?.finish()
        hand = nil
    }

    func testPickAndPlaceSchemeA() throws {
        try start(.screenTurns)
        try hand.pickAndPlace(warmUpHolds: 0)
    }

    func testPickAndPlaceSchemeB() throws {
        try start(.keyTurns)
        try hand.pickAndPlace(warmUpHolds: 0)
    }

    func testPickAndPlaceButtons() throws {
        try start(.buttons)
        try hand.pickAndPlace(warmUpHolds: 0)
    }
}
