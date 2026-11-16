import Foundation
import XCTest
@testable import TeleopCore

/// Whether the link is keeping a start off the wire behind a control that is still finishing. While it is, the arm
/// cannot have moved for that start, so a move nobody holds must not take the arm standing still for a stall.
final class TeleopLinkHeldBackTests: XCTestCase {
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

    private func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": clock, "seq": seq, "payload": payload]
        _ = link.receive(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }

    private func bringUp() {
        link.hello(name: "test")
        server("welcome")
        server("state", ["estop": false, "gripper": "closed"])
    }

    /// The server's final ack for the control whose start had this seq.
    private func finish(_ startSeq: Int) {
        server("ack", seq: startSeq, ["seq": startSeq, "status": "ok", "reason": "done"])
    }

    private func seq(ofLast type: String) -> Int {
        sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    private let params = PoseParams(gain: 1, smoothing: 0.3)

    func testStartHeldBackIsTrueWhileAStartWaitsBehindAStop() {
        bringUp()
        XCTAssertFalse(link.startHeldBack)
        XCTAssertTrue(link.poseStart(params))
        XCTAssertFalse(link.startHeldBack, "nothing was finishing: the start went out at once")
        XCTAssertEqual(types.last, "pose_start")
        let first = seq(ofLast: "pose_start")

        link.poseStop()
        XCTAssertFalse(link.startHeldBack, "a stop holds nothing back by itself")
        XCTAssertTrue(link.poseStart(params))
        XCTAssertTrue(link.startHeldBack, "the new start waits for the stopped hold's final ack")
        XCTAssertEqual(types.suffix(2), ["pose_start", "pose_stop"])
        link.poseUpdate(positionMeters: [0.01, 0, 0])
        XCTAssertTrue(link.startHeldBack, "an update before the ack sends nothing and still waits")

        finish(first)
        XCTAssertFalse(link.startHeldBack, "the final ack sent it")
        XCTAssertEqual(types.last, "pose_start")

        // Any control's start waits the same way behind any control's stop.
        link.poseStop()
        XCTAssertTrue(link.orientStart())
        XCTAssertTrue(link.startHeldBack)
        finish(seq(ofLast: "pose_start"))
        XCTAssertFalse(link.startHeldBack)
        XCTAssertEqual(types.last, "orient_start")
    }

    /// It ends when the wait is over and the start goes out, and when the start is dropped before it went out: by its
    /// own stop, by a STOP, or with the socket.
    func testStartHeldBackEndsWhenTheWaitIsOverOrTheStartIsDropped() {
        bringUp()
        link.poseStart(params)
        link.poseStop()
        link.poseStart(params)
        XCTAssertTrue(link.startHeldBack)
        clock += TeleopLink.finishWaitMs - 1
        link.service()
        XCTAssertTrue(link.startHeldBack, "still inside the wait")
        clock += 1
        link.service()
        XCTAssertFalse(link.startHeldBack, "the wait is over: the start went out")
        XCTAssertEqual(types.last, "pose_start")

        link.poseStop()
        link.poseStart(params)
        XCTAssertTrue(link.startHeldBack)
        link.poseStop()
        XCTAssertFalse(link.startHeldBack, "stopped before it went out: nothing is held back")

        link.poseStart(params)
        XCTAssertTrue(link.startHeldBack)
        link.estop()
        XCTAssertFalse(link.startHeldBack, "a STOP drops it")

        link.poseStart(params)
        XCTAssertFalse(link.startHeldBack, "nothing is finishing after a STOP")
        link.poseStop()
        link.poseStart(params)
        XCTAssertTrue(link.startHeldBack)
        link.transportClosed()
        XCTAssertFalse(link.startHeldBack, "the socket is gone")
    }

    /// The control a stop ended stays unfinished until its final ack: not the stop's own ack, which comes first. A
    /// start held back for it that goes out after the wait ends it too, and a stop of a start that never went out sends
    /// nothing and leaves the stop before it as it was. The jaws' and the wrist's stops count like the arm's.
    func testUnfinishedStopIsTheStoppedControlUntilItsFinalAck() throws {
        bringUp()
        XCTAssertNil(link.unfinishedStop)
        link.poseStart(params)
        let first = seq(ofLast: "pose_start")
        XCTAssertNil(link.unfinishedStop, "a running hold is not stopped")
        clock += 500
        link.poseStop()
        let stopped = try XCTUnwrap(link.unfinishedStop)
        XCTAssertEqual(stopped.start, first)
        XCTAssertEqual(stopped.sentAtMs, clock)
        let stop = seq(ofLast: "pose_stop")
        server("ack", seq: stop, ["seq": stop, "status": "ok", "reason": "pose_stop_requested"])
        XCTAssertEqual(link.unfinishedStop?.start, first, "the stop's own ack: not finished yet")
        finish(first)
        XCTAssertNil(link.unfinishedStop, "the final ack")

        link.poseStart(params)
        let second = seq(ofLast: "pose_start")
        link.poseStop()
        link.poseStart(params)
        link.poseStop()
        XCTAssertEqual(link.unfinishedStop?.start, second, "a start that never went out stops nothing")
        link.poseStart(params)
        clock += TeleopLink.finishWaitMs
        link.service()
        XCTAssertEqual(types.last, "pose_start", "the wait is over")
        XCTAssertNil(link.unfinishedStop, "the start waiting for it went out")
        link.poseStop()

        for kind in ["gripper_jog_start", "orient_start"] {
            setUp()
            bringUp()
            if kind == "gripper_jog_start" { link.gripperJogStart(.closed) } else { link.orientStart() }
            let start = seq(ofLast: kind)
            if kind == "gripper_jog_start" { link.gripperJogStop() } else { link.orientStop() }
            XCTAssertEqual(link.unfinishedStop?.start, start, kind)
            finish(start)
            XCTAssertNil(link.unfinishedStop, kind)
        }
    }
}
