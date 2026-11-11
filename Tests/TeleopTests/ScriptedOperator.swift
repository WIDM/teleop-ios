import simd
import TeleopCore
import XCTest
@testable import Teleop

/// Scripted phone motion through the app's own `AppModel` and link: the hand an operator moves, played by a test.
/// `ServerMotionTests` runs it against the live simulator; `LocalPickAndPlaceTests` against the server model on
/// a local socket.
final class ScriptedOperator {
    private(set) var model: AppModel!
    /// Where the hand is: an upright phone, right +x, up +y, back toward the operator +z, metres.
    var position = SIMD3<Float>.zero
    /// Scales every wait for the arm or the server, never the hand's own movements. 1 against the live simulator;
    /// less against a server that steps faster.
    let pace: Double

    init(address: String, smoothing: Double, pace: Double = 1) {
        self.pace = pace
        model = AppModel(
            start: .s1,
            haptics: NoHaptics(),
            pose: { [unowned self] in
                return TestPose.portrait(at: position)
            },
            liveLink: true
        )
        model.session.state.serverAddress = address
        model.session.state.setSmoothing(smoothing)
    }

    /// Connects and waits for the server's first state. False if it did not come within `seconds`.
    func connect(within seconds: TimeInterval) -> Bool {
        model.connect()
        return wait(seconds, until: { model.session.state.connected || model.session.state.serverInputError })
            && model.session.state.connected
    }

    /// Lets the app and the server run for `seconds` times `pace`.
    func pump(_ seconds: TimeInterval) { _ = wait(seconds * pace, until: { false }) }

    func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    /// Moves the hand to `target` (operator frame: right, up, back in metres) in `seconds`, 30 steps a second.
    func move(to target: SIMD3<Float>, in seconds: Double) {
        // By the clock, not by step count: a late timer must not turn into a jump the app would refuse.
        let from = position
        let started = Date()
        while true {
            let share = min(Date().timeIntervalSince(started) / seconds, 1)
            position = from + (target - from) * Float(share)
            if share >= 1 { break }
            _ = wait(1.0 / 120, until: { false })
        }
    }

    /// Moves the arm to a robot-base position, checking where the arm really is between holds. The server reports
    /// no position during a hold, so this is how an operator has to work too.
    ///
    /// Few holds on purpose. The server takes the wrist's sagged angle as its new target whenever a hold starts
    /// or ends, so every hold lets the gripper droop about 0.6 degrees more (measured 5.7 degrees over 10 holds),
    /// which moves the jaw tips away from where the grasp point was measured.
    @discardableResult
    func moveArm(to target: SIMD3<Float>, _ name: String, maxHolds: Int = 2) -> Bool {
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

    func gripper(_ target: GripperState, seconds: Double) {
        model.send(.gripperStart(target))
        pump(seconds)
        model.send(.gripperEnd)
        pump(1.0)
    }

    /// One full press of a jaw-turn handle. The server reports no joint angle, so the only way to know the
    /// 45 degrees are done is to hold long enough for a slow simulator.
    func turnJaws(_ direction: TurnDirection) {
        model.send(.turnStart(direction))
        XCTAssertEqual(model.session.state.jawTurning, direction, "the turn did not start. log: \(model.debugLog.suffix(3))")
        pump(20)
        model.send(.turnEnd)
        pump(1.5)
    }

    /// The whole task, done the way an operator would with the app's own controls: open, turn the jaws sideways,
    /// go to the grasp point the mini map shows, close, lift, carry, lower, open.
    func pickAndPlace(warmUpHolds: Int) throws {
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

    /// Ends whatever is held and closes the link, as `ServerMotionTests` has always done between tests.
    func finish() {
        if model.session.state.armMoving { model.send(.holdArmEnd) }
        pump(1)
        model.send(.switchMode)
    }
}
