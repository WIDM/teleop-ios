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

    // What the server said during the run, from every `state` on either connection and every final answer: the only
    // evidence a run passes on.
    /// A `state` said `task_success` after the jaws let go on the goal. The server latches a success only with the
    /// jaws open, so one from before that is left over from an earlier run.
    private(set) var successSeen = false
    private var countingSuccess = false
    /// The newest `episode` a `state` named; nil on a server that does not count episodes. Printed, never taken as a
    /// success: the server also starts a new episode when the object falls off the table or on a manual reset.
    private(set) var newestEpisode: Int?
    /// Holds the server ended while they were held: by its watchdog, or by a late refusal.
    private(set) var holdsEndedByServer = 0
    /// The step the hand was on when a working link went down; nil while it is up.
    private(set) var linkLostDuring: String?
    /// When the newest `state` arrived.
    private var lastStateAt: Date?
    /// What the hand is doing now, named in the failure if the run cannot go on.
    var step = "connecting"
    /// The step at which the run could not go on; nil while it can.
    private var haltedDuring: String?

    /// - Parameter makeTransport: both of the app's sockets; a real WebSocket when nil. A test passes one that stalls or
    ///   cuts the network path.
    init(
        address: String, mode: ControlMode = .screenTurns, smoothing: Double, pace: Double = 1,
        haptics: HapticsPlaying = NoHaptics(), makeTransport: ((URL) -> LinkTransport)? = nil
    ) {
        self.mode = mode
        self.pace = pace
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
        model = AppModel(
            start: .s1, haptics: haptics, pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: makeTransport ?? { WebSocketTransport(url: $0) })
        model.session.state.serverAddress = address
        model.session.state.setSmoothing(smoothing)
        model.controlMode = mode
        model.surfaceChanged(width: layout.width, height: layout.height, safeTop: 62, safeBottom: 34)
        // The hand listens beside the app, which still gets everything.
        let onState = model.link.onState
        model.link.onState = { [unowned self] state in
            lastStateAt = Date()
            if countingSuccess, state.taskSuccess == true || state.activity == .taskSuccess { successSeen = true }
            if let episode = state.episode { newestEpisode = episode }
            onState?(state)
        }
        let onFeedback = model.link.onFeedback
        model.link.onFeedback = { [unowned self] event in
            if event == .letGo(.watchdog) || event == .letGo(.lateRejection) { holdsEndedByServer += 1 }
            onFeedback?(event)
        }
        let onAction = model.link.onAction
        model.link.onAction = { [unowned self] action in
            if action == .linkLost, model.session.state.connected, linkLostDuring == nil { linkLostDuring = step }
            onAction?(action)
        }
    }

    /// False when a working link went down during the run. The first time, it fails the test loudly, naming the step
    /// and showing the app's own last log lines: nothing the app knows about the server after that is news, so no step
    /// may go on as if it were.
    func linkIsUp() -> Bool {
        guard let during = linkLostDuring else { return true }
        halt("the link went down", during: during)
        return false
    }

    /// False once the run cannot go on: the link went down, an emergency stop latched (on the phone, or in a `state`
    /// from either connection before the control one brings it), or the server's states stopped (`freshState`). Each
    /// fails the test once, loudly, at the step where it happened.
    private func going() -> Bool {
        guard linkIsUp(), haltedDuring == nil else { return false }
        guard !model.session.state.emergencyStop, model.serverState?.estop != true else {
            halt("an emergency stop latched", during: step)
            return false
        }
        return true
    }

    /// Waits for a `state` less than 1 s old, or one that arrived after `since`; the server sends one after every
    /// 200 ms of silence on either connection. False, after failing the run, when none comes while the link stays up:
    /// steering from an old arm position, or judging the run on an old object position, would be a guess. The wait
    /// outlasts the link's 3 s limit, so a stall of the path ends in a fresh state or a lost link.
    private func freshState(arrivedAfter since: Date? = nil) -> Bool {
        guard going() else { return false }
        let after = since ?? Date().addingTimeInterval(-1)
        let fresh = wait(5) { linkLostDuring != nil || lastStateAt.map { $0 > after } == true }
        guard going() else { return false }
        if !fresh { halt("the server's states stopped while the link stayed up", during: step) }
        return fresh
    }

    private func halt(_ what: String, during: String) {
        guard haltedDuring == nil else { return }
        haltedDuring = during
        let log = model.debugLog.suffix(12).joined(separator: "\n")
        print("PICK HALTED (\(mode.rawValue)): \(what) during \(during). The app's log:\n\(log)")
        XCTFail("\(mode): \(what) during \(during). The app's last log lines:\n\(log)")
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
        let up =
            wait(seconds, until: { model.session.state.connected || model.session.state.serverInputError })
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
        step = name
        let started = Date()
        var holds = 0
        pump(0.6)
        while holds < maxHolds {
            guard let arm = reportedArm(name) else { return false }
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
        guard let arm = reportedArm(name) else { return false }
        let off = simd_distance(arm, target)
        print(
            String(
                format: "PICK %@ (%@): %d holds, %.0f s, ended %.1f cm from target, estop %@",
                name, mode.rawValue, holds, Date().timeIntervalSince(started), off * 100,
                model.session.state.emergencyStop ? "YES" : "no"))
        return off < 0.008
    }

    /// Where the server reports the arm now, in the newest `state` from either connection (the one `freshState` waited
    /// for); nil, and said why, when it cannot be known.
    private func reportedArm(_ name: String) -> SIMD3<Float>? {
        guard freshState() else { return nil }
        guard let arm = model.serverState?.endEffector else {
            print("PICK \(name): the server's newest state has no arm position. log: \(model.debugLog.suffix(3))")
            return nil
        }
        return SIMD3(Float(arm.x), Float(arm.y), Float(arm.z))
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
        step = target == .open ? "open the jaws" : "close the jaws"
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
    ///
    /// It passes only on what the server reported after the jaws let go on the goal: a `state` that said
    /// `task_success`, or a `state` arriving after the last wait with the object resting inside the goal and the jaws
    /// reported open. A new episode alone is no success. A lost link, an emergency stop or states that stopped coming fail the run at that
    /// step, as do the grasp point not reached, the jaws not closing on the object and the object not lifted or not
    /// carried. Every run prints one `PICK RUN` line to check against the server's own log.
    func pickAndPlace(warmUpHolds: Int) throws {
        let started = Date()
        let profile = model.profile
        // Only what the server says during this run counts.
        successSeen = false
        countingSuccess = false
        holdsEndedByServer = 0
        let episodeBefore = newestEpisode
        var inGoal = false
        var verdict = "FAIL"
        defer {
            print(
                String(
                    format:
                        "PICK RUN (%@): episode %@ -> %@, success seen %@, holds ended by the server %d, link lost %@, "
                        + "object in goal %@, %.0f s: %@",
                    mode.rawValue, Self.text(episodeBefore), Self.text(newestEpisode), successSeen ? "YES" : "no",
                    holdsEndedByServer, linkLostDuring.map { "YES, during \($0)" } ?? "no", inGoal ? "YES" : "no",
                    Date().timeIntervalSince(started), verdict))
        }
        guard going() else { return }
        guard let objectStart = model.link.objectPosition, let goal = model.link.goalPosition,
            let armStart = model.link.armPosition
        else {
            verdict = "SKIP"
            throw XCTSkip("the server did not report the task object, goal and arm positions")
        }
        let lift = SIMD3<Float>(0, 0, 0.03)

        gripper(.open, seconds: 5)
        guard going() else { return }
        for hold in 0..<warmUpHolds {
            let up: Float = hold % 2 == 0 ? 0.03 : 0.015
            moveArm(to: armStart + SIMD3(0, 0, up), "warm-up hold \(hold + 1)", maxHolds: 1)
            guard going() else { return }
        }
        // Where the reported gripper point has to be for the guide's ring to sit on the object.
        guard let object = reportedObject("before the grasp") else { return }
        let grasp = profile.inBase(world: object) - profile.toolOffset
        moveArm(to: grasp + lift, "above the grasp point")
        guard going() else { return }
        guard moveArm(to: grasp, "grasp point", maxHolds: 3) else {
            if going() { XCTFail("\(mode): the arm could not reach the grasp point") }
            return
        }
        gripper(.closed, seconds: 15)
        guard going() else { return }
        guard model.gripping else {
            XCTFail("\(mode): the jaws did not close on the object")
            return
        }
        moveArm(to: grasp + lift, "lift 3 cm", maxHolds: 2)
        pump(1.0)
        guard let raised = reportedObject("after the lift") else { return }
        let lifted = raised.z - object.z
        guard lifted > 0.015 else {
            XCTFail("\(mode): the object was not lifted (rose \(lifted * 100) cm)")
            return
        }
        var overGoal = grasp + SIMD3(goal.x - object.x, goal.y - object.y, 0)
        moveArm(to: overGoal + lift, "to the goal")
        guard let carried = reportedObject("after the carry") else { return }
        guard carried.z - object.z > 0.015 else {
            XCTFail("\(mode): the object left the jaws on the way to the goal (\((carried.z - object.z) * 100) cm up)")
            return
        }
        let miss = SIMD3(goal.x - carried.x, goal.y - carried.y, 0)
        if simd_length(miss) > 0.005 {
            overGoal += miss
            moveArm(to: overGoal + lift, "object over the goal", maxHolds: 1)
            guard going() else { return }
        }
        moveArm(to: overGoal + SIMD3(0, 0, 0.002), "down onto the goal", maxHolds: 2)
        guard going() else { return }
        countingSuccess = true
        gripper(.open, seconds: 5)
        guard going() else { return }
        // A success shows for a moment and refuses every press meanwhile ("Wait."), so lift away only without one.
        if !successSeen {
            moveArm(to: overGoal + lift, "lift away", maxHolds: 1)
            guard going() else { return }
        }
        step = "waiting for the server after the release"
        pump(4)
        // Judged on a state that arrives after the wait, not on whatever state the app kept last: a link that went down
        // in the wait gives none, and is caught.
        guard freshState(arrivedAfter: Date()), let end = model.serverState else { return }
        if let at = end.object {
            inGoal =
                end.gripper == .open
                && Self.restsInGoal(
                    SIMD3(Float(at.x), Float(at.y), Float(at.z)), goal: goal, restingHeight: objectStart.z,
                    halfWidth: profile.goalSize / 2)
        }
        guard inGoal || successSeen else {
            XCTFail("\(mode): the server reported neither the object in the goal nor a success")
            return
        }
        verdict = "PASS"
    }

    /// Where the server reports the task object now, in the newest `state` from either connection; nil, after failing
    /// the run, when that cannot be known.
    private func reportedObject(_ when: String) -> SIMD3<Float>? {
        guard freshState() else { return nil }
        guard let object = model.serverState?.object else {
            XCTFail("\(mode): the server's newest state has no object position \(when)")
            return nil
        }
        return SIMD3(Float(object.x), Float(object.y), Float(object.z))
    }

    /// The object rests inside the goal: across, within the goal's half width of its centre (world frame, as the server
    /// reports both); in height, within the 1.5 cm the script takes for lifted of where it rested at the start, so an
    /// object still held over the goal, or one that fell below the table, is not in it.
    static func restsInGoal(
        _ object: SIMD3<Float>, goal: SIMD3<Float>, restingHeight: Float, halfWidth: Float
    ) -> Bool {
        abs(object.x - goal.x) <= halfWidth && abs(object.y - goal.y) <= halfWidth
            && abs(object.z - restingHeight) < 0.015
    }

    private static func text(_ episode: Int?) -> String { episode.map(String.init) ?? "not counted" }

    /// Lets go of everything, closes the link and puts back the saved mode.
    func finish() {
        release(.upper)
        release(.lower)
        pump(1)
        model.link.closeQuietly()
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
    }
}
