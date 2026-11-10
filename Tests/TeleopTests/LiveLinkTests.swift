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
    private var position: SIMD3<Float>? = .zero
    private var clock = 10_000
    private var model: AppModel!

    private func makeModel(at route: Route) {
        transports = []
        position = .zero
        clock = 10_000
        model = AppModel(
            start: route,
            haptics: NoHaptics(),
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
            nowMs: { [unowned self] in clock }
        )
        model.session.state.serverAddress = "100.64.0.1:8765"
        // Exact offsets in these tests; smoothing has its own test.
        model.session.state.setSmoothing(0)
    }

    /// Standby with the link up and tracking.
    private func bringUp(estop: Bool = false) {
        makeModel(at: .p4)
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": estop, "gripper": "closed"])
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
        model.session.state.serverAddress = "192.168.x.x:8765 oops"
        model.connect()
        XCTAssertTrue(model.session.state.serverInputError)
        XCTAssertTrue(transports.isEmpty)
    }

    func testAddressForms() {
        XCTAssertEqual(LiveLinkController.url(from: "100.64.0.1")?.absoluteString, "ws://100.64.0.1:8765")
        XCTAssertEqual(LiveLinkController.url(from: " mac.local:9000 ")?.absoluteString, "ws://mac.local:9000")
        XCTAssertEqual(LiveLinkController.url(from: "wss://host:1")?.absoluteString, "wss://host:1")
        XCTAssertNil(LiveLinkController.url(from: ""))
        XCTAssertNil(LiveLinkController.url(from: "http://host"))
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
        transport.server("state", ["estop": true])
        let sentAtEstop = transport.sent.count
        position = SIMD3(0.001, 0, 0)
        tick()
        XCTAssertFalse(transport.types.dropFirst(sentAtEstop).contains("pose_update"))
        model.send(.releaseStop)
        transport.server("state", ["estop": false])
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

    func testSocketCloseDuringAHoldStopsAndShowsErrors() {
        bringUp()
        model.send(.holdArmStart)
        transport.onClose?()
        XCTAssertFalse(model.session.state.connected)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(model.session.route, .s7)
        XCTAssertFalse(model.link.isOpen)
    }

    func testSilentServerCountsAsLost() {
        bringUp()
        clock += TeleopLink.staleAfterMs + 1
        model.link.tick()
        XCTAssertFalse(model.session.state.connected)
        XCTAssertEqual(model.session.route, .s7)
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
        model.send(.gripperStart(.open))
        XCTAssertEqual(transport.types.suffix(3), ["gripper_jog_start", "gripper_jog_stop", "gripper_jog_start"])
        XCTAssertEqual(model.session.state.gripperMoving, .open)
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
        model.send(.holdArmStart)
        XCTAssertEqual(transport.types.suffix(2), ["gripper_jog_stop", "pose_start"])
        run(ticks: 200)
        XCTAssertEqual(transport.types.filter { $0 == "gripper_jog_stop" }.count, 1)
        XCTAssertFalse(transport.types.contains("jog_keepalive"))
    }

    func testHoldOffsetIsShownAsRightForwardUpAndClearedOnRelease() {
        bringUp()
        XCTAssertNil(model.holdOffset)
        model.send(.holdArmStart)
        position = SIMD3(0.01, 0.005, -0.02)
        tick()
        let shown = try! XCTUnwrap(model.holdOffset)
        XCTAssertLessThan(simd_distance(shown, SIMD3(0.01, 0.02, 0.005)), 0.0001, "\(shown)")
        model.send(.holdArmEnd)
        XCTAssertNil(model.holdOffset)
    }

    func testHoldOffsetIsClearedWhenTheHoldEndsByItself() {
        bringUp()
        model.send(.holdArmStart)
        tick()
        XCTAssertNotNil(model.holdOffset)
        model.send(.stop)
        XCTAssertNil(model.holdOffset)
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
        // The readout shows the whole move so far: 3 cm done plus 8 cm asked.
        XCTAssertEqual(model.holdOffset!.x, 0.11, accuracy: 0.001)
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

    private let sceneState: [String: Any] = [
        "estop": false, "gripper": "open", "ee_pos": [0.021, -0.141, 0.160],
        "object_pos": [0.005, -0.200, 0.1025], "goal_pos": [0.075, -0.200, 0.1035],
    ]

    func testGuidanceAppearsOnceTheServerSaysWhereThingsAre() {
        bringUp()
        XCTAssertNil(model.guidance, "the first state had no positions")
        transport.server("state", sceneState)
        XCTAssertEqual(model.guidance?.target, .cube)
        XCTAssertEqual(model.guidance!.offset.y, 0.059, accuracy: 0.001)
    }

    func testGuidanceFollowsTheCommandDuringAHold() {
        bringUp()
        transport.server("state", sceneState)
        model.send(.holdArmStart)
        // 3 cm forward: 5.9 cm to the cube becomes 2.9 cm.
        for step in 1...3 {
            position = SIMD3(0, 0, -0.01 * Float(step))
            tick()
        }
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(model.guidance!.offset.y, 0.029, accuracy: 0.001)
        XCTAssertEqual(model.guidance!.offset.x, 0.016, accuracy: 0.001)
    }

    func testArmThatDoesNotMoveIsReportedAtTheEdge() {
        bringUp()
        transport.server("state", sceneState)
        model.send(.holdArmStart)
        for step in 1...10 {
            position = SIMD3(0.02 * Float(step), 0, 0)
            tick()
        }
        run(ticks: 50)
        XCTAssertFalse(model.guidance?.atEdge ?? false)
        // The server finished the hold and the arm is where it started.
        let start = transport.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        transport.server("state", sceneState)
        tick()
        XCTAssertTrue(model.guidance!.atEdge)
        model.send(.holdArmEnd)
        transport.server("state", sceneState)
        XCTAssertFalse(model.guidance!.atEdge, "the warning belongs to the hold that hit the edge")
    }

    func testGuidanceGoesWhenTheLinkDoes() {
        bringUp()
        transport.server("state", sceneState)
        model.send(.switchMode)
        XCTAssertNil(model.guidance)
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
        XCTAssertNil(model.holdOffset)
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
        XCTAssertEqual(model.session.route, .s7)
    }

    func testSwitchModeClosesTheSocket() {
        bringUp()
        model.send(.switchMode)
        XCTAssertTrue(transport.closed)
        XCTAssertFalse(model.session.state.connected)
    }

    func testEnteringASessionTriesTheSavedServer() {
        makeModel(at: .p1)
        model.send(.modeNext)
        XCTAssertEqual(transports.count, 1)
        XCTAssertFalse(model.session.state.connected)
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
}
