import TeleopCore
import XCTest
@testable import Teleop

/// The raw-input pick-and-place of `LocalPickAndPlaceTests`, one test per mode, against a real server on this Mac
/// (port 8765: Isaac Sim behind the relay; `TEST_RUNNER_TELEOP_ADDRESS` names another address). It moves the
/// simulated arm, so it runs only in the Live test plan and only when asked, as `ServerMotionTests` does:
///
///     TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test ... -testPlan Live
///
/// `testEveryDirectionGoesTheNamedWay` is the direction check for a new arm; see `docs/PROFILE.md`.
///
/// It needs the simulator's scene at its reset pose with nobody else driving it. It may run in a recording session,
/// where each success saves a take; it has not been tried in one yet.
///
/// A run passes only on what the server reported (`ScriptedOperator.pickAndPlace`), and fails at the step where a
/// working link went down, with the app's last log lines. Each run prints one `PICK RUN` line: the scheme, the
/// episode before and after, whether a success was seen, how many holds the server ended, whether the link was lost,
/// and the recorder as the phone holds it (state, session, saved count). Check it against the server's own log of
/// successes and, in a recording session, against the session's file; `docs/TESTING.md` says how to count runs.
final class OperatorLiveTests: XCTestCase {
    private var hand: ScriptedOperator!

    private func start(_ mode: ControlMode, profile: RobotProfile = TestProfiles.so101) throws {
        guard ProcessInfo.processInfo.environment["TELEOP_MOTION"] != nil else {
            throw XCTSkip("set TEST_RUNNER_TELEOP_MOTION=1 to drive the server")
        }
        let address = ScriptedOperator.liveServerAddress
        hand = ScriptedOperator(address: address, mode: mode, smoothing: 0.3, profile: profile)
        guard hand.connect(within: 4) else { throw XCTSkip("no server on \(address)") }
        let model = hand.model!
        hand.step = "the reset before the run"
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

    /// The direction check (`DirectionCheck`) against the real server: six 1 cm moves, each read back from the server's
    /// state, each along the base axis the profile names: the SO-101's, or the one `TEST_RUNNER_TELEOP_PROFILE` names by
    /// id (a file in `App/Resources/Profiles`). Run it first on a new arm, with the arm clear.
    func testEveryDirectionGoesTheNamedWay() throws {
        try start(.buttons, profile: try TestProfiles.chosenForLiveRuns())
        let faults = try XCTUnwrap(hand.directionCheckFaults(), "the check could not read the arm")
        XCTAssertEqual(faults, [], faults.joined(separator: "\n"))
    }
}
