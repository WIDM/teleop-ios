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
}
