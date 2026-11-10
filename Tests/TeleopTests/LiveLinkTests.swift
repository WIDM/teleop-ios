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
                    var m = matrix_identity_float4x4
                    m.columns.3 = SIMD4(p.x, p.y, p.z, 1)
                    return m
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
        XCTAssertEqual(update["p_rel_m"] as? [Double], [0.01, 0, -0.02])
    }

    func testOffsetIsMeasuredFromWhereTheHoldBegan() {
        bringUp()
        position = SIMD3(1, 2, 3)
        model.send(.holdArmStart)
        position = SIMD3(1, 2.01, 3)
        tick()
        let update = transport.sent.last!["payload"] as! [String: Any]
        XCTAssertEqual(update["p_rel_m"] as? [Double], [0, 0.01, 0])
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

    func testGripperToggleSendsTheNewState() {
        bringUp()
        model.send(.toggleGripper)
        XCTAssertEqual(model.session.state.gripper, .open)
        XCTAssertEqual((transport.sent.last!["payload"] as! [String: String])["action"], "open")
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
