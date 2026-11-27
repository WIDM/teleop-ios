import simd
import TeleopCore
import XCTest

@testable import Teleop

/// The link controller with the other bases: the SO-101's, bench arm B's and an arm on its side, each through a fake
/// socket that sends real commands and reads the arm's state back. Every expectation is the SO-101's, carried through
/// the frames (`TestFrames.carry`): the same moves of the same arm seen by the same operator. A rule inside the
/// controller that takes base z as up, or the link's z as flipped, fails on B or on the arm on its side.
private final class FramesTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func receive(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let envelope: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!)
    }
    func messages(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
    var types: [String] { sent.map { $0["type"] as! String } }
}

final class LinkFramesTests: XCTestCase {
    private let so = TestProfiles.so101.frames
    private var wire: FramesTransport!
    private var model: AppModel!
    private var clock = 10_000
    private var phone: SIMD3<Float>? = .zero
    private var saved: [String: Any] = [:]
    private let keys = [AppModel.controlModeKey, AppModel.taskAidKey, AppModel.assistKey, AppModel.lockChoiceKey]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        model = nil
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    /// The SO-101's profile for an arm mounted as `frames` say: its base-frame places (tool offset, measured place,
    /// work box) carried to that base.
    private func profile(_ frames: Frames) -> RobotProfile {
        var p = TestProfiles.so101
        p.frames = frames
        p.toolOffset = TestFrames.carry(p.toolOffset, from: so, to: frames)
        p.offsetMeasuredAt = TestFrames.carry(p.offsetMeasuredAt, from: so, to: frames)
        let a = TestFrames.carry(p.workspaceMin, from: so, to: frames)
        let c = TestFrames.carry(p.workspaceMax, from: so, to: frames)
        p.workspaceMin = simd_min(a, c)
        p.workspaceMax = simd_max(a, c)
        return p
    }

    private func bringUp(_ frames: Frames, coordinated: Bool = false) {
        clock = 10_000
        phone = .zero
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        wire = FramesTransport()
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { [unowned self] in phone.map { TestPose.portrait(at: $0) } }, liveLink: true,
            makeTransport: { [unowned self] _ in wire }, makeObserverTransport: { _ in FramesTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            profile: profile(frames), assistOn: false, lockChoice: .off)
        model.controlMode = .screenTurns
        model.session.state.setSmoothing(0)
        model.session.state.sensitivity = 1
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        var welcome: [String: Any] = [:]
        if coordinated {
            welcome = [
                "control_points": ["link_origin", "tool"], "tool_calibration_id": "test-tool",
                "tool_motion_modes": ["coordinated_height"],
            ]
        }
        wire.receive("welcome", welcome)
    }

    private func carry(_ p: SIMD3<Double>, to frames: Frames) -> SIMD3<Double> {
        TestFrames.carry(p, from: so, to: frames)
    }

    private func lastDelta() throws -> SIMD3<Double> {
        let payload = try XCTUnwrap(wire.messages("pose_update").last?["payload"] as? [String: Any])
        let p = try XCTUnwrap(payload["p_rel_m"] as? [Double])
        return SIMD3(p[0], p[1], p[2])
    }

