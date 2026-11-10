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

    func testGripperUsesTheServerActionNames() {
        bringUp()
        link.gripper(.closed)
        link.gripper(.open)
        XCTAssertEqual(sent.suffix(2).map { ($0["payload"] as! [String: String])["action"] }, ["close", "open"])
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
