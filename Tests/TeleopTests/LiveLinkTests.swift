import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class FakeTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var opened = false
    var closed = false

    func open() { opened = true }
    func close() { closed = true }
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    var types: [String] { sent.map { $0["type"] as! String } }

    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

final class LiveLinkTests: XCTestCase {
    private var transport: FakeTransport!
    private var transports: [FakeTransport] = []
    /// Listening connections, newest last. `transport` stays the control connection.
    private var observers: [FakeTransport] = []
    private var position: SIMD3<Float>? = .zero
    private var clock = 10_000
    private var model: AppModel!
    private var savedLanguage = L10n.language
    private var felt = SpyHaptics()
    private var speech = SpySpeech()
    private var sounds = SpySounds()

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    private func makeModel(at route: Route) {
        transports = []
        observers = []
        position = .zero
        clock = 10_000
        felt = SpyHaptics()
        speech = SpySpeech()
        sounds = SpySounds()
        model = AppModel(
            start: route,
            haptics: felt,
            sounds: sounds,
            speech: speech,
            pose: { [unowned self] in
                position.map { p in
                    return TestPose.portrait(at: p)
                }
            },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = FakeTransport()
                transports.append(made)
                transport = made
                return made
            },
            makeObserverTransport: { [unowned self] _ in
                let made = FakeTransport()
                observers.append(made)
                return made
            },
            nowMs: { [unowned self] in clock },
            clientName: "teleop-ios/1.0.0 (7)"
        )
        model.session.state.serverAddress = "100.64.0.1:8765"
        // Exact offsets in these tests; smoothing has its own test.
        model.session.state.setSmoothing(0)
    }

    /// Standby with the link up and tracking. What was said on connecting is forgotten.
    private func bringUp(estop: Bool = false) {
        makeModel(at: .p4)
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": estop, "gripper": "closed"])
        speech.spoken = []
    }

    /// The server's final ack for a control it has finished; it names the control's start seq.
    private func serverFinished(_ startSeq: Int) {
        transport.server("ack", seq: startSeq, ["seq": startSeq, "status": "ok", "reason": "stopped"])
    }

    private func lastSeq(of type: String) -> Int {
        transport.sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    /// One pose tick, 33 ms later.
    private func tick() {
        clock += 33
        model.link.tick()
    }

    /// Many ticks with a server that answers every probe, as a live one does.
    private func run(ticks: Int) {
        var answered = transport.sent.count
        for _ in 0..<ticks {
            tick()
            for message in transport.sent.dropFirst(answered) where message["type"] as? String == "test" {
                transport.server("test", seq: message["seq"] as! Int)
            }
            answered = transport.sent.count
        }
    }

    func testBadAddressShowsTheErrorAndOpensNothing() {
        makeModel(at: .s1)
        model.session.state.serverAddress = "100.64.0.1:8765 oops"
        model.connect()
        XCTAssertTrue(model.session.state.serverInputError)
        XCTAssertTrue(transports.isEmpty)
    }

    /// The saved address loads in practice too, so leaving practice connects to it. It used to load only when the
    /// launch was on the real server, and switching after a practice launch left the address empty.
    func testASavedAddressLoadsSoLeavingPracticeConnectsToIt() {
        let saved = UserDefaults.standard.string(forKey: AppModel.serverAddressKey)
        UserDefaults.standard.set("100.64.0.7:8765", forKey: AppModel.serverAddressKey)
        defer { UserDefaults.standard.set(saved, forKey: AppModel.serverAddressKey) }
        let live = AppModel(start: .s1, haptics: NoHaptics(), pose: { nil }, liveLink: true, makeTransport: { _ in FakeTransport() })
        XCTAssertEqual(live.session.state.serverAddress, "100.64.0.7:8765")
        var opened: [URL] = []
        let practice = AppModel(
            start: .p4, haptics: NoHaptics(), pose: { nil }, liveLink: false,
            makeTransport: { opened.append($0); return FakeTransport() }
        )
        XCTAssertEqual(practice.session.state.serverAddress, "100.64.0.7:8765")
        XCTAssertTrue(practice.operating.practice)
        practice.leavePractice()
        XCTAssertFalse(practice.operating.practice)
        XCTAssertEqual(opened.map(\.absoluteString), ["ws://100.64.0.7:8765"])
    }

    func testAddressForms() {
        XCTAssertEqual(LiveLinkController.url(from: "100.64.0.1")?.absoluteString, "ws://100.64.0.1:8765")
        XCTAssertEqual(LiveLinkController.url(from: " mac.local:9000 ")?.absoluteString, "ws://mac.local:9000")
        XCTAssertEqual(LiveLinkController.url(from: "wss://host:1")?.absoluteString, "wss://host:1")
        XCTAssertNil(LiveLinkController.url(from: ""))
        XCTAssertNil(LiveLinkController.url(from: "http://host"))
    }

    /// The app names itself to the server by its version and build, read from the bundle: never a person's name.
    func testTheAppsNameComesFromTheBundle() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = try! XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try! XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertEqual(LiveLinkController.clientName(), "teleop-ios/\(version) (\(build))")
        XCTAssertNotNil(LiveLinkController.clientName().range(of: #"^teleop-ios/\d+(\.\d+)+ \(\d+\)$"#, options: .regularExpression))
    }

    func testConnectSaysHelloAndWaitsForTheServer() {
        makeModel(at: .s1)
        model.connect()
        XCTAssertTrue(transport.opened)
        XCTAssertEqual(transport.types, ["hello"])
        XCTAssertFalse(model.session.state.connected)
        XCTAssertEqual(model.session.route, .s1)
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "closed"])
        XCTAssertTrue(model.session.state.connected)
        XCTAssertEqual(model.session.state.gripper, .closed)
        XCTAssertEqual(model.session.route, .p5)
    }

    func testNoWelcomeWithinTheTimeoutFails() {
        makeModel(at: .s1)
        model.connect()
        clock += 5001
        model.link.tick()
        XCTAssertTrue(transport.closed)
        XCTAssertTrue(model.session.state.serverInputError)
        XCTAssertFalse(model.session.state.connected)
    }

    func testHoldStreamsThePhoneOffsetAndStopsOnRelease() {
        bringUp()
        model.send(.holdArmStart)
        position = SIMD3(0.01, 0, -0.02)
        tick()
        model.send(.holdArmEnd)
        position = SIMD3(0.05, 0, 0)
        tick()
        XCTAssertEqual(transport.types, ["hello", "pose_start", "pose_update", "pose_stop"])
        let update = transport.sent[2]["payload"] as! [String: Any]
        // 1 cm right and 2 cm forward (ARKit forward is −z), as the server wants them.
        XCTAssertEqual(update["p_rel_m"] as? [Double], [-0.01, -0.02, 0])
    }

    func testOffsetIsMeasuredFromWhereTheHoldBegan() {
        bringUp()
        position = SIMD3(1, 2, 3)
        model.send(.holdArmStart)
        position = SIMD3(1, 2.01, 3)
        tick()
        let update = transport.sent.last!["payload"] as! [String: Any]
        XCTAssertEqual(update["p_rel_m"] as? [Double], [0, 0, -0.01])
    }

    func testHoldWithoutTrackingIsRefused() {
        bringUp()
        position = nil
        model.send(.holdArmStart)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertFalse(transport.types.contains("pose_start"))
    }

    func testLosingTrackingEndsTheHold() {
        bringUp()
        model.send(.holdArmStart)
        position = nil
        tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(transport.types.last, "pose_stop")
    }

    func testMovingThePhoneTooFastEndsTheHold() {
        bringUp()
        model.send(.holdArmStart)
        position = SIMD3(0.1, 0, 0)
        tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(transport.types.suffix(2), ["pose_start", "pose_stop"])
    }

    /// A tick a millisecond after the press, as a late timer gives on a slow phone: the hand's ordinary 1.1 mm step
    /// is not a jump. That tick sends nothing; the next one judges the speed over the longer time and sends.
    func testATickRightAfterThePressDoesNotMakeAnOrdinaryStepTooFast() throws {
        bringUp()
        model.send(.holdArmStart)
        position = SIMD3(0, 0, -0.0011)
        clock += 1
        model.link.tick()
        XCTAssertEqual(transport.types.last, "pose_start")
        position = SIMD3(0, 0, -0.0022)
        tick()
        XCTAssertTrue(model.session.state.armMoving, "the hold was ended as too fast")
        XCTAssertEqual(transport.types.suffix(2), ["pose_start", "pose_update"])
        let update = try XCTUnwrap(transport.sent.last?["payload"] as? [String: Any])
        let offset = try XCTUnwrap(update["p_rel_m"] as? [Double])
        XCTAssertEqual(offset[1], -0.0022, accuracy: 1e-6)
    }

    /// A real jump in a tick too soon to judge is never sent: the next tick ends the hold.
    func testAJumpRightAfterThePressEndsTheHoldOnTheNextTick() {
        bringUp()
        model.send(.holdArmStart)
        position = SIMD3(0.1, 0, 0)
        clock += 1
        model.link.tick()
        tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(transport.types.suffix(2), ["pose_start", "pose_stop"])
    }

    func testStopSendsEstopAndNothingMovesAfter() {
        bringUp()
        model.send(.holdArmStart)
        model.send(.stop)
        position = SIMD3(0.001, 0, 0)
        tick()
        XCTAssertEqual(transport.types.suffix(2), ["pose_start", "estop"])
        XCTAssertEqual(model.session.route, .s4)
    }

    func testReleaseSendsResetAndLateEstopStatesDoNotRelatch() {
        bringUp()
        model.send(.stop)
        model.send(.releaseStop)
        XCTAssertEqual(transport.types.suffix(2), ["estop", "estop_reset"])
        transport.server("state", ["estop": true])
        XCTAssertFalse(model.session.state.emergencyStop)
        transport.server("state", ["estop": false])
        transport.server("state", ["estop": true])
        XCTAssertTrue(model.session.state.emergencyStop)
    }

    func testServerEstopLatchesHereWithoutAnEcho() {
        bringUp()
        model.send(.holdArmStart)
        transport.server("state", ["estop": true])
        transport.server("state", ["estop": true])
        XCTAssertEqual(model.session.route, .s4)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertFalse(transport.types.contains("estop"))
    }

    func testServerEstopEndsOurHoldSoTheNextPressWorks() {
        bringUp()
        model.send(.holdArmStart)
        let hold = lastSeq(of: "pose_start")
        transport.server("state", ["estop": true])
        let sentAtEstop = transport.sent.count
        position = SIMD3(0.001, 0, 0)
        tick()
        XCTAssertFalse(transport.types.dropFirst(sentAtEstop).contains("pose_update"))
        model.send(.releaseStop)
        transport.server("state", ["estop": false])
        serverFinished(hold)
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2)
    }

    func testLongHoldOnAQuietServerIsNotALostLink() {
        bringUp()
        model.send(.holdArmStart)
        // Three seconds of holding. The server only echoes probes, as Leo's Bridge does during a hold.
        var answered = 0
        for _ in 0..<90 {
            tick()
            for message in transport.sent.dropFirst(answered) where message["type"] as? String == "test" {
                transport.server("test", seq: message["seq"] as! Int)
            }
            answered = transport.sent.count
        }
        XCTAssertGreaterThanOrEqual(transport.types.filter { $0 == "test" }.count, 5)
        XCTAssertTrue(model.session.state.connected)
        XCTAssertTrue(model.session.state.armMoving)
    }

    func testServerEndingTheHoldStopsHere() {
        bringUp()
        model.send(.holdArmStart)
        let start = transport.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        transport.server("ack", seq: start, ["seq": start, "status": "rejected", "reason": "pose_watchdog_timeout"])
        XCTAssertFalse(model.session.state.armMoving)
        position = SIMD3(0.001, 0, 0)
        tick()
        XCTAssertNotEqual(transport.types.last, "pose_update")
    }

    func testConnectingToAnEstoppedServerOpensS4() {
        bringUp(estop: true)
        XCTAssertTrue(model.session.state.connected)
        XCTAssertEqual(model.session.route, .s4)
    }

    func testSocketCloseDuringAHoldStopsAndReturnsToConnect() {
        bringUp()
        model.send(.holdArmStart)
        transport.onClose?()
        XCTAssertFalse(model.session.state.connected)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(model.session.route, .s1)
        XCTAssertTrue(model.session.state.connectionLost)
        XCTAssertFalse(model.link.isOpen)
    }

    func testSilentServerCountsAsLost() {
        bringUp()
        clock += TeleopLink.staleAfterMs + 1
        model.link.tick()
        XCTAssertFalse(model.session.state.connected)
        XCTAssertEqual(model.session.route, .s1)
        XCTAssertTrue(model.session.state.connectionLost)
    }

    func testGripperMovesWhileHeldAndStopsOnRelease() {
        bringUp()
        model.send(.gripperStart(.open))
        XCTAssertEqual(model.session.state.gripper, .open)
        XCTAssertEqual((transport.sent.last!["payload"] as! [String: String])["action"], "open")
        // Held for 5 s: keepalives every 133 ms, and it keeps going with no time limit.
        run(ticks: 150)
        let held = Array(transport.types.drop { $0 != "gripper_jog_start" })
        XCTAssertTrue(model.session.state.connected)
        XCTAssertGreaterThan(held.filter { $0 == "jog_keepalive" }.count, 30)
        XCTAssertFalse(held.contains("gripper_jog_stop"))
        model.send(.gripperEnd)
        XCTAssertEqual(transport.types.last, "gripper_jog_stop")
        let sentAtRelease = transport.sent.count
        run(ticks: 30)
        XCTAssertFalse(transport.types.dropFirst(sentAtRelease).contains("jog_keepalive"))
    }

    func testSwitchingDirectionStopsTheOldJogFirst() {
        bringUp()
        model.send(.gripperStart(.closed))
        let first = lastSeq(of: "gripper_jog_start")
        model.send(.gripperStart(.open))
        XCTAssertEqual(transport.types.suffix(2), ["gripper_jog_start", "gripper_jog_stop"])
        XCTAssertEqual(model.session.state.gripperMoving, .open)
        serverFinished(first)
        XCTAssertEqual(transport.types.suffix(3), ["gripper_jog_start", "gripper_jog_stop", "gripper_jog_start"])
        XCTAssertEqual((transport.sent.last!["payload"] as! [String: String])["action"], "open")
    }

    func testGoingFromTheOpenHandleToVolumeDownWaitsForTheServerAndKeepsHolding() {
        bringUp()
        model.send(.gripperStart(.open))
        let open = lastSeq(of: "gripper_jog_start")
        run(ticks: 10)
        model.send(.gripperStart(.closed))
        let sent = transport.sent.count
        run(ticks: 8)
        XCTAssertEqual(transport.types.dropFirst(sent).filter { $0 != "test" }, [], "no keepalive for a start the server has not seen")
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        serverFinished(open)
        XCTAssertEqual(transport.types.last, "gripper_jog_start")
        XCTAssertEqual((transport.sent.last!["payload"] as! [String: String])["action"], "close")
        run(ticks: 8)
        XCTAssertGreaterThan(transport.types.dropFirst(sent).filter { $0 == "jog_keepalive" }.count, 0)
    }

    func testHeldBackStartGoesOutAfterEightHundredMillisecondsWithoutTheAck() {
        bringUp()
        model.send(.wristStart)
        model.send(.wristEnd)
        model.send(.wristStart)
        XCTAssertTrue(model.session.state.wristMoving)
        XCTAssertEqual(transport.types.filter { $0 == "orient_start" }.count, 1)
        clock += TeleopLink.finishWaitMs - 100
        model.link.tick()
        XCTAssertEqual(transport.types.filter { $0 == "orient_start" }.count, 1)
        clock += 100
        model.link.tick()
        XCTAssertEqual(transport.types.filter { $0 == "orient_start" }.count, 2)
        XCTAssertEqual(transport.types.last, "orient_update")
    }

    func testReleasingBeforeTheServerFinishedSendsNothingMoreAndTheNextPressStillWorks() {
        bringUp()
        model.send(.wristStart)
        let first = lastSeq(of: "orient_start")
        model.send(.wristEnd)
        model.send(.wristStart)
        model.send(.wristEnd)
        XCTAssertEqual(transport.types.filter { $0 == "orient_start" }.count, 1)
        XCTAssertEqual(transport.types.filter { $0 == "orient_stop" }.count, 1)
        serverFinished(first)
        model.send(.wristStart)
        XCTAssertEqual(transport.types.suffix(2), ["orient_stop", "orient_start"])
    }

    func testServerRefusingTheGripperEndsTheHoldHere() {
        bringUp()
        model.send(.gripperStart(.closed))
        let start = transport.sent.last!["seq"] as! Int
        transport.server("ack", seq: start, ["seq": start, "status": "rejected", "reason": "busy"])
        XCTAssertNil(model.session.state.gripperMoving)
        let sentAfter = transport.sent.count
        run(ticks: 30)
        XCTAssertFalse(transport.types.dropFirst(sentAfter).contains("jog_keepalive"))
    }

    func testStopEndsTheGripperJog() {
        bringUp()
        model.send(.gripperStart(.closed))
        model.send(.stop)
        XCTAssertEqual(transport.types.last, "estop")
        let sentAfter = transport.sent.count
        run(ticks: 30)
        XCTAssertFalse(transport.types.dropFirst(sentAfter).contains("jog_keepalive"))
    }

    func testArmHoldDuringAGripperJogStopsItAndStarts() {
        bringUp()
        model.send(.gripperStart(.open))
        let jog = lastSeq(of: "gripper_jog_start")
        model.send(.holdArmStart)
        XCTAssertEqual(transport.types.suffix(2), ["gripper_jog_start", "gripper_jog_stop"])
        serverFinished(jog)
        XCTAssertEqual(transport.types.suffix(2), ["gripper_jog_stop", "pose_start"])
        run(ticks: 200)
        XCTAssertEqual(transport.types.filter { $0 == "gripper_jog_stop" }.count, 1)
        XCTAssertFalse(transport.types.contains("jog_keepalive"))
    }

    /// Roll in degrees of every orient_update sent after `index`, read back from the quaternion.
    private func rolls(after index: Int = 0) -> [Double] {
        transport.sent.dropFirst(index).filter { $0["type"] as? String == "orient_update" }.map {
            let q = ($0["payload"] as! [String: Any])["q_rel"] as! [Double]
            return -2 * asin(q[1]) * 180 / .pi
        }
    }

    private func lastOrientStartSeq() -> Int {
        transport.sent.last { $0["type"] as? String == "orient_start" }!["seq"] as! Int
    }

    func testServerRefusingTheWristHoldEndsItHere() {
        bringUp()
        model.send(.wristStart)
        let start = lastOrientStartSeq()
        transport.server("ack", seq: start, ["seq": start, "status": "rejected", "reason": "busy"])
        XCTAssertFalse(model.session.state.wristMoving)
        let sentAfter = transport.sent.count
        run(ticks: 30)
        XCTAssertTrue(rolls(after: sentAfter).isEmpty)
    }

    func testStaleRefusalOfAnEarlierWristHoldKeepsTheCurrentOne() {
        bringUp()
        model.send(.wristStart)
        let first = lastOrientStartSeq()
        model.send(.wristEnd)
        model.send(.wristStart)
        transport.server("ack", seq: first, ["seq": first, "status": "rejected", "reason": "busy"])
        XCTAssertTrue(model.session.state.wristMoving)
    }

    func testStopEndsTheWristHold() {
        bringUp()
        model.send(.wristStart)
        model.send(.stop)
        XCTAssertEqual(transport.types.last, "estop")
        let sentAfter = transport.sent.count
        run(ticks: 30)
        XCTAssertTrue(rolls(after: sentAfter).isEmpty)
    }

    func testArmHoldAndGripperTakeOverFromTheWristHold() {
        bringUp()
        model.send(.wristStart)
        model.send(.holdArmStart)
        XCTAssertEqual(transport.types.suffix(2), ["orient_start", "orient_stop"])
        XCTAssertFalse(model.session.state.wristMoving)
        serverFinished(lastOrientStartSeq())
        XCTAssertEqual(transport.types.suffix(2), ["orient_stop", "pose_start"])
        let hold = lastSeq(of: "pose_start")
        model.send(.holdArmEnd)
        serverFinished(hold)
        model.send(.wristStart)
        let turn = lastOrientStartSeq()
        model.send(.gripperStart(.open))
        XCTAssertEqual(transport.types.suffix(2), ["orient_start", "orient_stop"])
        serverFinished(turn)
        XCTAssertEqual(transport.types.suffix(2), ["orient_stop", "gripper_jog_start"])
        XCTAssertEqual(transport.types.filter { $0 == "orient_stop" }.count, 2)
    }

    func testWristHoldWithNoLinkIsRefusedWithACue() {
        makeModel(at: .p4)
        model.session.state.markConnected()
        model.send(.wristStart)
        XCTAssertFalse(model.session.state.wristMoving)
        XCTAssertTrue(transports.isEmpty)
    }

    /// The guide's commanded point: where the reported arm point is being sent, robot base frame, during the hold only.
    func testTheCommandedPointFollowsTheHandAndClearsOnRelease() {
        bringUp()
        transport.server("state", ["estop": false, "ee_pos": [0.02, -0.14, 0.16]])
        XCTAssertNil(model.link.commandedArm)
        model.send(.holdArmStart)
        // Right 1 cm, up 0.5 cm, forward 2 cm: right is base −X, forward −Y, up +Z.
        position = SIMD3(0.01, 0.005, -0.02)
        tick()
        let commanded = try! XCTUnwrap(model.link.commandedArm)
        XCTAssertLessThan(simd_distance(commanded, SIMD3(0.01, -0.16, 0.165)), 0.0001, "\(commanded)")
        // The input rules' 30 Hz tick redraws the screen; here it is called directly.
        model.inputsChanged()
        XCTAssertEqual(model.operating.arm?.commanded, commanded + model.profile.toolOffset, "the guide draws it")
        model.send(.holdArmEnd)
        XCTAssertNil(model.link.commandedArm)
    }

    func testTheCommandedPointClearsWhenTheHoldEndsByItself() {
        bringUp()
        transport.server("state", ["estop": false, "ee_pos": [0.02, -0.14, 0.16]])
        model.send(.holdArmStart)
        tick()
        XCTAssertNotNil(model.link.commandedArm)
        model.send(.stop)
        XCTAssertNil(model.link.commandedArm)
    }

    private func lastOffset() -> SIMD3<Float> {
        let update = transport.sent.last { $0["type"] as? String == "pose_update" }!["payload"] as! [String: Any]
        let p = update["p_rel_m"] as! [Double]
        return SIMD3(Float(p[0]), Float(p[1]), Float(p[2]))
    }

    /// The server's replies when a hold is stopped: the stop's ack, the start's final ack, then a state.
    private func serverFinishesHold(armAt position: [Double]) {
        let start = transport.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        transport.server("state", ["estop": false, "ee_pos": position])
    }

    /// Hand 20 cm to the right in a third of a second, with the arm reported at the origin beforehand.
    private func sweepRight() {
        bringUp()
        transport.server("state", ["estop": false, "ee_pos": [0.0, 0.0, 0.1]])
        model.send(.holdArmStart)
        for step in 1...10 {
            position = SIMD3(0.02 * Float(step), 0, 0)
            tick()
        }
    }

    func testNoServerHoldEverAsksForMoreThanTheLimit() {
        sweepRight()
        XCTAssertTrue(model.session.state.armMoving, "a fast hand must not end the hold")
        XCTAssertTrue(model.catchingUp)
        XCTAssertEqual(simd_length(lastOffset()), LiveLinkController.maxLeadMeters, accuracy: 0.0005)
        XCTAssertLessThan(lastOffset().x, 0, "still heading the way the hand went")
        // However long the hand waits, the same server hold never asks for more.
        for _ in 0..<40 { tick() }
        var farthest = 0.0
        for message in transport.sent where message["type"] as? String == "pose_update" {
            let payload = message["payload"] as! [String: Any]
            let p = payload["p_rel_m"] as! [Double]
            let x: Double = p[0], y: Double = p[1], z: Double = p[2]
            farthest = max(farthest, (x * x + y * y + z * z).squareRoot())
        }
        XCTAssertLessThanOrEqual(farthest, Double(LiveLinkController.maxLeadMeters) + 0.0005)
    }

    func testSmallMovesPassStraightThrough() {
        bringUp()
        model.send(.holdArmStart)
        position = SIMD3(0.02, 0, 0)
        tick()
        XCTAssertEqual(simd_length(lastOffset()), 0.02, accuracy: 0.0001)
        XCTAssertFalse(model.catchingUp)
        run(ticks: 90)
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 1, "no resync while the hand is within reach")
    }

    func testHandBeyondTheLimitResyncsWithTheRealArmAndGoesOn() {
        sweepRight()
        // 1.5 s of catching up, then the app ends the server hold to ask where the arm is.
        run(ticks: 50)
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop")
        XCTAssertTrue(model.session.state.armMoving, "the operator's hold goes on")
        let updatesBefore = transport.types.filter { $0 == "pose_update" }.count
        run(ticks: 5)
        XCTAssertEqual(transport.types.filter { $0 == "pose_update" }.count, updatesBefore, "nothing is asked while waiting")

        // The arm got 3 cm to the right (−X in the robot base).
        serverFinishesHold(armAt: [-0.03, 0.0, 0.1])
        XCTAssertEqual(transport.types.last, "pose_start")
        tick()
        // 17 cm still to go, so the new hold asks for the limit again, measured from the arm's new position.
        XCTAssertEqual(simd_length(lastOffset()), LiveLinkController.maxLeadMeters, accuracy: 0.0005)
        // The guide's commanded point: 3 cm done plus 8 cm asked, from the arm's new position.
        XCTAssertEqual(model.link.commandedArm!.x, -0.11, accuracy: 0.001)
    }

    func testLastStretchIsAskedExactly() {
        sweepRight()
        run(ticks: 50)
        // The arm is already 15 cm along; 5 cm are left, inside the limit.
        serverFinishesHold(armAt: [-0.15, 0.0, 0.1])
        tick()
        XCTAssertEqual(lastOffset().x, -0.05, accuracy: 0.0005)
        XCTAssertFalse(model.catchingUp)
        run(ticks: 90)
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2, "no further resync once within reach")
    }

    func testArmStuckAtTheEdgeNeverAccumulatesALead() {
        sweepRight()
        for _ in 0..<3 {
            run(ticks: 50)
            // The arm has not moved at all.
            serverFinishesHold(armAt: [0.0, 0.0, 0.1])
            tick()
            XCTAssertEqual(simd_length(lastOffset()), LiveLinkController.maxLeadMeters, accuracy: 0.0005)
        }
        XCTAssertTrue(model.session.state.armMoving)
    }

    func testStateBeforeTheServerFinishedDoesNotRestartTheHold() {
        sweepRight()
        run(ticks: 50)
        transport.server("state", ["estop": false, "ee_pos": [-0.01, 0.0, 0.1]])
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 1)
        serverFinishesHold(armAt: [-0.03, 0.0, 0.1])
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2)
    }

    func testServerThatNeverFinishesEndsTheOperatorsHold() {
        sweepRight()
        run(ticks: 50)
        run(ticks: 50)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(model.debugLog.contains { $0.contains("resync") })
    }

    func testReleaseDuringAResyncEndsCleanly() {
        sweepRight()
        run(ticks: 50)
        model.send(.holdArmEnd)
        serverFinishesHold(armAt: [-0.03, 0.0, 0.1])
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 1, "a released hold must not restart")
        XCTAssertNil(model.link.commandedArm)
    }

    func testStopDuringAResyncStaysStopped() {
        sweepRight()
        run(ticks: 50)
        model.send(.stop)
        serverFinishesHold(armAt: [-0.03, 0.0, 0.1])
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 1)
        XCTAssertEqual(model.session.route, .s4)
    }

    func testStopCauseSaysWhoStopped() {
        bringUp()
        XCTAssertNil(model.stopCause)
        model.send(.stop)
        XCTAssertEqual(model.stopCause, .button)
        model.send(.releaseStop)
        XCTAssertNil(model.stopCause)
    }

    func testServerStopAfterTheArmFellBehindSaysSo() {
        // The wording is checked in English, whatever language the simulator or an earlier test left behind.
        let language = L10n.language
        L10n.language = .en
        defer { L10n.language = language }
        bringUp()
        model.send(.holdArmStart)
        let start = transport.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        transport.server("ack", seq: start, ["seq": start, "status": "rejected", "reason": "pose_tracking_safety_stop"])
        transport.server("state", ["estop": true])
        XCTAssertEqual(model.session.route, .s4)
        XCTAssertEqual(model.stopCause, .armBehind)
        XCTAssertTrue(model.stopCause!.text.contains("10 cm"))
    }

    func testServerAlreadyStoppedOnConnectSaysSo() {
        bringUp(estop: true)
        XCTAssertEqual(model.stopCause, .onConnect)
    }

    func testServerStopWithNoKnownReasonIsStillNamed() {
        bringUp()
        transport.server("state", ["estop": true])
        XCTAssertEqual(model.stopCause, .server("unknown"))
    }

    func testSensitivityScalesThePhoneOffset() {
        bringUp()
        model.session.state.sensitivity = 0.5
        model.session.state.setSmoothing(0)
        model.send(.holdArmStart)
        position = SIMD3(0.01, 0, 0)
        tick()
        XCTAssertEqual((transport.sent.last!["payload"] as! [String: Any])["p_rel_m"] as? [Double], [-0.005, 0, 0])
    }

    func testSmoothingLagsThenSettlesOnTheHand() {
        bringUp()
        model.session.state.setSmoothing(0.5)
        model.send(.holdArmStart)
        position = SIMD3(0.01, 0, 0)
        tick()
        let first = ((transport.sent.last!["payload"] as! [String: Any])["p_rel_m"] as! [Double])[0]
        XCTAssertEqual(first, -0.005, accuracy: 0.0001)
        for _ in 0..<20 { tick() }
        let settled = ((transport.sent.last { $0["type"] as? String == "pose_update" }!["payload"] as! [String: Any])["p_rel_m"] as! [Double])[0]
        XCTAssertEqual(settled, -0.01, accuracy: 0.0001)
    }

    /// What the robot base does with an offset, per the server's calibrated mapping: [x, y, −z].
    private func baseMotion(_ world: SIMD3<Float>, camera: simd_float4x4) -> SIMD3<Float> {
        let axes = LiveLinkController.operatorAxes(camera)
        let sent = LiveLinkController.serverOffset(world, right: axes.right, forward: axes.forward)
        return SIMD3(sent.x, sent.y, -sent.z)
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), 0.0001, "\(a) vs \(b)", file: file, line: line)
    }

    func testUprightPhoneMovesTheArmTheWayTheHandMoves() {
        let upright = TestPose.portrait
        assertClose(baseMotion(SIMD3(0.1, 0, 0), camera: upright), SIMD3(-0.1, 0, 0))   // right → −X
        assertClose(baseMotion(SIMD3(0, 0, -0.1), camera: upright), SIMD3(0, -0.1, 0))  // forward → −Y
        assertClose(baseMotion(SIMD3(0, 0.1, 0), camera: upright), SIMD3(0, 0, 0.1))    // up → +Z
    }

    func testTurningAroundTurnsRightAndForwardWithTheOperator() {
        // Facing world +x.
        let turned = TestPose.portrait(turned: -90, about: SIMD3(0, 1, 0))
        assertClose(baseMotion(SIMD3(0.1, 0, 0), camera: turned), SIMD3(0, -0.1, 0))    // now forward
        assertClose(baseMotion(SIMD3(0, 0, 0.1), camera: turned), SIMD3(-0.1, 0, 0))    // now right
        assertClose(baseMotion(SIMD3(0, 0.1, 0), camera: turned), SIMD3(0, 0, 0.1))     // up is always up
    }

    func testPhoneLyingFlatUsesItsTopEdgeAsForward() {
        // Screen up, camera looking at the floor, top edge toward world −z.
        let flat = TestPose.portrait(turned: -90, about: SIMD3(1, 0, 0))
        assertClose(baseMotion(SIMD3(0, 0, -0.1), camera: flat), SIMD3(0, -0.1, 0))     // forward
        assertClose(baseMotion(SIMD3(0.1, 0, 0), camera: flat), SIMD3(-0.1, 0, 0))      // right
        assertClose(baseMotion(SIMD3(0, 0.1, 0), camera: flat), SIMD3(0, 0, 0.1))       // up
    }

    func testLeaningBackKeepsForwardStraightAhead() {
        for degrees: Float in [20, 45, 70] {
            let leaning = TestPose.portrait(turned: -degrees, about: SIMD3(1, 0, 0))
            assertClose(baseMotion(SIMD3(0, 0, -0.1), camera: leaning), SIMD3(0, -0.1, 0))
            assertClose(baseMotion(SIMD3(0.1, 0, 0), camera: leaning), SIMD3(-0.1, 0, 0))
            assertClose(baseMotion(SIMD3(0, 0.1, 0), camera: leaning), SIMD3(0, 0, 0.1))
        }
    }

    /// The bug this guards against: reading ARKit's sensor axes as if the phone were held landscape,
    /// which skewed forward by 45 degrees for an upright phone.
    func testRawCameraAxesAreNotMistakenForThePhonesEdges() {
        let axes = PhoneAxes(TestPose.portrait)
        assertClose(axes.top, SIMD3(0, 1, 0))
        assertClose(axes.right, SIMD3(1, 0, 0))
        assertClose(axes.view, SIMD3(0, 0, -1))
    }

    func testResetSceneIsSent() {
        bringUp()
        model.send(.resetScene)
        XCTAssertEqual(transport.types.last, "reset_scene")
    }

    func testSlowRoundTripBlocksCommands() {
        bringUp()
        for round in 1...2 {
            for _ in 0..<(TeleopLink.poseRateHz / 2) { tick() }
            let probe = transport.sent.last!
            XCTAssertEqual(probe["type"] as? String, "test")
            clock += 450
            transport.server("test", seq: probe["seq"] as! Int)
            if round == 1 { XCTAssertFalse(model.session.state.commandsBlocked, "one slow sample must not block") }
        }
        XCTAssertTrue(model.session.state.commandsBlocked)
        XCTAssertEqual(model.session.route, .p6)
        XCTAssertEqual(model.session.state.latencyMs, 450)
    }

    func testUserDisconnectClosesTheSocketQuietly() {
        makeModel(at: .s1)
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": false])
        model.send(.changeServer)
        model.send(.disconnect)
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(model.session.route, .s1)
        XCTAssertFalse(model.session.state.connectionLost)
    }

    func testSwitchingToTheDemoClosesTheSocketAndConnectsTheDemo() {
        bringUp()
        model.send(.holdArmStart)
        model.send(.openSettings)
        model.startPractice()
        XCTAssertTrue(transport.closed)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(model.session.state.connected, "the demo link is connected from the start")
        XCTAssertEqual(model.session.route, .s6)
    }

    func testSwitchingToTheRealServerTriesTheServerAddress() {
        transports = []
        let demo = AppModel(start: .s6, haptics: NoHaptics(), pose: { nil }, liveLink: false, makeTransport: { [unowned self] _ in
            let made = FakeTransport()
            transports.append(made)
            return made
        })
        demo.session.state.serverAddress = "100.64.0.1:8765"
        demo.leavePractice()
        XCTAssertEqual(transports.count, 1)
        XCTAssertTrue(transports[0].opened)
        XCTAssertFalse(demo.session.state.connected, "connected only once the server answers")
        XCTAssertEqual(demo.session.route, .s6)
    }

    func testLaunchTriesTheSavedServerOnce() {
        makeModel(at: .p4)
        XCTAssertTrue(transports.isEmpty, "making the model opens nothing")
        model.trySavedServer()
        XCTAssertEqual(transports.count, 1)
        XCTAssertTrue(transport.opened)
        XCTAssertFalse(model.session.state.connected)
        model.trySavedServer()
        XCTAssertEqual(transports.count, 1, "a socket already open is left alone")
    }

    func testLaunchWithNoSavedServerOpensNothing() {
        makeModel(at: .p4)
        model.session.state.serverAddress = ""
        model.trySavedServer()
        XCTAssertTrue(transports.isEmpty)
    }

    /// I-8.3: the tilt window counts from the flex measured after the last reset. A reconnect to the same run keeps
    /// it; only a new `welcome.session` starts it again. A server that names no run never does on a reconnect.
    func testOnlyANewServerRunStartsTheTiltWindowAgain() {
        for named in [false, true] {
            makeModel(at: .p4)
            model.connect()
            transport.server("welcome", named ? ["session": "run-1"] : [:])
            transport.server("state", ["estop": false, "wrist_flex_deg": 40.0])
            XCTAssertEqual(model.inputFacts().wrist.flexAtResetDeg, 40)
            model.connect()
            transport.server("welcome", named ? ["session": "run-1"] : [:])
            transport.server("state", ["estop": false, "wrist_flex_deg": 55.0])
            XCTAssertEqual(model.inputFacts().wrist.flexAtResetDeg, 40, "a reconnect, named: \(named)")
            guard named else { continue }
            model.connect()
            transport.server("welcome", ["session": "run-2"])
            transport.server("state", ["estop": false, "wrist_flex_deg": 55.0])
            XCTAssertEqual(model.inputFacts().wrist.flexAtResetDeg, 55, "a new run")
        }
    }

    func testReconnectDropsTheOldSocket() {
        bringUp()
        let first = transport!
        model.connect()
        XCTAssertTrue(first.closed)
        first.onClose?()
        XCTAssertTrue(model.link.isOpen)
    }

    func testFakeLinkNeverOpensASocket() {
        transports = []
        let fake = AppModel(start: .s1, haptics: NoHaptics(), pose: { nil }, liveLink: false, makeTransport: { [unowned self] _ in
            let made = FakeTransport()
            transports.append(made)
            return made
        })
        fake.connect()
        fake.send(.holdArmStart)
        fake.send(.stop)
        XCTAssertTrue(fake.session.state.connected)
        XCTAssertTrue(transports.isEmpty)
    }

    // MARK: The listening connection

    private var observer: FakeTransport { observers.last! }

    /// The listening connection's own welcome and first state.
    private func bringUpObserver(_ payload: [String: Any] = ["estop": false, "gripper": "closed"]) {
        observer.server("welcome", ["session": "run-1"])
        observer.server("state", payload)
    }

    func testTheListeningConnectionOpensAfterTheWelcomeAndOnlyListens() {
        makeModel(at: .p4)
        model.connect()
        XCTAssertTrue(observers.isEmpty, "not before the control connection's welcome")
        transport.server("welcome")
        XCTAssertEqual(observers.count, 1)
        XCTAssertTrue(observer.opened)
        XCTAssertEqual(observer.types, ["hello"])
        XCTAssertEqual((transport.sent[0]["payload"] as? [String: String])?["name"], "teleop-ios/1.0.0 (7)")
        XCTAssertEqual((observer.sent[0]["payload"] as? [String: String])?["name"], "teleop-ios/1.0.0 (7) observer")
        transport.server("state", ["estop": false, "gripper": "closed"])
        bringUpObserver()
        model.send(.holdArmStart)
        run(ticks: 20)
        model.send(.holdArmEnd)
        XCTAssertEqual(observer.types, ["hello"], "it never sends a command")
        XCTAssertTrue(model.link.observerUp)
    }

    func testStopGoesOutOnBothConnections() {
        bringUp()
        bringUpObserver()
        model.send(.stop)
        XCTAssertEqual(transport.types.last, "estop")
        XCTAssertEqual(observer.types.last, "estop")
        XCTAssertEqual(felt.felt, [.play(.alarm)])
    }

    func testStopBeforeTheListeningConnectionIsUpGoesOutOnTheControlOne() {
        bringUp()
        model.send(.stop)
        XCTAssertEqual(transport.types.last, "estop")
        XCTAssertEqual(observer.types, ["hello"])
    }

    /// With no connection up nothing pretends the robot stopped: three ticks and "No link. Not stopped.", and the
    /// `estop` goes out first after the next welcome, with the rattle.
    func testStopWithNoLinkIsNotPretendedAndIsSentAfterTheNextWelcome() {
        makeModel(at: .p4)
        model.send(.stop)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(felt.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["No link. Not stopped."])
        XCTAssertEqual(model.operating.state, .notConnected(reason: nil), "the screen does not say stopped either")
        speech.finish()
        model.connect()
        XCTAssertEqual(transport.types, ["hello"])
        transport.server("welcome")
        XCTAssertEqual(transport.types, ["hello", "estop"])
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        XCTAssertEqual(felt.felt, [.play(.no), .play(.alarm)])
        XCTAssertEqual(speech.spoken.last, "Emergency stop. You pressed stop. Hold the top edge to reset.")
        transport.server("state", ["estop": true, "gripper": "closed"])
        XCTAssertEqual(felt.felt.filter { $0 == .play(.alarm) }.count, 1, "the server's own stop is not told twice")
    }

    /// Practice stays refused while the stop is latched (§7.4), and Connect and Settings say why. Before the STOP
    /// reaches a robot the robot is not stopped (J7), so the reason says the STOP is waiting; once the welcome has
    /// sent it, the robot is stopped.
    func testThePracticeRefusalSaysWhetherTheStopReachedARobot() {
        makeModel(at: .p4)
        model.send(.stop)
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked_unsent")
        model.startPractice()
        XCTAssertTrue(model.liveLink, "practice is refused")
        model.connect()
        transport.server("welcome")
        XCTAssertEqual(transport.types.last, "estop")
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked")
        XCTAssertTrue(model.session.state.emergencyStop)
    }

    /// §6.5: with a recorder, estop_reset is not offered at all, so the model refuses a release whatever sends it, and
    /// only the reset leaves the stop. With no recorder, and on a server that does not say (no `rec`), the release is
    /// offered and works.
    func testReleaseKeepSceneIsRefusedWithARecorderOnly() {
        bringUp()
        transport.server("state", ["estop": false, "gripper": "closed", "rec": "armed", "rec_saved": 0])
        model.send(.stop)
        XCTAssertEqual(model.stopExits.exits, [.resetScene])
        XCTAssertFalse(model.operating.stopExits.exits.contains(.releaseKeepScene), "the screen offers only the reset")
        model.send(.releaseStop)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertFalse(transport.types.contains("estop_reset"))
        XCTAssertEqual(model.cueLog.last?.event, .refused(.deadInput), "the refused release is heard")

        for state: [String: Any] in [["estop": false, "gripper": "closed", "rec": "none"], ["estop": false, "gripper": "closed"]] {
            bringUp()
            transport.server("state", state)
            model.send(.stop)
            XCTAssertEqual(model.stopExits.exits, [.resetScene, .releaseKeepScene], "\(state)")
            model.send(.releaseStop)
            XCTAssertFalse(model.session.state.emergencyStop, "\(state)")
            XCTAssertEqual(transport.types.last, "estop_reset", "\(state)")
        }
    }

    func testAStopReleasedBeforeTheLinkCameBackIsNotSentLater() {
        makeModel(at: .p4)
        model.send(.stop)
        model.send(.releaseStop)
        model.connect()
        transport.server("welcome")
        XCTAssertEqual(transport.types, ["hello"])
    }

    func testADroppedListeningConnectionIsReopenedEvery2sWithoutAWord() {
        bringUp()
        bringUpObserver()
        observer.onClose?()
        XCTAssertFalse(model.link.observerUp)
        XCTAssertTrue(model.session.state.connected)
        run(ticks: 55)
        XCTAssertEqual(observers.count, 1, "not before 2 s")
        run(ticks: 10)
        XCTAssertEqual(observers.count, 2)
        XCTAssertEqual(observer.types, ["hello"])
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertTrue(felt.felt.isEmpty)
        XCTAssertTrue(sounds.played.isEmpty)
    }

    func testAListeningConnectionThatGoesQuietIsReplaced() {
        bringUp()
        bringUpObserver()
        run(ticks: 65)
        XCTAssertEqual(observers.count, 1)
        XCTAssertTrue(observers[0].closed, "closed after 2 s of silence")
        run(ticks: 65)
        XCTAssertEqual(observers.count, 2)
        XCTAssertTrue(model.session.state.connected, "the control connection was answering all along")
    }

    func testTheNewestStateFromEitherConnectionIsUsed() {
        bringUp()
        bringUpObserver()
        observer.server("state", seq: 0, ["estop": false, "rec": "capturing", "rec_saved": 7, "rec_discarded": 1, "rec_samples": 60,
                                          "wrist_flex_deg": 41.5, "wrist_roll_deg": 88.0, "gripper_deg": 12.0])
        XCTAssertEqual(model.serverState?.wristRollDeg, 88)
        XCTAssertEqual(model.serverState?.gripperDeg, 12)
        XCTAssertEqual(model.recorder, RecorderDisplay(mode: .capturing, saved: 7, discarded: 1, secondsCaptured: 2))
        XCTAssertEqual(model.stopExits.exits, [.resetScene], "with a recorder only a reset leaves the stop")
    }

    func testAStateThatLeftTheServerEarlierIsNotTakenForNews() {
        bringUp()
        bringUpObserver()
        let state = { (ts: Int, saved: Int) in
            ["v": 1, "type": "state", "ts": ts, "seq": 0, "payload": ["estop": false, "rec": "armed", "rec_saved": saved]] as [String: Any]
        }
        let send = { (to: FakeTransport, message: [String: Any]) in
            to.onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
        }
        send(observer, state(5000, 3))
        send(observer, state(5200, 4))
        send(transport, state(5100, 3))
        XCTAssertEqual(model.recorder.saved, 4)
        XCTAssertEqual(sounds.played, [.saved], "saved once, not twice")
    }

    // MARK: Feedback on a real server

    func testGoPlaysWhenTheStartHasGoneOutAndNoRefusalCame() {
        bringUp()
        model.send(.holdArmStart)
        XCTAssertEqual(felt.felt, [])
        for _ in 0..<9 { tick() }
        XCTAssertEqual(felt.felt, [], "297 ms: still inside the acceptance time")
        tick()
        XCTAssertEqual(felt.felt, [.play(.go)])
    }

    func testAStartRefusedAtOnceGetsThreeTicksAndTheReason() {
        bringUp()
        model.send(.gripperStart(.closed))
        let start = lastSeq(of: "gripper_jog_start")
        transport.server("ack", seq: start, ["seq": start, "status": "rejected", "reason": "busy"])
        XCTAssertEqual(felt.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["Wait."])
        for _ in 0..<12 { tick() }
        XCTAssertEqual(felt.felt, [.play(.no)], "no GO for a refused start")
    }

    func testTooFastEndsTheHoldWithTwoLongBuzzesAndTheReason() {
        bringUp()
        model.send(.holdArmStart)
        for _ in 0..<10 { tick() }
        position = SIMD3(0.2, 0, 0)
        tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(felt.felt, [.play(.go), .play(.letGo)])
        XCTAssertEqual(speech.spoken, ["Too fast."])
    }

    func testTheServersWatchdogEndingAHoldSaysLinkHiccup() {
        bringUp()
        model.send(.holdArmStart)
        let start = lastSeq(of: "pose_start")
        for _ in 0..<10 { tick() }
        transport.server("ack", seq: start, ["seq": start, "status": "rejected", "reason": "pose_watchdog_timeout"])
        XCTAssertEqual(felt.felt, [.play(.go), .play(.letGo)])
        XCTAssertEqual(speech.spoken, ["Link hiccup."])
    }

    func testContactWhileClosingGripsAndTheModelKnowsItIsGripping() {
        bringUp()
        bringUpObserver()
        model.send(.gripperStart(.closed))
        for _ in 0..<10 { tick() }
        observer.server("state", ["estop": false, "gripper": "close", "ik": "gripper_contact", "gripper_deg": 8.0])
        XCTAssertEqual(felt.felt, [.play(.go), .play(.grip)])
        let close = lastSeq(of: "gripper_jog_start")
        model.send(.gripperEnd)
        XCTAssertTrue(model.gripping)
        model.send(.gripperStart(.open))
        XCTAssertTrue(model.gripping, "the open waits for the close's final ack")
        serverFinished(close)
        XCTAssertEqual(transport.types.last, "gripper_jog_start")
        XCTAssertFalse(model.gripping, "an open ends it")
    }

    /// Gripping belongs to the real jaws: practice has none, so a close there is never refused for a grip the server
    /// reported, and the real server's grip is known again on leaving practice.
    func testGrippingOnTheRealServerDoesNotCarryIntoPractice() {
        bringUp()
        bringUpObserver()
        model.send(.gripperStart(.closed))
        for _ in 0..<10 { tick() }
        observer.server("state", ["estop": false, "gripper": "close", "ik": "gripper_contact", "gripper_deg": 8.0])
        model.send(.gripperEnd)
        XCTAssertTrue(model.gripping)
        XCTAssertTrue(model.inputFacts().gripping)

        model.startPractice()
        XCTAssertFalse(model.gripping, "practice has no grip")
        XCTAssertFalse(model.inputFacts().gripping, "so a second close is not refused there")
        model.send(.gripperStart(.closed))
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        XCTAssertNotEqual(model.cueLog.last?.event, .limit(.alreadyGripping))
        model.send(.gripperEnd)

        model.leavePractice()
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "close"])
        XCTAssertTrue(model.gripping, "the same server run: its jaws still grip")
    }

    func testLosingTheLinkDuringAHoldLetsGoWithTheSound() {
        bringUp()
        model.send(.holdArmStart)
        for _ in 0..<10 { tick() }
        transport.onClose?()
        XCTAssertEqual(felt.felt, [.play(.go), .play(.letGo)])
        XCTAssertEqual(sounds.played, [.linkLost])
        XCTAssertEqual(speech.spoken, ["Link lost."])
    }

    func testLosingAnIdleLinkIsHeardNotFelt() {
        bringUp()
        transport.onClose?()
        XCTAssertEqual(felt.felt, [])
        XCTAssertEqual(sounds.played, [.linkLost])
    }

    func testAStoppedServerFoundAfterADropDuringAHoldBlamesTheLink() {
        bringUp()
        model.send(.holdArmStart)
        transport.onClose?()
        speech.finish()
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": true, "gripper": "closed"])
        XCTAssertEqual(speech.spoken.last, "Emergency stop. The link dropped during a move. Hold the top edge to reset.")
    }

    func testResetWaitsForTheStoppedHoldsFinalAck() {
        bringUp()
        model.send(.holdArmStart)
        let start = lastSeq(of: "pose_start")
        tick()
        model.send(.holdArmEnd)
        model.send(.resetScene)
        XCTAssertEqual(transport.types.last, "pose_stop")
        serverFinished(start)
        XCTAssertEqual(transport.types.last, "reset_scene")
    }

    func testAResetTheServerCannotTakeSaysSo() {
        bringUp()
        model.send(.resetScene)
        let reset = lastSeq(of: "reset_scene")
        transport.server("ack", seq: reset, ["seq": reset, "status": "rejected", "reason": "sim_not_ready"])
        XCTAssertEqual(speech.spoken, ["Not reset. Wait."])
    }

    func testAResetWhileTheArmIsHeldIsRefusedAndNothingIsSent() {
        bringUp()
        model.send(.holdArmStart)
        model.send(.resetScene)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertFalse(transport.types.contains("reset_scene"))
        XCTAssertFalse(transport.types.contains("pose_stop"))
        XCTAssertEqual(speech.spoken, ["Let go first."])
    }

    func testAPressWithNoLinkSaysSo() {
        makeModel(at: .p4)
        model.send(.holdArmStart)
        XCTAssertEqual(felt.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["No link."])
    }

    /// C-R4: a press while the reset waits for a final ack is refused, so `reset_scene` never goes out behind a
    /// start released by the same ack.
    func testAPressWhileAResetIsPendingIsRefusedAndTheResetStillGoesOutAlone() throws {
        bringUp()
        model.send(.holdArmStart)
        let start = lastSeq(of: "pose_start")
        tick()
        model.send(.holdArmEnd)
        model.send(.resetScene)
        model.send(.holdArmStart)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(felt.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["Wait."])
        clock += 400
        model.send(.gripperStart(.closed))
        XCTAssertEqual(felt.felt, [.play(.no), .play(.no)])
        model.send(.gripperEnd)
        serverFinished(start)
        let stop = try XCTUnwrap(transport.types.lastIndex(of: "pose_stop"))
        XCTAssertEqual(Array(transport.types[(stop + 1)...]), ["reset_scene"])
    }

    /// §5.4: a hold the server ends with a success plays no LETGO; the session's hold ends with it.
    func testAHoldEndedBySuccessEndsQuietly() {
        bringUp()
        model.send(.holdArmStart)
        let start = lastSeq(of: "pose_start")
        for _ in 0..<10 { tick() }
        transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "task_success"])
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(felt.felt, [.play(.go)])
        XCTAssertEqual(speech.spoken, [])
        let sent = transport.sent.count
        tick()
        XCTAssertFalse(transport.types.dropFirst(sent).contains("pose_update"), "nothing more is streamed for it")
    }

    /// I-7: with the listening connection up, 1.2 s with nothing on either connection is a lost link.
    func testWithTheListeningConnectionUpTheLinkIsLostAfter1point2sOfSilence() {
        bringUp()
        bringUpObserver()
        for _ in 0..<36 { tick() }
        XCTAssertTrue(model.session.state.connected, "1.19 s")
        tick()
        XCTAssertFalse(model.session.state.connected, "1.22 s")
        XCTAssertEqual(sounds.played, [.linkLost])
    }

    /// A talking listening connection does not keep a control connection alive that has heard nothing for 2 s:
    /// its commands are not getting through.
    func testAListeningConnectionThatKeepsTalkingCoversAtMost2sOfControlSilence() {
        bringUp()
        bringUpObserver()
        for step in 0..<60 {
            tick()
            if step % 6 == 0 { observer.server("state", ["estop": false, "gripper": "closed"]) }
        }
        XCTAssertTrue(model.session.state.connected, "the control connection alone allows 2 s")
        for _ in 0..<5 { tick() }
        XCTAssertFalse(model.session.state.connected, "and no more")
    }

    // MARK: On target is felt

    /// Where the profile's offset was measured: there the estimated pinch point is exact.
    private var graspArm: SIMD3<Double> { SIMD3(model.profile.offsetMeasuredAt) }

    /// A state with the gripper point at `arm`, the wrist where the offset was measured and the jaws' label, and the
    /// task object (world frame) right under the estimated pinch point of `objectUnder`, or no task object.
    private func armState(
        _ arm: SIMD3<Double>, objectUnder: SIMD3<Double>? = nil, noObject: Bool = false, gripper: String? = "open",
        tool: SIMD3<Double>? = nil, episode: Int? = 0, estop: Bool = false
    ) -> [String: Any] {
        var state: [String: Any] = [
            "estop": estop, "ee_pos": [arm.x, arm.y, arm.z],
            "wrist_flex_deg": model.profile.offsetMeasuredFlexDeg, "wrist_roll_deg": model.profile.offsetMeasuredRollDeg,
        ]
        if let gripper { state["gripper"] = gripper }
        if let episode { state["episode"] = episode }
        if !noObject {
            let object = (objectUnder ?? graspArm) + SIMD3<Double>(model.profile.toolOffset + model.profile.baseInWorld)
            state["object_pos"] = [object.x, object.y, object.z]
        }
        if let tool { state["tool_pos"] = [tool.x, tool.y, tool.z] }
        return state
    }

    private var feltOnTarget: Int { felt.felt.filter { $0 == .play(.onTarget) }.count }

    private var guide: GuidePicture? { model.operating.arm.map { GuidePicture(reading: $0, profile: model.profile) } }

    /// Felt once as the guide turns On target during a hold, from the listening connection, and not again while the
    /// pinch point stays inside the window 1.5 times as large; after the hold, leaving that window arms it again.
    func testOnTargetIsFeltOnceDuringAHoldAndAgainOnlyAfterLeavingTheWiderWindow() {
        bringUp()
        bringUpObserver(armState(graspArm + SIMD3(0.02, 0.02, 0.02)))
        model.send(.holdArmStart)
        run(ticks: 10)
        XCTAssertTrue(model.session.state.armMoving)
        observer.server("state", armState(graspArm + SIMD3(0, 0, 0.02)))
        XCTAssertEqual(feltOnTarget, 0, "2 cm above the object")
        observer.server("state", armState(graspArm))
        XCTAssertEqual(guide?.onTarget, true)
        XCTAssertEqual(feltOnTarget, 1, "heard on the listening connection while the hold runs")
        XCTAssertTrue(model.cueLog.contains { $0.event == .onTarget && $0.haptic == .onTarget && $0.sound == nil && $0.speech.isEmpty })
        for x in [0.004, 0.0065, 0.003, 0.0085, 0.0] {
            run(ticks: 6)
            observer.server("state", armState(graspArm + SIMD3(x, 0, 0)))
        }
        model.send(.holdArmEnd)
        transport.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1, "out of the window and back, never past 9 mm: once")
        clock += 1000
        transport.server("state", armState(graspArm + SIMD3(0.0095, 0, 0)))
        XCTAssertEqual(guide?.approximate, false)
        transport.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 2, "after the hold, back from past 9 mm")
    }

    /// A close arms it again, so opening on the target after a miss is felt; a scene reset arms it again too.
    func testACloseOrAResetArmsTheOnTargetCueAgain() {
        bringUp()
        bringUpObserver(armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        observer.server("state", armState(graspArm, gripper: "close"))
        XCTAssertEqual(feltOnTarget, 1, "the jaws are not open")
        clock += 1000
        observer.server("state", armState(graspArm, gripper: "open"))
        XCTAssertEqual(feltOnTarget, 2, "opened again on the target")
        clock += 1000
        observer.server("state", armState(graspArm, episode: 1))
        XCTAssertEqual(feltOnTarget, 3, "a new episode is a scene reset")
    }

    /// 1 cm nearer the base than where the offset was measured, with the object under the estimated pinch point: the
    /// estimate may be 11 mm off, so the marker is approximate and nothing is felt. The same place with a reported
    /// tool point is felt.
    func testOnTargetIsNotFeltWhileTheMarkerIsApproximate() {
        bringUp()
        let nearer = graspArm + SIMD3(0, 0.01, 0)
        bringUpObserver(armState(nearer + SIMD3(0, 0, 0.03), objectUnder: nearer))
        observer.server("state", armState(nearer, objectUnder: nearer))
        XCTAssertEqual(guide?.approximate, true)
        XCTAssertEqual(guide?.onTarget, false)
        XCTAssertEqual(feltOnTarget, 0)
        let pinch = nearer + SIMD3<Double>(model.profile.toolOffset)
        observer.server("state", armState(nearer, objectUnder: nearer, tool: pinch))
        XCTAssertEqual(guide?.approximate, false)
        XCTAssertEqual(feltOnTarget, 1, "a reported tool point is never approximate")
    }

    func testOnTargetIsNotFeltWithTheTaskAidOff() {
        let saved = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
        defer { UserDefaults.standard.set(saved, forKey: AppModel.taskAidKey) }
        bringUp()
        model.taskAid = false
        bringUpObserver(armState(graspArm + SIMD3(0, 0, 0.03)))
        observer.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 0)
        model.taskAid = true
        XCTAssertEqual(feltOnTarget, 1, "turned on with the jaws on the target: the guide turns On target now")
    }

    func testOnTargetIsNotFeltWhileTheStopIsLatched() {
        bringUp()
        bringUpObserver(armState(graspArm + SIMD3(0, 0, 0.03)))
        model.send(.stop)
        observer.server("state", armState(graspArm, estop: true))
        XCTAssertEqual(feltOnTarget, 0)
        XCTAssertEqual(felt.felt, [.play(.alarm)])
    }

    /// A stop the server reports in the very state that brings the jaws onto the target, on either connection, is a
    /// latched stop too: only the rattle.
    func testOnTargetIsNotFeltInAStateThatReportsAStop() {
        for onObserver in [true, false] {
            bringUp()
            bringUpObserver(armState(graspArm + SIMD3(0, 0, 0.03)))
            let on = onObserver ? observer : transport!
            on.server("state", armState(graspArm, estop: true))
            XCTAssertEqual(feltOnTarget, 0, onObserver ? "listening connection" : "control connection")
        }
    }

    /// A reset's answer can come before the first state after it. The state from before the reset, still on the
    /// target, must not be felt again as if the jaws had just arrived.
    func testAResetAnsweredBeforeItsStateDoesNotReplayTheCueFromTheOldState() {
        bringUp()
        bringUpObserver(armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        model.send(.resetScene)
        let reset = lastSeq(of: "reset_scene")
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok"])
        run(ticks: 3)
        XCTAssertEqual(feltOnTarget, 1, "nothing new is known about the jaws yet")
        observer.server("state", armState(graspArm + SIMD3(0.02, 0.02, 0.02), gripper: "closed", episode: 1))
        clock += 1000
        observer.server("state", armState(graspArm, episode: 1))
        XCTAssertEqual(feltOnTarget, 2, "the next approach after the reset")
    }

    /// A server that reports no episode: the reset's answer arms the cue on the first state after it, even with the
    /// jaws left open and the pinch point never more than 9 mm from the target.
    func testOnAServerWithoutEpisodesTheStateAfterAResetsAnswerArmsTheCue() {
        bringUp()
        bringUpObserver(armState(graspArm, episode: nil))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        model.send(.resetScene)
        let reset = lastSeq(of: "reset_scene")
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok"])
        XCTAssertEqual(feltOnTarget, 1)
        observer.server("state", armState(graspArm + SIMD3(0.007, 0, 0), episode: nil))
        XCTAssertEqual(feltOnTarget, 1, "7 mm off: out of the window")
        clock += 1000
        observer.server("state", armState(graspArm, episode: nil))
        XCTAssertEqual(feltOnTarget, 2, "the approach after the reset")
    }

    /// On a server without episodes, a state sent while the reset was still running can arrive after the reset's
    /// answer, on the other connection. It still shows the arm from before the reset, so it does not arm the cue.
    func testAStateFromWhileTheResetRanArrivingAfterItsAnswerDoesNotReplayTheCue() {
        bringUp()
        bringUpObserver(armState(graspArm, episode: nil))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        model.send(.resetScene)
        let reset = lastSeq(of: "reset_scene")
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok"])
        var late = armState(graspArm, episode: nil)
        late["ik"] = "resetting"
        observer.server("state", late)
        XCTAssertEqual(feltOnTarget, 1, "sent while the server was still resetting")
        observer.server("state", armState(graspArm + SIMD3(0.007, 0, 0), episode: nil))
        clock += 1000
        observer.server("state", armState(graspArm, episode: nil))
        XCTAssertEqual(feltOnTarget, 2, "the approach after the reset")
    }

    /// On a server with episodes the new episode is the one sign of a reset: the reset's answer coming after it does
    /// not arm the cue a second time.
    func testOneResetArmsTheCueOnceWhenTheNewEpisodeComesBeforeTheAnswer() {
        bringUp()
        bringUpObserver(armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        model.send(.resetScene)
        let reset = lastSeq(of: "reset_scene")
        observer.server("state", armState(graspArm, episode: 1))
        XCTAssertEqual(feltOnTarget, 2, "the new episode armed it")
        clock += 1000
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok"])
        observer.server("state", armState(graspArm, episode: 1))
        XCTAssertEqual(feltOnTarget, 2, "the answer to the same reset does not arm it again")
    }

    /// A state that does not say how the jaws are is neither open nor a close: it neither plays the cue nor arms it.
    func testAStateWithoutTheJawsLabelNeitherPlaysNorArmsTheCue() {
        bringUp()
        bringUpObserver(armState(graspArm + SIMD3(0, 0, 0.03), gripper: nil))
        observer.server("state", armState(graspArm, gripper: nil))
        XCTAssertEqual(feltOnTarget, 0, "the jaws may be shut")
        observer.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        observer.server("state", armState(graspArm, gripper: nil))
        clock += 1000
        observer.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1, "no close, no reset, never out of the window: once")
    }

    /// No task object reported: nothing to be on, wherever the jaws are.
    func testOnTargetIsNotFeltWithoutATarget() {
        bringUp()
        bringUpObserver(armState(graspArm + SIMD3(0, 0, 0.03), noObject: true))
        observer.server("state", armState(graspArm, noObject: true))
        XCTAssertNotNil(model.operating.arm)
        XCTAssertEqual(feltOnTarget, 0)
    }

    /// A new server run starts the scene over: its first state is a new approach, even with the jaws already open on
    /// the target. A reconnect to the same run is not.
    func testANewServerRunArmsTheCueOnItsFirstState() {
        makeModel(at: .p4)
        model.connect()
        transport.server("welcome", ["session": "run-1"])
        transport.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        model.connect()
        transport.server("welcome", ["session": "run-1"])
        transport.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1, "a reconnect to the same run")
        clock += 1000
        model.connect()
        transport.server("welcome", ["session": "run-2"])
        transport.server("state", armState(graspArm))
        XCTAssertEqual(feltOnTarget, 2, "a new run")
    }

    /// Practice draws no arm, and the closed link leaves its last state behind. Coming back to the real server is not a
    /// target reported anew: nothing is felt before the server says anything, nor when the same run says the jaws are
    /// still where they were.
    func testComingBackFromPracticeDoesNotReplayTheCueFromTheLastState() {
        bringUp()
        bringUpObserver(armState(graspArm))
        XCTAssertEqual(feltOnTarget, 1)
        clock += 1000
        model.startPractice()
        model.inputsChanged()
        model.leavePractice()
        model.inputsChanged()
        XCTAssertFalse(model.session.state.connected)
        XCTAssertEqual(feltOnTarget, 1, "nothing new from the server")
        transport.server("welcome")
        transport.server("state", armState(graspArm))
        XCTAssertTrue(model.session.state.connected)
        XCTAssertEqual(feltOnTarget, 1, "the same server run: the jaws did not move")
    }
}