    private func assertEqual(
        _ a: SIMD3<Double>, _ expected: SIMD3<Double>, accuracy: Double, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            simd_distance(a, expected), 0, accuracy: accuracy, "\(a) is not \(expected): \(message)", file: file,
            line: line)
    }

    // MARK: A resync

    /// A hand that goes 12 cm right and 12 cm up in a third of a second asks for more than one server hold may, so the
    /// link ends the server hold to learn where the arm is. The arm went 10 cm right and 9 cm up; what is left, 2 cm
    /// right and 3 cm up, goes out as the next hold's offset, and the guide's commanded point is where the arm is plus
    /// that. Every one of these is the operator's right and up whichever base axis they lie along and however the link
    /// is signed.
    func testAResyncGoesOnFromWhereTheArmGotToOnEveryBase() throws {
        let start = SIMD3(0.0, 0.0, 0.1)
        for (name, frames) in TestFrames.all {
            bringUp(frames)
            let g0 = carry(start, to: frames)
            wire.receive("state", ["estop": false, "ee_pos": [g0.x, g0.y, g0.z], "gripper": "closed"])
            model.send(.holdArmStart)
            for step in 1...10 {
                phone = SIMD3(0.012 * Float(step), 0.012 * Float(step), 0)
                clock += 33
                model.link.tick()
            }
            XCTAssertTrue(model.catchingUp, name)
            // Asking for the limit, the way the hand went, in the link's frame.
            let capped = try lastDelta()
            assertEqual(
                capped, frames.linkOffset(right: 0.12, forward: 0, up: 0.12) / simd_length(SIMD3(0.12, 0, 0.12)) * 0.08,
                accuracy: 0.0005, "\(name): the limit, the way the hand went")

            for _ in 0..<50 {
                clock += 33
                model.link.tick()
                for message in wire.sent
                where message["type"] as? String == "test" && !answered.contains(message["seq"] as! Int) {
                    answered.insert(message["seq"] as! Int)
                    wire.receive("test", seq: message["seq"] as! Int)
                }
            }
            XCTAssertEqual(wire.types.last { $0 != "test" }, "pose_stop", "\(name): the link asks where the arm is")

            let arm = g0 + frames.base(fromOperator: SIMD3(0.10, 0, 0.09))
            let start = wire.messages("pose_start").last?["seq"] as! Int
            wire.receive("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
            wire.receive("state", ["estop": false, "ee_pos": [arm.x, arm.y, arm.z]])
            XCTAssertEqual(wire.types.last, "pose_start", "\(name): the hold goes on from there")
            clock += 33
            model.link.tick()
            assertEqual(
                try lastDelta(), frames.linkOffset(right: 0.02, forward: 0, up: 0.03), accuracy: 0.0005,
                "\(name): what is left, in the link's frame")
            let commanded = SIMD3<Double>(try XCTUnwrap(model.link.commandedArm))
            assertEqual(
                commanded, arm + frames.base(fromOperator: SIMD3(0.02, 0, 0.03)), accuracy: 0.001,
                "\(name): the guide's commanded point")
            model.link.endHold()
        }
    }

    private var answered = Set<Int>()

    // MARK: Coordinated height

    private func tool(_ frames: Frames, up rise: Double) -> [Double] {
        let p = carry(SIMD3(0.01, -0.17, 0.07), to: frames) + frames.base(fromOperator: SIMD3(0, 0, rise))
        return [p.x, p.y, p.z]
    }

    /// Holding up or down on coordinated height asks the server for height only: the offset has a part on the link axis
    /// that is up and none on the other two, signed as the link signs it. With the tool 1 mm further along each state,
    /// the offset asked for is what that travel was (progress, taken in the link's frame) plus the lead the hold may ask
    /// for, so a progress taken with the wrong sign for the axis shows in it.
    func testCoordinatedHeightAsksForHeightAlongUpInTheLinksSignOnEveryBase() throws {
        for (name, frames) in TestFrames.all {
            for (button, direction, sign) in [
                (ButtonID.down, OperatorDirection.down, -1.0), (ButtonID.up, OperatorDirection.up, 1.0),
            ] {
                bringUp(frames, coordinated: true)
                let origin = carry(SIMD3(0, -0.14, 0.16), to: frames)
                func state(_ rise: Double, ik: String = "pose_tracking") {
                    wire.receive(
                        "state",
                        [
                            "estop": false, "ik": ik, "gripper": "open",
                            "ee_pos": [origin.x, origin.y, origin.z], "tool_pos": tool(frames, up: rise),
                        ])
                }
                state(0, ik: "ok")
                model.surfaceChanged(width: 375, height: 667, safeTop: 20, safeBottom: 0)
                model.setPrecisionPanelOpen(true)
                model.buttonDown(button)
                let started = try XCTUnwrap(wire.messages("pose_start").last?["payload"] as? [String: Any])
                XCTAssertEqual(started["tool_motion"] as? String, "coordinated_height", "\(name) \(direction)")
                for index in 1...12 {
                    clock += 100
                    state(sign * 0.001 * Double(index))
                    model.controller.tick()
                    model.link.tick()
                }
                let delta = try lastDelta()
                let along = frames.linkVector(direction)
                let amount = simd_dot(delta, along)
                assertEqual(
                    delta, along * amount, accuracy: 1e-9, "\(name) \(direction): along the link's up axis only")
                XCTAssertGreaterThan(amount, 0.005, "\(name) \(direction): 12 mm of progress and the lead")
                XCTAssertLessThanOrEqual(amount, 0.0171, "\(name) \(direction)")
                XCTAssertEqual(wire.messages("pose_start").count, 1, "\(name) \(direction): one hold")
                model.buttonUp(button)
            }
        }
    }
}
