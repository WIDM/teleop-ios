import Foundation
import XCTest
@testable import TeleopCore

final class TeleopLinkTests: XCTestCase {
    private var sent: [[String: Any]] = []
    private var clock = 1000
    private var link: TeleopLink!

    override func setUp() {
        sent = []
        clock = 1000
        link = TeleopLink(
            send: { [unowned self] text in
                sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
            },
            now: { [unowned self] in clock }
        )
    }

    private var types: [String] { sent.map { $0["type"] as! String } }

    private func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) -> LinkEvent? {
        let message: [String: Any] = ["v": 1, "type": type, "ts": clock, "seq": seq, "payload": payload]
        return link.receive(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }

    private func bringUp(estop: Bool = false) {
        link.hello()
        _ = server("welcome")
        _ = server("state", ["estop": estop, "gripper": "closed"])
    }

    /// The server's final ack for a control it has finished: it names the control's start seq.
    @discardableResult
    private func finish(_ startSeq: Int, status: String = "ok") -> LinkEvent? {
        server("ack", seq: startSeq, ["seq": startSeq, "status": status, "reason": status == "ok" ? "done" : "busy"])
    }

    private var lastSeq: Int { sent.last!["seq"] as! Int }

    private func seq(ofLast type: String) -> Int {
        sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    private let params = PoseParams(gain: 1, deadbandDegrees: 2, smoothing: 0.3)

    func testHelloThenWelcomeAndStateMakesTheLinkReady() {
        link.hello()
        XCTAssertEqual(sent[0]["v"] as? Int, 1)
        XCTAssertEqual((sent[0]["payload"] as? [String: String])?["client"], "phone")
        XCTAssertNil(server("welcome"))
        XCTAssertFalse(link.ready)
        XCTAssertEqual(server("state", ["estop": false, "gripper": "closed"]), .up(estop: false, gripper: .closed))
        XCTAssertTrue(link.ready)
        XCTAssertEqual(server("state", ["estop": true, "gripper": "open"]), .state(estop: true, gripper: .open))
    }

    func testBothServerSpellingsOfAClosedGripperAreRead() {
        link.hello()
        _ = server("welcome")
        XCTAssertEqual(server("state", ["estop": false, "gripper": "close"]), .up(estop: false, gripper: .closed))
        XCTAssertEqual(server("state", ["estop": false, "gripper": "closed"]), .state(estop: false, gripper: .closed))
        XCTAssertEqual(server("state", ["estop": false, "gripper": "moving"]), .state(estop: false, gripper: nil))
    }

    func testStateBeforeWelcomeDoesNotMakeTheLinkReady() {
        XCTAssertNil(server("state", ["estop": false]))
        XCTAssertFalse(link.ready)
    }

    func testSeqStrictlyIncreases() {
        bringUp()
        link.poseStart(params)
        link.poseUpdate(positionMeters: [0, 0, 0])
        link.probe()
        link.poseStop()
        let seqs = sent.map { $0["seq"] as! Int }
        XCTAssertEqual(seqs, Array(1...seqs.count))
    }

    func testNothingMovesBeforeTheLinkIsReady() {
        XCTAssertFalse(link.poseStart(params))
        link.poseUpdate(positionMeters: [0.1, 0, 0])
        XCTAssertEqual(types, [])
    }

    func testHoldSendsStartUpdatesAndOneStop() {
        bringUp()
        XCTAssertTrue(link.poseStart(params))
        link.poseUpdate(positionMeters: [0.01234567, 0, -0.02])
        link.poseStop()
        link.poseStop()
        XCTAssertEqual(types, ["hello", "pose_start", "pose_update", "pose_stop"])
        let start = sent[1]["payload"] as! [String: Any]
        XCTAssertEqual(start["rate_hz"] as? Int, 30)
        XCTAssertEqual(start["control_mode"] as? String, "translation")
        XCTAssertEqual(Set(start.keys), ["frame", "rate_hz", "control_mode", "gain", "deadband_deg", "smoothing"])
        let update = sent[2]["payload"] as! [String: Any]
        XCTAssertEqual(Set(update.keys), ["p_rel_m", "q_rel", "gripper_delta"])
        XCTAssertEqual(update["p_rel_m"] as? [Double], [0.0123, 0, -0.02])
    }

    func testUpdatesAfterStopAreDropped() {
        bringUp()
        link.poseStart(params)
        link.poseStop()
        link.poseUpdate(positionMeters: [0.1, 0, 0])
        XCTAssertEqual(types.last, "pose_stop")
    }

    func testSecondStartWhileHeldIsRefused() {
        bringUp()
        XCTAssertTrue(link.poseStart(params))
        XCTAssertFalse(link.poseStart(params))
        XCTAssertEqual(types.filter { $0 == "pose_start" }.count, 1)
    }

    func testEstopEndsTheHold() {
        bringUp()
        link.poseStart(params)
        link.estop()
        link.poseUpdate(positionMeters: [0.1, 0, 0])
        XCTAssertEqual(types.suffix(2), ["pose_start", "estop"])
        XCTAssertFalse(link.holdActive)
    }

    func testResetSceneStopsTheHoldFirst() {
        bringUp()
        link.poseStart(params)
        link.resetScene()
        XCTAssertEqual(types.suffix(2), ["pose_stop", "reset_scene"])
    }

    func testClosedTransportDropsTheHoldAndReadiness() {
        bringUp()
        link.poseStart(params)
        link.transportClosed()
        XCTAssertFalse(link.ready)
        XCTAssertFalse(link.holdActive)
        XCTAssertFalse(link.poseStart(params))
    }

    func testRejectedStartEndsTheHold() {
        bringUp()
        link.poseStart(params)
        let seq = sent.last!["seq"] as! Int
        XCTAssertEqual(
            server("ack", seq: seq, ["seq": seq, "status": "rejected", "reason": "estop_active"]),
            .holdRefused(reason: "estop_active")
        )
        XCTAssertFalse(link.holdActive)
    }

    func testLateRefusalOfAnEarlierPressKeepsTheCurrentHold() {
        bringUp()
        link.poseStart(params)
        let first = sent.last!["seq"] as! Int
        link.poseStop()
        link.poseStart(params)
        XCTAssertEqual(
            server("ack", seq: first, ["seq": first, "status": "rejected", "reason": "busy"]),
            .rejected(type: "pose_start", reason: "busy")
        )
        XCTAssertTrue(link.holdActive)
        link.poseStop()
        XCTAssertEqual(types.last, "pose_stop")
    }

    func testProbeEchoesKeepAQuietHoldAlive() {
        bringUp()
        link.poseStart(params)
        // The real server sends no state while pose updates keep arriving.
        for _ in 0..<6 {
            link.probe()
            let seq = sent.last!["seq"] as! Int
            clock += 500
            _ = server("test", seq: seq)
            XCTAssertFalse(link.isStale)
        }
    }

    func testOkAckIsQuiet() {
        bringUp()
        link.estopReset()
        let seq = sent.last!["seq"] as! Int
        XCTAssertNil(server("ack", seq: seq, ["seq": seq, "status": "ok", "reason": "estop_reset"]))
    }

    func testGripperJogUsesTheServerActionNamesAndReplacesARunningJog() {
        bringUp()
        link.gripperJogStart(.closed)
        let first = lastSeq
        link.gripperJogStart(.open)
        XCTAssertEqual(types.suffix(2), ["gripper_jog_start", "gripper_jog_stop"])
        finish(first)
        XCTAssertEqual(types.suffix(3), ["gripper_jog_start", "gripper_jog_stop", "gripper_jog_start"])
        let starts = sent.filter { $0["type"] as? String == "gripper_jog_start" }.map { $0["payload"] as! [String: String] }
        XCTAssertEqual(starts.map { $0["action"] }, ["close", "open"])
        XCTAssertEqual(Set(starts[0].keys), ["action", "step"])
    }

    func testKeepaliveOnlyWhileTheGripperJogs() {
        bringUp()
        link.keepalive()
        XCTAssertEqual(types, ["hello"])
        link.gripperJogStart(.closed)
        link.keepalive()
        link.gripperJogStop()
        link.keepalive()
        link.gripperJogStop()
        XCTAssertEqual(types.suffix(3), ["gripper_jog_start", "jog_keepalive", "gripper_jog_stop"])
    }

    func testArmHoldStopsTheGripperJogFirst() {
        bringUp()
        link.gripperJogStart(.closed)
        let jog = lastSeq
        XCTAssertTrue(link.poseStart(params))
        XCTAssertEqual(types.suffix(2), ["gripper_jog_start", "gripper_jog_stop"])
        XCTAssertFalse(link.gripperJogActive)
        finish(jog)
        XCTAssertEqual(types.suffix(3), ["gripper_jog_start", "gripper_jog_stop", "pose_start"])
    }

    func testGripperJogIsRefusedDuringAnArmHold() {
        bringUp()
        link.poseStart(params)
        link.gripperJogStart(.closed)
        XCTAssertEqual(types.last, "pose_start")
    }

    func testRefusedGripperJogStopsKeepalives() {
        bringUp()
        link.gripperJogStart(.closed)
        let seq = sent.last!["seq"] as! Int
        _ = server("ack", seq: seq, ["seq": seq, "status": "rejected", "reason": "busy"])
        link.keepalive()
        XCTAssertEqual(types.last, "gripper_jog_start")
    }

    func testEstopEndsTheGripperJog() {
        bringUp()
        link.gripperJogStart(.closed)
        link.estop()
        link.keepalive()
        XCTAssertEqual(types.last, "estop")
    }

    private func qRel(_ message: [String: Any]) -> [Double] {
        (message["payload"] as! [String: Any])["q_rel"] as! [Double]
    }

    func testOrientStartSendsExactlyTheServerPayload() {
        bringUp()
        XCTAssertTrue(link.orientStart())
        let message = sent.last!
        XCTAssertEqual(message["type"] as? String, "orient_start")
        let payload = message["payload"] as! [String: Any]
        XCTAssertEqual(Set(payload.keys), ["frame", "rate_hz", "gain", "deadband_deg", "smoothing"])
        XCTAssertEqual(payload["frame"] as? String, "phone_body")
        XCTAssertEqual(payload["rate_hz"] as? Int, 30)
        XCTAssertEqual(payload["gain"] as? Double, 1.0)
        XCTAssertEqual(payload["deadband_deg"] as? Double, 0.0)
        XCTAssertEqual(payload["smoothing"] as? Double, 0.0)
        XCTAssertTrue(link.turnActive)
    }

    func testOrientUpdateRollsAboutYWithTheServersSign() throws {
        bringUp()
        link.orientStart()
        link.orientUpdate(rollDegrees: 0)
        XCTAssertEqual(qRel(sent.last!), [0, 0, 0, 1])
        link.orientUpdate(rollDegrees: 30)
        var q = qRel(sent.last!)
        XCTAssertEqual(q[0], 0)
        XCTAssertEqual(q[2], 0)
        XCTAssertEqual(q[1], -sin(15 * Double.pi / 180), accuracy: 1e-6)
        XCTAssertEqual(q[3], cos(15 * Double.pi / 180), accuracy: 1e-6)
        link.orientUpdate(rollDegrees: -55)
        q = qRel(sent.last!)
        XCTAssertEqual(q[1], sin(27.5 * Double.pi / 180), accuracy: 1e-6)
        XCTAssertEqual(sqrt(q.map { $0 * $0 }.reduce(0, +)), 1, accuracy: 1e-5)
        XCTAssertEqual(Set((sent.last!["payload"] as! [String: Any]).keys), ["q_rel"])
    }

    func testOrientUpdateIsNotRememberedAndIsDroppedOutsideATurn() {
        bringUp()
        link.orientUpdate(rollDegrees: 10)
        XCTAssertFalse(types.contains("orient_update"))
        link.orientStart()
        link.orientUpdate(rollDegrees: .nan)
        XCTAssertFalse(types.contains("orient_update"))
        link.orientUpdate(rollDegrees: 10)
        let seq = sent.last!["seq"] as! Int
        XCTAssertNil(server("ack", seq: seq, ["seq": seq, "status": "rejected", "reason": "x"]))
    }

    func testOrientStopEndsTheTurnAndTheAckOfItsStartReportsNothing() {
        bringUp()
        link.orientStart()
        let seq = sent.last!["seq"] as! Int
        link.orientStop()
        link.orientStop()
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        XCTAssertEqual((sent.last!["payload"] as! [String: Any]).count, 0)
        XCTAssertFalse(link.turnActive)
        link.orientUpdate(rollDegrees: 10)
        XCTAssertEqual(types.last, "orient_stop")
        XCTAssertNil(server("ack", seq: seq, ["seq": seq, "status": "accepted"]))
    }

    func testOrientIsNotSentBeforeReadyOrDuringAnArmHold() {
        XCTAssertFalse(link.orientStart())
        bringUp()
        link.poseStart(params)
        XCTAssertFalse(link.orientStart())
        XCTAssertFalse(types.contains("orient_start"))
    }

    func testArmHoldAndGripperJogStopTheTurnFirst() {
        bringUp()
        link.orientStart()
        let turn = lastSeq
        XCTAssertTrue(link.poseStart(params))
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        XCTAssertFalse(link.turnActive)
        finish(turn)
        XCTAssertEqual(types.suffix(3), ["orient_start", "orient_stop", "pose_start"])

        link.poseStop()
        finish(seq(ofLast: "pose_start"))
        link.orientStart()
        let second = lastSeq
        link.gripperJogStart(.open)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        XCTAssertFalse(link.turnActive)
        finish(second)
        XCTAssertEqual(types.suffix(3), ["orient_start", "orient_stop", "gripper_jog_start"])
    }

    func testTurnStopsAGripperJogAndReplacesARunningTurn() {
        bringUp()
        link.gripperJogStart(.closed)
        let jog = lastSeq
        link.orientStart()
        XCTAssertEqual(types.suffix(2), ["gripper_jog_start", "gripper_jog_stop"])
        XCTAssertFalse(link.gripperJogActive)
        finish(jog)
        XCTAssertEqual(types.suffix(3), ["gripper_jog_start", "gripper_jog_stop", "orient_start"])
        let turn = lastSeq
        link.orientStart()
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        finish(turn)
        XCTAssertEqual(types.suffix(3), ["orient_start", "orient_stop", "orient_start"])
    }

    func testEstopResetSceneAndClosedTransportEndTheTurn() {
        bringUp()
        link.orientStart()
        link.estop()
        XCTAssertFalse(link.turnActive)
        link.orientUpdate(rollDegrees: 5)
        XCTAssertEqual(types.last, "estop")

        link.orientStart()
        link.resetScene()
        XCTAssertEqual(types.suffix(2), ["orient_stop", "reset_scene"])

        link.orientStart()
        link.transportClosed()
        XCTAssertFalse(link.turnActive)
        XCTAssertFalse(link.orientStart())
    }

    func testRefusedTurnIsReportedAsItsOwnEventAndStopsUpdates() {
        bringUp()
        link.orientStart()
        let seq = sent.last!["seq"] as! Int
        XCTAssertEqual(
            server("ack", seq: seq, ["seq": seq, "status": "rejected", "reason": "busy"]),
            .turnRefused(reason: "busy")
        )
        XCTAssertFalse(link.turnActive)
        link.orientUpdate(rollDegrees: 5)
        XCTAssertEqual(types.last, "orient_start")
    }

    func testLateRefusalOfAnEarlierTurnKeepsTheCurrentOne() {
        bringUp()
        link.orientStart()
        let first = sent.last!["seq"] as! Int
        link.orientStop()
        link.orientStart()
        XCTAssertEqual(
            server("ack", seq: first, ["seq": first, "status": "rejected", "reason": "busy"]),
            .rejected(type: "orient_start", reason: "busy")
        )
        XCTAssertTrue(link.turnActive)
    }

    func testRefusalOfAnArmHoldDoesNotEndATurnAndTheOtherWayAround() {
        bringUp()
        link.poseStart(params)
        let hold = sent.last!["seq"] as! Int
        link.poseStop()
        link.orientStart()
        XCTAssertEqual(
            server("ack", seq: hold, ["seq": hold, "status": "rejected", "reason": "busy"]),
            .rejected(type: "pose_start", reason: "busy")
        )
        XCTAssertTrue(link.turnActive)
    }

    func testNewTurnWaitsForTheFinalAckOfTheOldOne() {
        bringUp()
        link.orientStart()
        let first = lastSeq
        link.orientStop()
        link.orientStart()
        XCTAssertTrue(link.turnActive)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        link.orientUpdate(rollDegrees: 10)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        XCTAssertNil(finish(first))
        XCTAssertEqual(types.suffix(3), ["orient_start", "orient_stop", "orient_start"])
        link.orientUpdate(rollDegrees: 10)
        XCTAssertEqual(types.last, "orient_update")
    }

    func testARejectedFinalAckAlsoReleasesTheHeldBackStart() {
        bringUp()
        link.gripperJogStart(.closed)
        let first = lastSeq
        link.gripperJogStop()
        link.gripperJogStart(.open)
        XCTAssertEqual(types.last, "gripper_jog_stop")
        XCTAssertEqual(finish(first, status: "rejected"), .rejected(type: "gripper_jog_start", reason: "busy"))
        XCTAssertEqual(types.last, "gripper_jog_start")
        XCTAssertEqual((sent.last!["payload"] as! [String: String])["action"], "open")
        XCTAssertTrue(link.gripperJogActive)
    }

    func testStartAfterAnAckedStopGoesOutAtOnce() {
        bringUp()
        link.orientStart()
        let first = lastSeq
        link.orientStop()
        finish(first)
        link.orientStart()
        XCTAssertEqual(types.suffix(3), ["orient_start", "orient_stop", "orient_start"])
    }

    func testHeldBackStartGoesOutAfterEightHundredMillisecondsOnTheNextUpdate() {
        bringUp()
        link.orientStart()
        link.orientStop()
        link.orientStart()
        clock += TeleopLink.finishWaitMs - 1
        link.orientUpdate(rollDegrees: 10)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        clock += 1
        link.orientUpdate(rollDegrees: 10)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_update"])
        XCTAssertEqual(types.filter { $0 == "orient_start" }.count, 2)
    }

    func testTheWaitIsTimedFromTheStopAndAHeldBackGripperStartIsReleasedByKeepalive() {
        bringUp()
        link.orientStart()
        link.orientStop()
        clock += 900
        link.gripperJogStart(.open)
        XCTAssertEqual(types.last, "gripper_jog_start")

        link.gripperJogStop()
        link.gripperJogStart(.closed)
        link.keepalive()
        XCTAssertEqual(types.suffix(2), ["gripper_jog_start", "gripper_jog_stop"])
        clock += TeleopLink.finishWaitMs
        link.keepalive()
        XCTAssertEqual(types.suffix(2), ["gripper_jog_start", "jog_keepalive"])
    }

    func testHeldBackArmHoldSendsNothingUntilItsStartGoesOut() {
        bringUp()
        link.orientStart()
        let turn = lastSeq
        link.orientStop()
        XCTAssertTrue(link.poseStart(params))
        XCTAssertTrue(link.holdActive)
        XCTAssertFalse(link.poseStart(params))
        link.poseUpdate(positionMeters: [0.01, 0, 0])
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        finish(turn)
        link.poseUpdate(positionMeters: [0.01, 0, 0])
        XCTAssertEqual(types.suffix(2), ["pose_start", "pose_update"])
    }

    func testStoppingAHeldBackStartSendsNothingAtAll() {
        bringUp()
        link.orientStart()
        let turn = lastSeq
        link.orientStop()
        link.orientStart()
        link.orientStop()
        XCTAssertFalse(link.turnActive)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        XCTAssertEqual(types.count, 3)
        finish(turn)
        XCTAssertEqual(types.count, 3)
        clock += 5000
        link.orientUpdate(rollDegrees: 10)
        XCTAssertEqual(types.count, 3)

        link.poseStart(params)
        link.poseStop()
        link.poseStart(params)
        link.poseStop()
        XCTAssertEqual(types.suffix(2), ["pose_start", "pose_stop"])
        XCTAssertEqual(types.count, 5)
        link.gripperJogStart(.open)
        link.gripperJogStop()
        XCTAssertEqual(types.count, 5)
    }

    func testStopsAreSentForAStartThatWasOnTheWireEvenWhileAnotherIsHeldBack() {
        bringUp()
        link.orientStart()
        let turn = lastSeq
        link.orientStop()
        link.gripperJogStart(.open)
        link.poseStart(params)
        XCTAssertFalse(link.gripperJogActive)
        XCTAssertEqual(types.suffix(2), ["orient_start", "orient_stop"])
        finish(turn)
        XCTAssertEqual(types.suffix(2), ["orient_stop", "pose_start"])
        XCTAssertEqual(types.filter { $0 == "gripper_jog_start" }.count, 0)
    }

    func testAnAckOfAnOlderSeqDoesNotReleaseTheHeldBackStart() {
        bringUp()
        link.gripperJogStart(.closed)
        let jog = lastSeq
        link.gripperJogStop()
        link.orientStart()
        link.orientStop()
        XCTAssertEqual(types.last, "gripper_jog_stop")
        // The jog is the only control that was on the wire; the turn start never was. An unrelated seq changes nothing.
        XCTAssertNil(finish(jog + 100))
        XCTAssertEqual(types.last, "gripper_jog_stop")
        link.orientStart()
        XCTAssertEqual(types.last, "gripper_jog_stop")
        XCTAssertNil(finish(jog))
        XCTAssertEqual(types.last, "orient_start")
    }

    func testALateFinalAckAfterTheWaitReleasesNothingThatBelongsToALaterStop() {
        bringUp()
        link.orientStart()
        let first = lastSeq
        link.orientStop()
        link.orientStart()
        clock += TeleopLink.finishWaitMs
        link.orientUpdate(rollDegrees: 1)
        let second = lastSeq - 1
        XCTAssertEqual(sent[sent.count - 2]["type"] as? String, "orient_start")
        XCTAssertEqual(second, sent[sent.count - 2]["seq"] as! Int)
        link.orientStop()
        link.gripperJogStart(.open)
        XCTAssertEqual(types.last, "orient_stop")
        XCTAssertNil(finish(first))
        XCTAssertEqual(types.last, "orient_stop")
        XCTAssertNil(finish(second))
        XCTAssertEqual(types.last, "gripper_jog_start")
    }

    func testEstopDropsTheHeldBackStartAndThePendingAck() {
        bringUp()
        link.orientStart()
        let turn = lastSeq
        link.orientStop()
        link.orientStart()
        link.estop()
        XCTAssertFalse(link.turnActive)
        finish(turn)
        link.orientUpdate(rollDegrees: 5)
        XCTAssertEqual(types.suffix(2), ["orient_stop", "estop"])
        clock += 5000
        link.orientUpdate(rollDegrees: 5)
        XCTAssertEqual(types.last, "estop")
        // Nothing is pending any more, so a new start is not held back.
        link.orientStart()
        XCTAssertEqual(types.last, "orient_start")
    }

    func testResetSceneDropsTheHeldBackStartAndThePendingAck() {
        bringUp()
        link.gripperJogStart(.open)
        link.gripperJogStop()
        link.orientStart()
        link.resetScene()
        XCTAssertEqual(types.last, "reset_scene")
        XCTAssertFalse(link.turnActive)
        link.orientStart()
        XCTAssertEqual(types.last, "orient_start")
    }

    func testClosedTransportDropsTheHeldBackStartAndThePendingAck() {
        bringUp()
        link.orientStart()
        link.orientStop()
        link.orientStart()
        link.transportClosed()
        let count = sent.count
        clock += 5000
        link.orientUpdate(rollDegrees: 5)
        XCTAssertEqual(sent.count, count)
        bringUp()
        link.orientStart()
        XCTAssertEqual(types.last, "orient_start")
    }

    func testTheResyncStopStillReportsHoldStoppedAndTheNextHoldGoesOutAtOnce() {
        bringUp()
        link.poseStart(params)
        let hold = lastSeq
        link.poseStop()
        XCTAssertEqual(finish(hold), .holdStopped)
        XCTAssertTrue(link.poseStart(params))
        XCTAssertEqual(types.suffix(3), ["pose_start", "pose_stop", "pose_start"])
    }

    func testOnlyAnArmHoldsFinalAckReportsHoldStopped() {
        bringUp()
        link.gripperJogStart(.closed)
        let jog = lastSeq
        link.gripperJogStop()
        XCTAssertNil(finish(jog))
        link.orientStart()
        let turn = lastSeq
        link.orientStop()
        XCTAssertNil(finish(turn))
    }

    func testProbeMeasuresTheRoundTrip() {
        bringUp()
        link.probe()
        let seq = sent.last!["seq"] as! Int
        clock += 87
        XCTAssertEqual(server("test", seq: seq), .latency(ms: 87))
        XCTAssertNil(server("test", seq: seq))
    }

    func testDroppedProbesAreNotMeasuredLater() {
        bringUp()
        link.probe()
        let seq = sent.last!["seq"] as! Int
        link.dropProbes()
        clock += 9000
        XCTAssertNil(server("test", seq: seq))
    }

    func testSilentServerGoesStale() {
        bringUp()
        clock += TeleopLink.staleAfterMs
        XCTAssertFalse(link.isStale)
        clock += 1
        XCTAssertTrue(link.isStale)
        _ = server("state", ["estop": false])
        XCTAssertFalse(link.isStale)
    }

    func testPoseParamsAreClampedToServerRanges() {
        let params = PoseParams(gain: 5, deadbandDegrees: -1, smoothing: 1)
        XCTAssertEqual(params, PoseParams(gain: 2, deadbandDegrees: 0, smoothing: 0.95))
    }

    func testGarbageIsIgnored() {
        XCTAssertNil(link.receive("not json"))
        XCTAssertNil(link.receive("{\"type\":7}"))
    }
}
