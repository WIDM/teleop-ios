import simd
import TeleopCore
import XCTest
@testable import Teleop

/// A socket that keeps what the app sends and lets the test speak for the server.
private final class HeardTestTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []

    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    var types: [String] { sent.map { $0["type"] as! String } }

    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

/// A follow nobody holds never ends in silence, and never ends twice. One row per way it can end, each run for a
/// follow latched by a press of the upper key and for one latched by a thumb slid up while the key is held, through
/// the model with a scripted server and the test's clocks. Each row asserts that the follow ended, the session's hold
/// and the link's hold with it, and that exactly one ending cue was heard, from a row of the cue table that cannot be
/// dropped (it speaks at the first or second level, or plays a sound).
final class LooseEndingHeardTests: XCTestCase {
    /// How the follow was latched.
    enum Start: CaseIterable { case pressPress, holdThenSlide }

    /// One way a follow ends: what it needs before the latch, the robot it runs on, and what causes it.
    struct Row {
        var name: String
        var profile: RobotProfile = .so101Simulator
        var before: (LooseEndingHeardTests) -> Void = { _ in }
        var cause: (LooseEndingHeardTests) -> Void
    }

    private var transport: HeardTestTransport!
    private var observer: HeardTestTransport?
    private var position: SIMD3<Float>? = .zero
    private var tilted = false
    private var clock = 10_000
    private var model: AppModel!
    private var nextTouch = 1
    private var savedLanguage = L10n.language
    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    /// The aids are chosen through the model's initializer, which saves nothing; both keys are removed all the same,
    /// never put back to a value read before: a launch argument shadows the saved value, so a value read here and
    /// written back could be the argument's, saved for good.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        L10n.language = savedLanguage
        model = nil
        transport = nil
        observer = nil
        super.tearDown()
    }

    /// The table, kept beside the assertion, so a new ending is one more row.
    static var rows: [Row] {
        [
            Row(name: "too fast") { test in
                test.run(ticks: 10)
                test.position = SIMD3(0.2, 0, 0)
                test.tick()
            },
            Row(name: "tracking lost, seen by the link") { test in
                test.position = nil
                test.tick()
            },
            Row(name: "tracking lost, seen by the input rules") { test in
                test.position = nil
                test.clock += 100
                test.model.controller.tick()
            },
            Row(name: "a re-sent start the server never finished") { test in
                test.sweepRight()
                test.run(ticks: 100)
            },
            Row(name: "the watchdog after GO") { test in
                test.run(ticks: 10)
                test.serverAnswers("rejected", "pose_watchdog_timeout")
            },
            Row(name: "a late rejection after GO") { test in
                test.run(ticks: 10)
                test.serverAnswers("rejected", "ik_failed")
            },
            Row(name: "busy before GO") { $0.serverAnswers("rejected", "busy") },
            Row(name: "not ready before GO") { $0.serverAnswers("rejected", "sim_not_ready") },
            Row(name: "a validation code before GO") { $0.serverAnswers("rejected", "invalid_rate") },
            Row(name: "a stopped robot before GO, then its stop state") { test in
                test.serverAnswers("rejected", "estop_active")
                test.transport.server("state", ["estop": true, "gripper": "closed"])
            },
            // The refusal can come after the hold was taken as accepted (a link with jitter): the alarm alone tells it.
            Row(name: "a stopped robot after GO, then its stop state") { test in
                test.run(ticks: 10)
                XCTAssertEqual(test.model.cueLog.last?.event, .holdLive, "\(test.model.lockChoice): accepted")
                let accepted = test.model.cueLog.count
                test.serverAnswers("rejected", "estop_active")
                test.transport.server("state", ["estop": true, "gripper": "closed"])
                XCTAssertEqual(
                    test.model.cueLog.dropFirst(accepted).map(\.event), [.emergencyStop(.other, takeDiscarded: false)],
                    "\(test.model.lockChoice): the alarm and nothing else")
            },
            Row(name: "an emergency-stop reason, then the stop state") { test in
                test.run(ticks: 10)
                test.serverAnswers("rejected", "estop")
                test.transport.server("state", ["estop": true, "gripper": "closed"])
            },
            Row(name: "a stop state") { $0.transport.server("state", ["estop": true, "gripper": "closed"]) },
            Row(name: "a success, its state on the control connection") { test in
                test.run(ticks: 10)
                test.serverAnswers("ok", TeleopLink.successReason)
                test.transport.server("state", ["estop": false, "gripper": "open", "task_success": true])
            },
            Row(name: "a success, its state on the listening connection") { test in
                test.bringUpObserver()
                test.run(ticks: 10)
                test.serverAnswers("ok", TeleopLink.successReason)
                test.observer?.server("state", ["estop": false, "gripper": "open", "task_success": true])
            },
            Row(name: "a success whose state comes before the final answer") { test in
                test.bringUpObserver()
                test.run(ticks: 10)
                test.observer?.server("state", ["estop": false, "gripper": "open", "task_success": true])
                // The server shows the success and ends the hold itself: the input rules end nothing meanwhile.
                test.clock += 100
                test.model.controller.tick()
                XCTAssertTrue(test.model.session.state.armMoving, "still following while the success shows")
                XCTAssertNotNil(test.model.controller.arbiter.engagement)
                test.serverAnswers("ok", TeleopLink.successReason)
            },
            Row(name: "the link lost") { $0.transport.onClose?() },
            Row(name: "STOP") { $0.touch(at: $0.bottomBand) },
            Row(name: "a slow link") { test in
                test.model.send(.linkLatency(ms: 500))
                test.model.send(.linkLatency(ms: 500))
            },
            Row(name: "the app left") { $0.model.activeChanged(false) },
            Row(name: "the camera stopped") { $0.model.controller.cameraInterrupted(true) },
            Row(name: "the operating screen left") { $0.model.send(.openSettings) },
            Row(name: "the phone held sideways") { test in
                test.tilted = true
                test.clock += 100
                test.model.controller.tick()
            },
            Row(name: "the lock's time limit", profile: oneSecondLock) { test in
                test.clock += 1100
                test.model.controller.tick()
            },
            Row(name: "a key") { test in
                test.clock += 100
                test.model.keyEvent(.lower, down: true)
            },
            Row(name: "a touch on the control surface") { $0.touch(at: $0.surfaceCentre) },
            Row(name: "a touch on the top band") { $0.touch(at: $0.topBand) },
            Row(name: "a touch on the gear") { $0.touch(at: $0.gear) },
            // The start waits behind the jaws' stop, so the link's feedback has nothing engaged when tracking is lost:
            // the link ends the hold and records nothing it told.
            Row(name: "a link path that tells nothing", before: { $0.closeAndReleaseTheJaws() }) { test in
                test.position = nil
                test.tick()
            },
        ]
    }

    func testEveryEndingIsHeardExactlyOnce() {
        for row in Self.rows {
            for start in Start.allCases {
                let what = "\(row.name), \(start)"
                bringUp(profile: row.profile, start: start)
                row.before(self)
                latch(start, what)
                let before = model.cueLog.count
                row.cause(self)
                XCTAssertNil(model.controller.arbiter.engagement, what)
                XCTAssertFalse(model.session.state.armMoving, what)
                XCTAssertFalse(model.link.holdIsLoose, what)
                let sent = transport.sent.count
                tick()
                XCTAssertFalse(
                    transport.types.dropFirst(sent).contains("pose_update"), "\(what): the link still streams")
                let endings = model.cueLog.dropFirst(before).filter { Self.isEndingCue($0.event) }
                XCTAssertEqual(endings.count, 1, "\(what): \(model.cueLog.dropFirst(before).map(\.event))")
                XCTAssertTrue(endings.allSatisfy(Self.cannotBeDropped), "\(what): \(endings.map(\.event))")
            }
        }
    }

    /// A move's endings, the alarm, link loss during a hold, and a success's narration.
    static func isEndingCue(_ key: CueKey) -> Bool {
        switch key {
        case .drive(.stoppedByYou), .drive(.arrived), .drive(.ended): return true
        case .emergencyStop, .linkLost(holdEngaged: true), .taskSuccess, .takeSaved, .successNotSaved: return true
        default: return false
        }
    }

    /// The row speaks at the first or second level, which waits and is never dropped, or plays a sound.
    static func cannotBeDropped(_ entry: CueLogEntry) -> Bool {
        let row = CueTable.row(for: entry.event)
        return row.sound != nil || (row.level.map { $0 <= .p2 } ?? false)
    }

    /// The simulator's robot with a lock limit short enough to reach in a test.
    static var oneSecondLock: RobotProfile {
        var profile = RobotProfile.so101Simulator
        profile.assist.lock = LockLimits(timeLimitS: 1)
        return profile
    }

    // MARK: The app, the server and the hand

    /// Standby on the real server in scheme A with the link up, the reference phone's layout, and lock chosen for
    /// `start`, given to the model without saving it.
    private func bringUp(profile: RobotProfile, start: Start) {
        position = .zero
        tilted = false
        clock = 10_000
        observer = nil
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { [unowned self] in
                guard let position else { return nil }
                guard !tilted else { return TestPose.portrait(turned: 60, about: SIMD3(0, 0, 1)) }
                return TestPose.portrait(at: position)
            },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = HeardTestTransport()
                transport = made
                return made
            },
            makeObserverTransport: { [unowned self] _ in
                let made = HeardTestTransport()
                observer = made
                return made
            },
            nowMs: { [unowned self] in clock },
            inputClock: { [unowned self] in Double(clock) / 1000 },
            clientName: "teleop-ios/1.0.0 (7)", profile: profile,
            assistOn: true, lockChoice: start == .pressPress ? .pressPress : .holdThenSlide
        )
        model.controlMode = .screenTurns
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.session.state.setSmoothing(0)
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "closed"])
    }

    /// Latches the follow the way `start` does and checks it latched, with its cue heard once.
    private func latch(_ start: Start, _ what: String) {
        let heardBefore = model.cueLog.count
        switch start {
        case .pressPress:
            clock += 100
            model.keyEvent(.upper, down: true)
            clock += 100
            model.keyEvent(.upper, down: false)
        case .holdThenSlide:
            clock += 50
            model.keyEvent(.upper, down: true)
            clock += 50
            let point = surfaceCentre
            let id = touchDown(at: point)
            // Past the palm window, then 12 mm up the glass, 1 mm every 5 ms.
            clock += 110
            for step in 1...12 {
                clock += 5
                touchSample(id, .moved, at: SIMD2(point.x, point.y - Double(step) * layout.pointsPerMm))
            }
            touchSample(id, .ended, at: SIMD2(point.x, point.y - 12 * layout.pointsPerMm))
            clock += 20
            model.keyEvent(.upper, down: false)
        }
        guard case .latched? = model.controller.arbiter.engagement else {
            return XCTFail("\(what): not latched: \(String(describing: model.controller.arbiter.engagement))")
        }
        XCTAssertTrue(model.session.state.armMoving, what)
        XCTAssertTrue(model.link.holdIsLoose, what)
        XCTAssertEqual(model.cueLog.dropFirst(heardBefore).map(\.event), [.drive(.latched)], what)
    }

    private var layout: SurfaceLayout { model.controller.arbiter.layout }

    var surfaceCentre: SIMD2<Double> {
        let surface = layout.controlSurface
        return SIMD2(surface.x + surface.width / 2, surface.y + surface.height / 2)
    }

    var topBand: SIMD2<Double> { SIMD2(layout.width / 2, layout.topBand.maxY - 20) }
    var gear: SIMD2<Double> { SIMD2(layout.gear.x + layout.gear.width / 2, layout.gear.y + layout.gear.height / 2) }
    var bottomBand: SIMD2<Double> { SIMD2(layout.width / 2, layout.bottomBand.y + layout.bottomBand.height / 2) }

    private func touchDown(at point: SIMD2<Double>) -> Int {
        let id = nextTouch
        nextTouch += 1
        touchSample(id, .began, at: point)
        return id
    }

    private func touchSample(_ id: Int, _ phase: TouchSample.Phase, at point: SIMD2<Double>) {
        model.touch(TouchSample(id: id, phase: phase, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
    }

    /// A thumb comes down at `point`, 100 ms after the last input.
    func touch(at point: SIMD2<Double>) {
        clock += 100
        _ = touchDown(at: point)
    }

    /// One pose tick, 33 ms later.
    func tick() {
        clock += 33
        model.link.tick()
    }

    /// Many ticks with a server that answers every probe, as a live one does.
    func run(ticks: Int) {
        var answered = transport.sent.count
        for _ in 0..<ticks {
            tick()
            for message in transport.sent.dropFirst(answered) where message["type"] as? String == "test" {
                transport.server("test", seq: message["seq"] as! Int)
            }
            answered = transport.sent.count
        }
    }

    /// The server's final answer for the newest translation hold.
    func serverAnswers(_ status: String, _ reason: String) {
        let start = transport.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        transport.server("ack", seq: start, ["seq": start, "status": status, "reason": reason])
    }

    /// The listening connection's welcome and first state.
    func bringUpObserver() {
        observer?.server("welcome", ["session": "run-1"])
        observer?.server("state", ["estop": false, "gripper": "closed"])
        XCTAssertTrue(model.link.observerUp)
    }

    /// The arm reported at the origin, then the hand 20 cm to the right in a third of a second: more than one server
    /// hold may ask for, so the link catches up and re-sends the start after 1.5 s.
    func sweepRight() {
        transport.server("state", ["estop": false, "gripper": "closed", "ee_pos": [0.0, 0.0, 0.1]])
        for step in 1...10 {
            position = SIMD3(0.02 * Float(step), 0, 0)
            tick()
        }
    }

    /// The jaws close and are let go of just before the latch: the follow's start waits on the wire for the server to
    /// finish the jaws' hold.
    func closeAndReleaseTheJaws() {
        model.send(.gripperStart(.closed))
        clock += 20
        model.send(.gripperEnd)
    }
}
