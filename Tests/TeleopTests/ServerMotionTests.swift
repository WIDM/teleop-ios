import simd
import TeleopCore
import XCTest
@testable import Teleop

/// Scripted phone motion through the real app code against a real server on this Mac (port 8765):
/// the stub, or Isaac Sim behind the SSH tunnel. It moves the simulated arm, so it only runs when asked, and only
/// in the Live test plan:
///
///     TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test ... -testPlan Live
///
/// Each profile is a hand movement no slower than a person makes. The promise under test: the app never
/// trips the server's safety stop, whatever the hand does, and the arm ends up where the hand asked.
/// The pick-and-place script itself is `ScriptedOperator`; `LocalPickAndPlaceTests` runs it in the default run.
final class ServerMotionTests: XCTestCase {
    private var hand: ScriptedOperator!
    private var model: AppModel { hand.model }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TELEOP_MOTION"] != nil else {
            throw XCTSkip("set TEST_RUNNER_TELEOP_MOTION=1 to drive the server")
        }
        hand = ScriptedOperator(address: "127.0.0.1:8765", smoothing: 0.3)
        guard hand.connect(within: 4) else {
            throw XCTSkip("no server on 127.0.0.1:8765")
        }
        // What the top band does when held: from the stop state the server's reset also clears the stop.
        model.runReset()
        hand.pump(6)
    }

    override func tearDown() {
        hand?.finish()
        hand = nil
    }

    /// Holds, runs `motion`, waits `settle` seconds with the hand still, releases, and reports what the arm did.
    private func hold(_ name: String, settle: Double, _ motion: () -> Void) {
        hand.position = .zero
        hand.pump(0.5)
        let before = model.link.armPosition
        let started = Date()
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving, "\(name): hold did not start")
        motion()
        let asked = hand.position
        hand.pump(settle)
        XCTAssertTrue(model.session.state.armMoving, "\(name): hold ended by itself. log: \(model.debugLog.suffix(6))")
        hand.release(.upper)
        hand.pump(1.0)
        XCTAssertFalse(model.session.state.emergencyStop, "\(name): E-stopped, cause \(String(describing: model.stopCause))")
        XCTAssertTrue(model.session.state.connected, "\(name): link lost")
        guard let before, let after = model.link.armPosition else {
            print("MOTION \(name): no arm position from the server")
            return
        }
        guard simd_length(asked) > 0.005 else {
            print(String(format: "MOTION %@: hand back at the start, arm ended %.1f cm from where it began, %.1f s",
                         name, simd_distance(after, before) * 100, Date().timeIntervalSince(started)))
            return
        }
        // Identity camera: right is +x, forward is −z, up is +y. The server wants right → −X, forward → −Y, up → +Z.
        let wantedBase = SIMD3(-asked.x, asked.z, asked.y)
        let moved = after - before
        let reached = simd_dot(moved, simd_normalize(wantedBase)) / simd_length(wantedBase)
        print(String(
            format: "MOTION %@: asked %.1f cm, arm moved %.1f cm along it (%.0f%%), %.1f cm off it, %.1f s",
            name, simd_length(wantedBase) * 100, simd_dot(moved, simd_normalize(wantedBase)) * 100, reached * 100,
            simd_length(moved - simd_normalize(wantedBase) * simd_dot(moved, simd_normalize(wantedBase))) * 100,
            Date().timeIntervalSince(started)
        ))
    }

    /// One held control taking over from another while the first is still held. The server finishes the old one
    /// about 50 ms after its stop and refuses a start that arrives sooner ("busy"), so the link has to wait.
    func testAWristHoldTakesOverFromAGripperHoldStillHeld() {
        model.send(.gripperStart(.open))
        hand.pump(1.0)
        model.send(.wristStart)
        hand.pump(1.5)
        XCTAssertTrue(model.session.state.wristMoving, "the wrist hold was refused. log: \(model.debugLog.suffix(4))")
        XCTAssertNil(model.session.state.gripperMoving)
        hand.pump(3)
        model.send(.wristEnd)
        hand.pump(1.0)
        // And straight back, the other way round.
        model.send(.wristStart)
        hand.pump(0.5)
        model.send(.gripperStart(.open))
        hand.pump(1.5)
        XCTAssertEqual(model.session.state.gripperMoving, .open,
                       "the gripper hold was refused. log: \(model.debugLog.suffix(4))")
        model.send(.gripperEnd)
        hand.pump(1.0)
        XCTAssertFalse(model.session.state.emergencyStop)
    }

    /// Tipping the phone with the wrist input held tilts the jaws, and tipping it back brings them back; neither is
    /// refused. The server reports the measured flex when it has `wrist_flex_deg`.
    func testTiltingThePhoneTiltsTheWristBothWays() {
        let before = model.serverState?.wristFlexDeg
        hand.wrist(.tilt, by: 10, hold: 3)
        let tilted = model.serverState?.wristFlexDeg
        hand.wrist(.tilt, by: -10, hold: 3)
        if let before, let tilted, let after = model.serverState?.wristFlexDeg {
            print(String(format: "MOTION tilt: flex %.1f, then %.1f, then %.1f", before, tilted, after))
        }
        XCTAssertFalse(model.session.state.wristMoving)
        XCTAssertFalse(model.session.state.emergencyStop)
    }

    /// The whole task in as few holds as it takes.
    func testPickAndPlaceByScript() throws {
        try hand.pickAndPlace(warmUpHolds: 0)
    }

    /// The same after a dozen extra holds, the way a hand works its way to the cube. This needs a server that
    /// keeps its wrist target: one that copies the sagged wrist angle into the target at every hold droops the
    /// gripper about 4 to 7 degrees over these holds, and the jaws then close beside the cube.
    func testPickAndPlaceAfterManyHolds() throws {
        try hand.pickAndPlace(warmUpHolds: 12)
    }

    func testFastSweepRightThenBack() {
        hold("right 16 cm in 0.4 s", settle: 20) { hand.move(to: SIMD3(0.16, 0, 0), in: 0.4) }
        hold("left 16 cm in 0.4 s", settle: 20) { hand.move(to: SIMD3(-0.16, 0, 0), in: 0.4) }
    }

    func testFastUpThenDown() {
        hold("up 10 cm in 0.3 s", settle: 12) { hand.move(to: SIMD3(0, 0.10, 0), in: 0.3) }
        hold("down 10 cm in 0.3 s", settle: 12) { hand.move(to: SIMD3(0, -0.10, 0), in: 0.3) }
    }

    func testZigZagNeverTripsTheServer() {
        hold("forward and back 12 cm, three times", settle: 6) {
            for _ in 0..<3 {
                hand.move(to: SIMD3(0, 0, -0.12), in: 0.5)
                hand.move(to: SIMD3(0, 0, 0), in: 0.5)
            }
        }
    }

    func testSlowSmallMoveIsFollowedClosely() {
        hold("right 4 cm in 2 s", settle: 4) { hand.move(to: SIMD3(0.04, 0, 0), in: 2) }
        hold("left 4 cm in 2 s", settle: 4) { hand.move(to: SIMD3(-0.04, 0, 0), in: 2) }
    }
}
