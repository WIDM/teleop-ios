import simd
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

    private func start(_ mode: ControlMode, recorder: ServerModelConfig.Recorder? = nil) throws {
        // Three and a half times the lab server's pace, so the script's waits shrink by about as much.
        server = LocalTeleopServer(config: .s4Simulator(stepsPerSecond: 60, recorder: recorder))
        try server.start()
        hand = ScriptedOperator(address: server.address, mode: mode, smoothing: 0.3, pace: 0.3)
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
        // The script skips without these, which suits the live server; against the local one it is a failure.
        _ = try XCTUnwrap(hand.model.link.objectPosition, "the local server reported no cube")
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

    /// What the operating screen draws follows the server in real use, not only in fixtures: through a whole
    /// pick-and-place with a recorder, the guide's arm reading is there with the target and the goal, its pinch point
    /// moves during a hold, the jaw opening changes, gripping turns true, and the saved and wait states come up.
    func testTheGuideFollowsTheServerThroughAPickAndPlace() throws {
        try start(.screenTurns, recorder: .init())
        let model = hand.model!
        let first = try XCTUnwrap(model.operating.arm, "no arm reading once connected")
        XCTAssertNotNil(first.target)
        XCTAssertNotNil(first.goal)
        XCTAssertFalse(first.gripping)

        var readings = 0, withoutTaskObjects = 0
        var pinchAtHoldStart: SIMD3<Float>?
        var movedDuringAHold: Float = 0
        var jaws: [Double] = []
        var gripping = false
        var saved = false, waited = false
        hand.watch = {
            if let arm = model.operating.arm {
                readings += 1
                if arm.target == nil || arm.goal == nil { withoutTaskObjects += 1 }
                if let opening = arm.jawOpening { jaws.append(opening) }
                gripping = gripping || arm.gripping
                if model.session.state.armMoving {
                    let start = pinchAtHoldStart ?? arm.pinchPoint
                    pinchAtHoldStart = start
                    movedDuringAHold = max(movedDuringAHold, simd_distance(start, arm.pinchPoint))
                } else {
                    pinchAtHoldStart = nil
                }
            }
            switch model.operating.state {
            case .saved: saved = true
            case .wait: waited = true
            default: break
            }
        }
        try hand.pickAndPlace(warmUpHolds: 0)
        hand.watch = nil
        finishedTheTask()

        XCTAssertGreaterThan(readings, 100)
        XCTAssertEqual(withoutTaskObjects, 0, "the target and the goal are always there")
        XCTAssertGreaterThan(movedDuringAHold, 0.01, "the pinch point moves during a hold, from the listening connection")
        XCTAssertGreaterThan((jaws.max() ?? 0) - (jaws.min() ?? 0), 0.5, "the jaw opening follows the jaws")
        XCTAssertTrue(gripping, "the guide says holding once the jaws grip")
        XCTAssertTrue(saved, "the saved take reaches the screen")
        XCTAssertTrue(waited, "the server's save and reset reach the screen as Wait")
    }
}
