import simd
import TeleopCore
import XCTest
@testable import Teleop

/// Scripted phone motion through the real app code against a real server on this Mac (port 8765):
/// the stub, or Isaac Sim behind the SSH tunnel. It moves the simulated arm, so it only runs when asked:
///
///     TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test ... -only-testing:TeleopTests/ServerMotionTests
///
/// Each profile is a hand movement no slower than a person makes. The promise under test: the app never
/// trips the server's safety stop, whatever the hand does, and the arm ends up where the hand asked.
final class ServerMotionTests: XCTestCase {
    private var position = SIMD3<Float>.zero
    private var model: AppModel!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TELEOP_MOTION"] != nil else {
            throw XCTSkip("set TEST_RUNNER_TELEOP_MOTION=1 to drive the server")
        }
        position = .zero
        model = AppModel(
            start: .s1,
            haptics: NoHaptics(),
            pose: { [unowned self] in
                return TestPose.portrait(at: position)
            },
            liveLink: true
        )
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.session.state.setSmoothing(0.3)
        model.connect()
        guard wait(4, until: { model.session.state.connected || model.session.state.serverInputError }),
              model.session.state.connected else {
            throw XCTSkip("no server on 127.0.0.1:8765")
        }
        if model.session.state.emergencyStop {
            model.send(.releaseStop)
            pump(1.5)
        }
        model.send(.resetScene)
        pump(6)
    }

    override func tearDown() {
        if model?.session.state.armMoving == true { model.send(.holdArmEnd) }
        pump(1)
        model?.send(.switchMode)
        model = nil
    }

    private func pump(_ seconds: TimeInterval) { _ = wait(seconds, until: { false }) }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    /// Moves the hand to `target` (operator frame: right, up, back in metres) in `seconds`, 30 steps a second.
    private func move(to target: SIMD3<Float>, in seconds: Double) {
        // By the clock, not by step count: a late timer must not turn into a jump the app would refuse.
        let from = position
        let started = Date()
        while true {
            let share = min(Date().timeIntervalSince(started) / seconds, 1)
            position = from + (target - from) * Float(share)
            if share >= 1 { break }
            pump(1.0 / 120)
        }
    }

    /// Holds, runs `motion`, waits `settle` seconds with the hand still, releases, and reports what the arm did.
    private func hold(_ name: String, settle: Double, _ motion: () -> Void) {
        position = .zero
        pump(0.5)
        let before = model.link.armPosition
        let started = Date()
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving, "\(name): hold did not start")
        motion()
        let asked = position
        pump(settle)
        XCTAssertTrue(model.session.state.armMoving, "\(name): hold ended by itself. log: \(model.debugLog.suffix(6))")
        model.send(.holdArmEnd)
        pump(1.0)
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

    /// Moves the arm to a robot-base position, checking where the arm really is between holds. The server reports
    /// no position during a hold, so this is how an operator has to work too.
    ///
    /// Few holds on purpose. The server takes the wrist's sagged angle as its new target whenever a hold starts
    /// or ends, so every hold lets the gripper droop about 0.6 degrees more (measured 5.7 degrees over 10 holds),
    /// which moves the jaw tips away from where the grasp point was measured.
    @discardableResult
    private func moveArm(to target: SIMD3<Float>, _ name: String, maxHolds: Int = 2) -> Bool {
        let started = Date()
        var holds = 0
        pump(0.6)
        while holds < maxHolds {
            guard let arm = model.link.armPosition else { return false }
            let remaining = target - arm
            if simd_length(remaining) < 0.005 { break }
            // Operator frame: right is −X, forward is −Y, up is +Z. An upright phone: right +x, up +y, forward −z.
            let hand = SIMD3(-remaining.x, remaining.z, remaining.y)
            position = .zero
            pump(0.3)
            model.send(.holdArmStart)
            guard model.session.state.armMoving else {
                print("PICK \(name): hold did not start. log: \(model.debugLog.suffix(3))")
                return false
            }
            move(to: hand, in: max(Double(simd_length(remaining)) / 0.15, 0.4))
            pump(5)
            model.send(.holdArmEnd)
            pump(1.2)
            holds += 1
            if model.session.state.emergencyStop { break }
        }
        let arm = model.link.armPosition ?? target
        let off = simd_distance(arm, target)
        print(String(format: "PICK %@: %d holds, %.0f s, ended %.1f cm from target, arm at (%.1f, %.1f, %.1f) cm, estop %@",
                     name, holds, Date().timeIntervalSince(started), off * 100, arm.x * 100, arm.y * 100, arm.z * 100,
                     model.session.state.emergencyStop ? "YES" : "no"))
        return off < 0.008
    }

    private func gripper(_ target: GripperState, seconds: Double) {
        model.send(.gripperStart(target))
        pump(seconds)
        model.send(.gripperEnd)
        pump(1.0)
    }

    /// One full press of a jaw-turn handle. The server reports no joint angle, so the only way to know the
    /// 45 degrees are done is to hold long enough for a slow simulator.
    private func turnJaws(_ direction: TurnDirection) {
        model.send(.turnStart(direction))
        XCTAssertEqual(model.session.state.jawTurning, direction, "the turn did not start. log: \(model.debugLog.suffix(3))")
        pump(20)
        model.send(.turnEnd)
        pump(1.5)
    }

    /// One held control taking over from another while the first is still held. The server finishes the old one
    /// about 50 ms after its stop and refuses a start that arrives sooner ("busy"), so the link has to wait.
    func testTurnTakesOverFromAGripperHoldStillHeld() {
        model.send(.gripperStart(.open))
        pump(1.0)
        model.send(.turnStart(.positive))
        pump(1.5)
        XCTAssertEqual(model.session.state.jawTurning, .positive,
                       "the turn was refused. log: \(model.debugLog.suffix(4))")
        XCTAssertNil(model.session.state.gripperMoving)
        pump(3)
        model.send(.turnEnd)
        pump(1.0)
        // And straight back, the other way round.
        model.send(.turnStart(.negative))
        pump(0.5)
        model.send(.gripperStart(.open))
        pump(1.5)
        XCTAssertEqual(model.session.state.gripperMoving, .open,
                       "the gripper hold was refused. log: \(model.debugLog.suffix(4))")
        model.send(.gripperEnd)
        pump(1.0)
        XCTAssertFalse(model.session.state.emergencyStop)
    }

    /// The wrist pitch handles: a press tilts the jaws and is not refused, and the opposite press follows it at once.
    /// The angles themselves are only in the server's log (it reports none): 40 to 50 and back on 2026-11-11.
    func testTiltPressesAreAcceptedBothWays() {
        model.send(.turnStart(.tiltDown))
        pump(4)
        XCTAssertEqual(model.session.state.jawTurning, .tiltDown, "the tilt was refused. log: \(model.debugLog.suffix(4))")
        model.send(.turnEnd)
        model.send(.turnStart(.tiltUp))
        pump(4)
        XCTAssertEqual(model.session.state.jawTurning, .tiltUp, "the tilt back was refused. log: \(model.debugLog.suffix(4))")
        model.send(.turnEnd)
        pump(1.0)
        XCTAssertFalse(model.session.state.emergencyStop)
    }

    /// The whole task in as few holds as it takes.
    func testPickAndPlaceByScript() throws {
        try pickAndPlace(warmUpHolds: 0)
    }

    /// The same after a dozen extra holds, the way a hand works its way to the cube. This needs a server that
    /// keeps its wrist target: one that copies the sagged wrist angle into the target at every hold droops the
    /// gripper about 4 to 7 degrees over these holds, and the jaws then close beside the cube.
    func testPickAndPlaceAfterManyHolds() throws {
        try pickAndPlace(warmUpHolds: 12)
    }

    /// The whole task, done the way an operator would with the app's own controls: open, turn the jaws sideways,
    /// go to the grasp point the mini map shows, close, lift, carry, lower, open.
    private func pickAndPlace(warmUpHolds: Int) throws {
        let started = Date()
        let profile = RobotProfile.so101Simulator
        guard let cubeStart = model.link.cubePosition, let goal = model.link.goalPosition,
              let armStart = model.link.armPosition else {
            throw XCTSkip("the server did not report the cube, goal and arm positions")
        }
        print(String(format: "PICK start: arm (%.1f, %.1f, %.1f) cube (%.1f, %.1f, %.1f) goal (%.1f, %.1f, %.1f) cm",
                     armStart.x * 100, armStart.y * 100, armStart.z * 100, cubeStart.x * 100, cubeStart.y * 100,
                     cubeStart.z * 100, goal.x * 100, goal.y * 100, goal.z * 100))
        let lift = SIMD3<Float>(0, 0, 0.03)

        gripper(.open, seconds: 5)
        for hold in 0..<warmUpHolds {
            // Above the start pose only: there the jaw tips hang a centimetre over the cube.
            let up: Float = hold % 2 == 0 ? 0.03 : 0.015
            moveArm(to: armStart + SIMD3(0, 0, up), "warm-up hold \(hold + 1)", maxHolds: 1)
        }
        if !profile.jawsStartSideways {
            turnJaws(.positive)
            turnJaws(.positive)
        }
        // Where the reported gripper point has to be for the map's ring to sit on the cube, from where the cube
        // is now, as the map shows it.
        let cube = model.link.cubePosition ?? cubeStart
        let grasp = profile.inBase(world: cube) - profile.toolOffset
        moveArm(to: grasp + lift, "above the grasp point")
        guard moveArm(to: grasp, "grasp point") else {
            print("PICK RESULT: could not reach the grasp point")
            XCTFail("the arm could not reach the grasp point")
            return
        }
        gripper(.closed, seconds: 15)
        moveArm(to: grasp + lift, "lift 3 cm", maxHolds: 1)
        pump(1.0)
        let lifted = (model.link.cubePosition ?? cube).z - cube.z
        print(String(format: "PICK lift: cube rose %.1f cm", lifted * 100))
        guard lifted > 0.015 else {
            print("PICK RESULT: never lifted the cube")
            XCTFail("the cube was not lifted")
            return
        }
        var overGoal = grasp + SIMD3(goal.x - cube.x, goal.y - cube.y, 0)
        moveArm(to: overGoal + lift, "to the goal")
        // The cube sits ahead of the reported point, so it swings further than that point when the arm turns.
        // Steer the cube itself onto the goal, as the guide does while carrying.
        if let carried = model.link.cubePosition {
            let miss = SIMD3(goal.x - carried.x, goal.y - carried.y, 0)
            print(String(format: "PICK carried: cube at (%.1f, %.1f, %.1f) cm, %.1f cm from the goal across the table",
                         carried.x * 100, carried.y * 100, carried.z * 100, simd_length(miss) * 100))
            if simd_length(miss) > 0.005, carried.z - cube.z > 0.015 {
                overGoal += miss
                moveArm(to: overGoal + lift, "cube over the goal", maxHolds: 1)
            }
        }
        moveArm(to: overGoal + SIMD3(0, 0, 0.002), "down onto the goal", maxHolds: 1)
        gripper(.open, seconds: 5)
        moveArm(to: overGoal + lift, "lift away", maxHolds: 1)
        pump(4)
        let cubeEnd = model.link.cubePosition ?? cubeStart
        let inGoal = abs(cubeEnd.x - goal.x) <= 0.025 && abs(cubeEnd.y - goal.y) <= 0.025
        // A success resets the scene at once, which also puts the cube back at its start.
        let resetBySuccess = simd_distance(cubeEnd, cubeStart) < 0.005
        print(String(format: "PICK RESULT: cube ended (%.1f, %.1f, %.1f) cm, in goal %@, scene reset after success %@, %.0f s in all",
                     cubeEnd.x * 100, cubeEnd.y * 100, cubeEnd.z * 100,
                     inGoal ? "YES" : "no", resetBySuccess ? "YES" : "no", Date().timeIntervalSince(started)))
        XCTAssertFalse(model.session.state.emergencyStop)
        XCTAssertTrue(inGoal || resetBySuccess, "the cube did not end in the goal")
    }

    func testFastSweepRightThenBack() {
        hold("right 16 cm in 0.4 s", settle: 20) { move(to: SIMD3(0.16, 0, 0), in: 0.4) }
        hold("left 16 cm in 0.4 s", settle: 20) { move(to: SIMD3(-0.16, 0, 0), in: 0.4) }
    }

    func testFastUpThenDown() {
        hold("up 10 cm in 0.3 s", settle: 12) { move(to: SIMD3(0, 0.10, 0), in: 0.3) }
        hold("down 10 cm in 0.3 s", settle: 12) { move(to: SIMD3(0, -0.10, 0), in: 0.3) }
    }

    func testZigZagNeverTripsTheServer() {
        hold("forward and back 12 cm, three times", settle: 6) {
            for _ in 0..<3 {
                move(to: SIMD3(0, 0, -0.12), in: 0.5)
                move(to: SIMD3(0, 0, 0), in: 0.5)
            }
        }
    }

    func testSlowSmallMoveIsFollowedClosely() {
        hold("right 4 cm in 2 s", settle: 4) { move(to: SIMD3(0.04, 0, 0), in: 2) }
        hold("left 4 cm in 2 s", settle: 4) { move(to: SIMD3(-0.04, 0, 0), in: 2) }
    }
}
