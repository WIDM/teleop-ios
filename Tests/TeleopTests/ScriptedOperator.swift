import simd
import TeleopCore
import XCTest
@testable import Teleop

/// A hand that operates the app through its raw inputs only, the way a person can: volume keys down and up, touches
/// on the operating screen (slides as continuous 1 mm moves), the phone's position and attitude as ARKit would
/// report them, the pad's buttons, and waiting. It never sends a control action to the session.
///
/// `LocalOperatorTests` and `LocalPickAndPlaceTests` run it against the server model on a local socket;
/// `OperatorLiveTests` and `ServerMotionTests` against the live simulator.
final class ScriptedOperator {
    private(set) var model: AppModel!
    let mode: ControlMode
    /// Where the hand is: an upright phone, right +x, up +y, back toward the operator +z, metres.
    var position = SIMD3<Float>.zero
    /// How the phone is turned from upright, in the world.
    var rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    /// Scales every wait for the arm or the server, never the hand's own movements. 1 against the live simulator;
    /// less against a server that steps faster.
    let pace: Double
    /// The operating screen of the reference phone.
    let layout = SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34)
    /// Called on every turn of the run loop while the hand waits, so a test can watch what the app shows.
    var watch: (() -> Void)?
    private var nextTouchID = 1
    private var lastFrame: TimeInterval = 0
    private let savedMode: String?

    init(address: String, mode: ControlMode = .screenTurns, smoothing: Double, pace: Double = 1, haptics: HapticsPlaying = NoHaptics()) {
        self.mode = mode
        self.pace = pace
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
        model = AppModel(start: .s1, haptics: haptics, pose: { [unowned self] in camera }, liveLink: true)
        model.session.state.serverAddress = address
        model.session.state.setSmoothing(smoothing)
        model.controlMode = mode
        model.surfaceChanged(width: layout.width, height: layout.height, safeTop: 62, safeBottom: 34)
    }

    /// The camera transform ARKit would report for the hand now.
    var camera: simd_float4x4 {
        var pose = simd_float4x4(rotation) * TestPose.portrait
        pose.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return pose
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Connects, waits for the server's first state and goes to the operating screen. False if the state did not
    /// come within `seconds`.
    func connect(within seconds: TimeInterval) -> Bool {
        model.connect()
        let up = wait(seconds, until: { model.session.state.connected || model.session.state.serverInputError })
            && model.session.state.connected
        if up, model.session.route != .p4 { model.send(.closeConnection) }
        return up
    }

    /// Lets the app and the server run for `seconds` times `pace`.
    func pump(_ seconds: TimeInterval) { _ = wait(seconds * pace, until: { false }) }

    /// Runs the app, ARKit frames at 60 Hz included, until `done` or `seconds` have passed.
    func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            frame()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 240))
            watch?()
        }
        return done()
    }

    /// One ARKit frame, if one is due.
    private func frame() {
        let time = now
        guard time - lastFrame >= 1.0 / 60 else { return }
        lastFrame = time
        model.poseFrame(camera, at: time)
    }

    // MARK: Raw inputs

    func press(_ key: InputKey) { model.keyEvent(key, down: true) }
    func release(_ key: InputKey) { model.keyEvent(key, down: false) }

    /// A thumb comes down at `x`, `y` (points); returns the touch's id.
    @discardableResult
    func touchDown(x: Double, y: Double, radius: Double = 8) -> Int {
        let id = nextTouchID
        nextTouchID += 1
        model.touch(TouchSample(id: id, phase: .began, x: x, y: y, majorRadius: radius), at: now)
        return id
    }

    func touchMove(_ id: Int, x: Double, y: Double, radius: Double = 8) {
        model.touch(TouchSample(id: id, phase: .moved, x: x, y: y, majorRadius: radius), at: now)
    }

    func touchUp(_ id: Int, x: Double, y: Double, radius: Double = 8) {
        model.touch(TouchSample(id: id, phase: .ended, x: x, y: y, majorRadius: radius), at: now)
    }

    /// A short tap.
    func tap(x: Double, y: Double) {
        let id = touchDown(x: x, y: y)
        _ = wait(0.05, until: { false })
        touchUp(id, x: x, y: y)
    }

    /// The middle of the control surface, where a thumb rests.
    var surfaceCentre: SIMD2<Double> {
        let surface = layout.controlSurface
        return SIMD2(surface.x + surface.width / 2, surface.y + surface.height / 2)
    }

    /// Scheme B: the half under a right thumb closes, the other half opens.
    func half(_ side: SurfaceLayout.Side) -> SIMD2<Double> {
        let surface = layout.controlSurface
        let x = side == .near ? surface.width * 0.75 : surface.width * 0.25
        return SIMD2(x, surface.y + surface.height / 2)
    }

    /// The middle of the bottom band (STOP) and of the top band away from the gear.
    var bottomBand: SIMD2<Double> { SIMD2(layout.width / 2, layout.bottomBand.y + layout.bottomBand.height / 2) }
    var topBand: SIMD2<Double> { SIMD2(layout.width / 2, layout.topBand.maxY - 20) }

    /// Slides touch `id` from `from` straight up by `millimetres`, 1 mm at a time over `seconds`.
    func slideUp(_ id: Int, from point: SIMD2<Double>, millimetres: Int, in seconds: Double) {
        for step in 1...millimetres {
            touchMove(id, x: point.x, y: point.y - Double(step) * layout.pointsPerMm)
            _ = wait(seconds / Double(millimetres), until: { false })
        }
    }

    /// Turns the phone from upright to `degrees` on one axis in `seconds`: `turn` is the steering-wheel motion
    /// (clockwise as the operator sees the screen), `tilt` tips the top edge away from the operator.
    func turnPhone(_ axis: WristAxis, to degrees: Float, in seconds: Double) {
        let from = rotation
        // Upright, the screen faces the operator along world +z and the phone's right edge is world +x.
        let worldAxis = axis == .turn ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(1, 0, 0)
        let to = simd_quatf(angle: -degrees * .pi / 180, axis: worldAxis)
        let started = Date()
        while true {
            let share = Float(min(Date().timeIntervalSince(started) / seconds, 1))
            rotation = simd_slerp(from, to, share)
            if share >= 1 { break }
            _ = wait(1.0 / 120, until: { false })
        }
    }

    /// Moves the hand to `target` (operator frame: right, up, back in metres) in `seconds`.
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

    // MARK: Moves an operator makes

    /// Moves the arm to a robot-base position, checking where the arm really is between holds, as an operator does
    /// by eye.
    @discardableResult
    func moveArm(to target: SIMD3<Float>, _ name: String, maxHolds: Int = 2) -> Bool {
        let started = Date()
        var holds = 0
        pump(0.6)
        while holds < maxHolds {
            guard let arm = model.link.armPosition else { return false }
            let remaining = target - arm
            if simd_length(remaining) < 0.004 { break }
            if mode == .buttons {
                guard holdButtons(for: remaining, name) else { return false }
            } else {
                guard holdUpperKey(for: remaining, name) else { return false }
            }
            pump(1.2)
            holds += 1
            if model.session.state.emergencyStop { break }
        }
        let arm = model.link.armPosition ?? target
        let off = simd_distance(arm, target)
        print(String(format: "PICK %@ (%@): %d holds, %.0f s, ended %.1f cm from target, estop %@",
                     name, mode.rawValue, holds, Date().timeIntervalSince(started), off * 100,
                     model.session.state.emergencyStop ? "YES" : "no"))
        return off < 0.008
    }

    /// One vol+ hold that moves the phone by the base-frame offset `remaining`.
    private func holdUpperKey(for remaining: SIMD3<Float>, _ name: String) -> Bool {
        // Operator frame: right is −X, forward is −Y, up is +Z. An upright phone: right +x, up +y, forward −z.
        let hand = SIMD3(-remaining.x, remaining.z, remaining.y)
        position = .zero
        pump(0.3)
        press(.upper)
        guard model.session.state.armMoving else {
            print("PICK \(name): hold did not start. log: \(model.debugLog.suffix(3))")
            release(.upper)
            return false
        }
        move(to: hand, in: max(Double(simd_length(remaining)) / 0.15, 0.4))
        pump(5)
        release(.upper)
        return true
    }

    /// One button hold per axis, as long as the ramp needs to cover that axis's share of `remaining`.
    private func holdButtons(for remaining: SIMD3<Float>, _ name: String) -> Bool {
        let parts: [(ButtonID, Float)] = [
            (remaining.x >= 0 ? .left : .right, abs(remaining.x)),
            (remaining.y >= 0 ? .back : .forward, abs(remaining.y)),
            (remaining.z >= 0 ? .up : .down, abs(remaining.z)),
        ]
        for (button, distance) in parts where distance >= 0.001 {
            let speed: ButtonSpeed = distance < 0.015 ? .fine : .coarse
            model.selectSpeed(speed)
            model.buttonDown(button)
            guard model.session.state.armMoving else {
                print("PICK \(name): \(button) did not start. log: \(model.debugLog.suffix(3))")
                model.buttonUp(button)
                return false
            }
            _ = wait(Double(distance) / speed.metresPerSecond, until: { false })
            model.buttonUp(button)
            pump(0.8)
        }
        return true
    }

    /// Opens or closes the jaws with the scheme's own gesture, held for `seconds` times `pace`.
    func gripper(_ target: GripperState, seconds: Double) {
        switch (mode, target) {
        case (.buttons, _):
            model.buttonDown(target == .open ? .open : .close)
            pump(seconds)
            model.buttonUp(target == .open ? .open : .close)
        case (.screenTurns, .closed):
            press(.lower)
            pump(seconds)
            release(.lower)
        case (.screenTurns, .open):
            let point = surfaceCentre
            let id = touchDown(x: point.x, y: point.y)
            _ = wait(0.15, until: { false })
            slideUp(id, from: point, millimetres: 12, in: 0.25)
            pump(seconds)
            touchUp(id, x: point.x, y: point.y - 12 * layout.pointsPerMm)
        case (.keyTurns, _):
            let point = half(target == .closed ? .near : .far)
            let id = touchDown(x: point.x, y: point.y)
            pump(seconds)
            touchUp(id, x: point.x, y: point.y)
        }
        pump(1.0)
    }

    /// Turns or tilts the wrist by rotating the phone `degrees` with the scheme's wrist input held, a thumb on the
    /// glass (A) or vol− (B), and holds for `seconds` times `pace` so the wrist arrives.
    func wrist(_ axis: WristAxis, by degrees: Float, hold seconds: Double) {
        rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        pump(0.2)
        let point = surfaceCentre
        var touch: Int?
        if mode == .keyTurns {
            press(.lower)
        } else {
            touch = touchDown(x: point.x, y: point.y)
            _ = wait(0.15, until: { false })
        }
        turnPhone(axis, to: degrees, in: Double(abs(degrees)) / 40)
        pump(seconds)
        if let touch { touchUp(touch, x: point.x, y: point.y) } else { release(.lower) }
        pump(0.5)
        // Back to upright with nothing held, as a hand does between holds.
        rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    }

    /// The whole task with the scheme's own inputs: open, go to the grasp point the guide shows, close, lift, carry,
    /// lower, open.
    func pickAndPlace(warmUpHolds: Int) throws {
        let started = Date()
        let profile = model.profile
        guard let objectStart = model.link.objectPosition, let goal = model.link.goalPosition,
              let armStart = model.link.armPosition else {
            throw XCTSkip("the server did not report the task object, goal and arm positions")
        }
        let lift = SIMD3<Float>(0, 0, 0.03)

        gripper(.open, seconds: 5)
        for hold in 0..<warmUpHolds {
            let up: Float = hold % 2 == 0 ? 0.03 : 0.015
            moveArm(to: armStart + SIMD3(0, 0, up), "warm-up hold \(hold + 1)", maxHolds: 1)
        }
        // Where the reported gripper point has to be for the guide's ring to sit on the object.
        let object = model.link.objectPosition ?? objectStart
        let grasp = profile.inBase(world: object) - profile.toolOffset
        moveArm(to: grasp + lift, "above the grasp point")
        guard moveArm(to: grasp, "grasp point", maxHolds: 3) else {
            XCTFail("\(mode): the arm could not reach the grasp point")
            return
        }
        gripper(.closed, seconds: 15)
        XCTAssertTrue(model.gripping, "\(mode): the jaws did not close on the object")
        moveArm(to: grasp + lift, "lift 3 cm", maxHolds: 2)
        pump(1.0)
        let lifted = (model.link.objectPosition ?? object).z - object.z
        guard lifted > 0.015 else {
            XCTFail("\(mode): the object was not lifted (rose \(lifted * 100) cm)")
            return
        }
        var overGoal = grasp + SIMD3(goal.x - object.x, goal.y - object.y, 0)
        moveArm(to: overGoal + lift, "to the goal")
        if let carried = model.link.objectPosition {
            let miss = SIMD3(goal.x - carried.x, goal.y - carried.y, 0)
            if simd_length(miss) > 0.005, carried.z - object.z > 0.015 {
                overGoal += miss
                moveArm(to: overGoal + lift, "object over the goal", maxHolds: 1)
            }
        }
        moveArm(to: overGoal + SIMD3(0, 0, 0.002), "down onto the goal", maxHolds: 2)
        gripper(.open, seconds: 5)
        // A success shows for a moment and refuses every press meanwhile ("Wait."), so lift away only without one.
        if model.serverState?.taskSuccess != true { moveArm(to: overGoal + lift, "lift away", maxHolds: 1) }
        pump(4)
        let objectEnd = model.link.objectPosition ?? objectStart
        let inGoal = abs(objectEnd.x - goal.x) <= 0.025 && abs(objectEnd.y - goal.y) <= 0.025
        // A success resets the scene at once, which also puts the object back at its start.
        let resetBySuccess = simd_distance(objectEnd, objectStart) < 0.005
        print(String(format: "PICK RESULT (%@): in goal %@, scene reset after success %@, %.0f s in all",
                     mode.rawValue, inGoal ? "YES" : "no", resetBySuccess ? "YES" : "no", Date().timeIntervalSince(started)))
        XCTAssertFalse(model.session.state.emergencyStop)
        XCTAssertTrue(inGoal || resetBySuccess, "\(mode): the object did not end in the goal")
    }

    /// Lets go of everything, closes the link and puts back the saved mode.
    func finish() {
        release(.upper)
        release(.lower)
        pump(1)
        model.link.closeQuietly()
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
    }
}
