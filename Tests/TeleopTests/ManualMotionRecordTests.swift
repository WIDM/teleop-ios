import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class MotionRecordTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []

    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

final class ManualMotionRecordTests: XCTestCase {
    private struct Run {
        var wire: [String]
        var records: [(Int, String)]
    }

    private func run(record: Bool, direction: Float) -> Run {
        let transport = MotionRecordTransport()
        var position = SIMD3<Float>.zero
        var clock = 10_000
        var records: [(Int, String)] = []
        let model = AppModel(
            start: .p4, haptics: SpyHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { TestPose.portrait(at: position) }, liveLink: true,
            makeTransport: { _ in transport }, makeObserverTransport: { _ in MotionRecordTransport() },
            nowMs: { clock }, inputClock: { Double(clock) / 1000 },
            clientName: "teleop-motion-test", assistOn: false, lockChoice: .off)
        let savedMode = UserDefaults.standard.object(forKey: AppModel.controlModeKey)
        defer { UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey) }
        model.controlMode = .screenTurns
        model.session.state.setSmoothing(0)
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        transport.server("welcome")
        let state: [String: Any] = ["estop": false, "gripper": "open", "ee_pos": [0.0, 0.0, 0.15]]
        transport.server("state", state)
        model.link.onLog = record ? { if $0.hasPrefix("motion ") { records.append((clock, $0)) } } : nil
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving)
        var answered = transport.sent.count
        var stoppedAt: Int?
        for index in 0..<180 {
            clock += 33
            position.y = direction * min(Float(index) * 0.002, 0.16)
            model.link.tick()
            for message in Array(transport.sent.dropFirst(answered)) {
                if message["type"] as? String == "test" {
                    transport.server("test", seq: message["seq"] as! Int)
                }
                if message["type"] as? String == "pose_stop" { stoppedAt = clock }
            }
            answered = transport.sent.count
            if let stopped = stoppedAt, clock - stopped >= 1100 {
                let start = transport.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
                transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
                transport.server("state", state)
                stoppedAt = nil
            }
        }
        model.keyEvent(.upper, down: false)
        let recordCount = records.count
        for _ in 0..<40 {
            clock += 33
            model.link.tick()
        }
        XCTAssertEqual(records.count, recordCount, "Idle ticks do not record motion")
        let wire = transport.sent.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), encoding: .utf8)!
        }
        model.link.closeQuietly()
        return Run(wire: wire, records: records)
    }

    private func gripRun(record: Bool, gripper: GripperProfile = TestProfiles.so101.gripper) -> Run {
        let transport = MotionRecordTransport()
        var clock = 10_000
        var records: [(Int, String)] = []
        var profile = TestProfiles.so101
        profile.gripper = gripper
        let link = LiveLinkController(
            makeTransport: { _ in transport }, makeObserverTransport: { _ in MotionRecordTransport() },
            pose: { nil }, nowMs: { clock }, profile: profile, clientName: "teleop-grip-record-test")
        XCTAssertTrue(link.connect(to: "127.0.0.1:8765"))
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "open", "ee_pos": [0.0, 0.0, 0.15]])
        link.onLog = record ? { if $0.hasPrefix("grip ") { records.append((clock, $0)) } } : nil
        XCTAssertTrue(link.startGripper(.closed))
        for index in 0..<75 {
            clock += 33
            transport.server(
                "state",
                [
                    "estop": false, "ik": "gripper_jogging", "gripper_deg": 40.0 - Double(index) * 0.1,
                    "wrist_flex_deg": 40.0, "wrist_roll_deg": 3.0, "tool_pos": [0.01, -0.1, 0.05],
                ])
            link.tick()
            if let probe = transport.sent.last(where: { $0["type"] as? String == "test" }) {
                transport.server("test", seq: probe["seq"] as! Int)
            }
        }
        link.stopGripper()
        let count = records.count
        for _ in 0..<40 {
            clock += 33
            link.tick()
        }
        XCTAssertEqual(records.count, count)
        let wire = transport.sent.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), encoding: .utf8)!
        }
        link.closeQuietly()
        return Run(wire: wire, records: records)
    }

    func testGripRecordsMeasuredJointsAndToolWithoutChangingCommands() {
        let quiet = gripRun(record: false)
        let recorded = gripRun(record: true)
        XCTAssertEqual(recorded.wire, quiet.wire)
        XCTAssertGreaterThanOrEqual(recorded.records.count, 2)
        for (before, after) in zip(recorded.records, recorded.records.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.0 - before.0, 1000)
        }
        XCTAssertTrue(
            recorded.records.allSatisfy {
                $0.1.contains("tool_base=[0.0100,-0.1000,0.0500]")
                    && $0.1.contains("wrist_flex_deg=40.0000 wrist_roll_deg=3.0000")
                    && $0.1.contains("jaw_deg=") && $0.1.contains("server_activity=gripperJogging")
            })
    }

    /// The session record writes the jaw reading under the field's name and says what it is measured in: the SO-101's
    /// degrees, and the millimetres of a parallel jaw.
    func testTheRecordNamesTheJawsUnit() {
        for (unit, gripper) in [("deg", TestProfiles.so101.gripper), ("mm", TestProfiles.benchBGripper)] {
            let recorded = gripRun(record: true, gripper: gripper)
            XCTAssertGreaterThanOrEqual(recorded.records.count, 2, unit)
            XCTAssertTrue(
                recorded.records.allSatisfy {
                    $0.1.contains("jaw_deg=") && !$0.1.contains("jaw_deg=none")
                        && $0.1.contains("jaw_unit=\(unit) server_activity=gripperJogging")
                }, unit)
        }
    }

    func testRecordingDoesNotChangeUpOrDownCommandsIncludingResync() {
        for direction: Float in [-1, 1] {
            let quiet = run(record: false, direction: direction)
            let recorded = run(record: true, direction: direction)
            XCTAssertEqual(recorded.wire, quiet.wire)
            XCTAssertFalse(recorded.records.isEmpty)
            XCTAssertTrue(recorded.records.contains { $0.1.contains("cap=true") })
            XCTAssertTrue(recorded.records.contains { $0.1.contains("resync=true") })
            for (before, after) in zip(recorded.records, recorded.records.dropFirst()) {
                XCTAssertGreaterThanOrEqual(after.0 - before.0, 1000)
            }
            XCTAssertTrue(
                recorded.records.allSatisfy {
                    $0.1.contains("link_frame=base_x,base_y,negative_base_z units=m")
                        && $0.1.contains("measured_received_age_ms=")
                        && $0.1.contains("gain=1.0 smoothing=0.0")
                        && $0.1.contains("tool_base=none wrist_flex_deg=none wrist_roll_deg=none jaw_deg=none")
                })
            let vertical = recorded.records.compactMap { entry -> Double? in
                guard let start = entry.1.range(of: "sent_link=[") else { return nil }
                let values = entry.1[start.upperBound...].prefix { $0 != "]" }.split(separator: ",")
                return values.last.flatMap { Double($0) }
            }
            XCTAssertTrue(vertical.contains { $0 * Double(direction) < 0 }, "Up is negative link z")
        }
    }
}
