import XCTest
@testable import TeleopServerModel

/// The envelope rules every message goes through before any command rule.
final class ProtocolTests: XCTestCase {
    private var bench: Bench!

    override func setUp() {
        bench = Bench()
    }

    func testHelloComesFirstAndIsAnsweredWithWelcomeAndState() {
        let phone = bench.client(hello: false)
        phone.send("estop")
        XCTAssertEqual(phone.received.map(\.type), ["error"])
        XCTAssertEqual(phone.received.last?.payload["code"], "hello_required")
        phone.send("hello", .object(["client": "phone", "name": "bench"]))
        XCTAssertEqual(phone.received.suffix(2).map(\.type), ["welcome", "state"])
        XCTAssertEqual(phone.received.suffix(2).first?.payload["config"], .object(["coarse_cm": 2.0, "fine_cm": 0.5]))
    }

    func testARepeatedOrOlderSeqIsDroppedSilently() {
        let phone = bench.client()
        let message = JSONValue.object(["v": 1, "type": "estop", "ts": 0, "seq": 1, "payload": .object([])])
        let before = phone.received.count
        phone.sendText(message.text)
        XCTAssertEqual(phone.received.count, before, "seq 1 was the hello")
    }

    func testTheVersionIsFixedByTheFirstMessage() {
        let phone = bench.client()
        phone.sendText(JSONValue.object(["v": 0, "type": "estop", "ts": 0, "seq": 5, "payload": .object([])]).text)
        XCTAssertEqual(phone.received.last?.payload["code"], "version_changed")
    }

    func testRepliesBeforeAnyValidMessageUseVersionZero() {
        let phone = bench.client(hello: false)
        phone.sendText("{not json")
        XCTAssertEqual(phone.received.last?.message["v"], 0)
        XCTAssertEqual(phone.received.last?.message["seq"], -1)
        XCTAssertEqual(phone.received.last?.payload["code"], "invalid_json")
    }

    func testATestMessageIsEchoedByteForByte() {
        let phone = bench.client()
        let text = #"{"v":1,"type":"test","ts":12,"seq":9,"payload":{"anything":[1,2.50]}}"#
        phone.sendText(text)
        XCTAssertEqual(phone.received.last?.text, text)
    }

    func testIntegersAndRealNumbersAreToldApart() {
        let phone = bench.client()
        let start = phone.send("jog_start", .object(["axis": "x", "dir": 1.0, "step": "fine"]))
        XCTAssertEqual(phone.reason(start), "rejected jog_invalid_dir")
        let rate = phone.send(
            "orient_start",
            .object([
                "frame": "phone_body", "rate_hz": 30.0, "gain": 1, "deadband_deg": 0, "smoothing": 0,
            ]))
        XCTAssertEqual(phone.reason(rate), "rejected invalid_orient_rate")
    }

    func testMalformedUpdatesAreAnsweredWithAnError() {
        let phone = bench.client()
        phone.send(
            "pose_update",
            .object(["p_rel_m": .numbers([0, 0]), "q_rel": .numbers([0, 0, 0, 1]), "gripper_delta": 0]))
        XCTAssertEqual(phone.received.last?.payload["code"], "invalid_pose_position")
        phone.send("orient_update", .object(["q_rel": .numbers([0, 0, 0, 2])]))
        XCTAssertEqual(phone.received.last?.payload["code"], "invalid_orient_quaternion")
    }

    func testJSONRoundTripsKeepTypesAndOrder() {
        let text = #"{"b": 1, "a": [1.5, true, null, "x\"y"], "c": {"n": -0.0}, "d": 1e-05}"#
        let value = JSONValue.parse(text)
        XCTAssertEqual(value?.text, #"{"b": 1, "a": [1.5, true, null, "x\"y"], "c": {"n": -0.0}, "d": 1e-05}"#)
        XCTAssertEqual(value?["b"], .int(1))
        XCTAssertNil(JSONValue.parse("[1,]"))
        XCTAssertNil(JSONValue.parse("01"))
        XCTAssertEqual(JSONValue.parse("NaN")?.numberValue?.isNaN, true, "Python's json accepts NaN")
    }
}
