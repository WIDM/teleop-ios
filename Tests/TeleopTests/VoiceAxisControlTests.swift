import simd
import Speech
import TeleopCore
import XCTest
@testable import Teleop

private final class AxisRecognitionSpy: AxisSpeechRecognizing {
    var onEvent: ((Int, AxisSpeechEvent) -> Void)?
    var epochs: [Int] = []
    var stops = 0
    func start(epoch: Int, language: String) { epochs.append(epoch); onEvent?(epoch, .listening) }
    func stop() { stops += 1 }
}

private final class AxisTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var now: () -> Int = { 10_000 }
    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func receive(_ type: String, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": now(), "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
    func messages(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
}

final class VoiceAxisControlTests: XCTestCase {
    private var model: AppModel!
    private var wire: AxisTransport!
    private var recognition: AxisRecognitionSpy!
    private var speech: SpySpeech!
    private var clock = 10_000
    private var camera: simd_float4x4? = TestPose.portrait
    private var savedMode: Any?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.object(forKey: AppModel.controlModeKey)
    }
    override func tearDown() {
        model = nil
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        super.tearDown()
    }

    private func bringUp(tool: Bool = true, lock: LockChoice = .off) {
        recognition = AxisRecognitionSpy()
        speech = SpySpeech()
        wire = AxisTransport()
        wire.now = { [unowned self] in clock }
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech, axisRecognizer: recognition,
            pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: { [unowned self] _ in wire }, makeObserverTransport: { _ in AxisTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: true, lockChoice: lock)
        model.controlMode = .screenTurns
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        wire.receive(
            "welcome", tool ? ["control_points": ["link_origin", "tool"], "tool_calibration_id": "test-tool"] : [:])
        state()
        for _ in 0..<5 { speech.finish() }
    }
    private func state() {
        wire.receive(
            "state",
            [
                "estop": false, "ik": "ok", "gripper": "open", "ee_pos": [0.0, -0.14, 0.16],
                "tool_pos": [0.01, -0.17, 0.07],
            ])
    }
    private func listen() {
        model.toggleVoiceAxis()
        let started = expectation(description: "recognition starts after quiet tail")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { started.fulfill() }
        wait(for: [started], timeout: 2)
        XCTAssertNotNil(recognition.epochs.last)
    }
    private func choose(_ text: String = "只調高度") {
        recognition.onEvent?(recognition.epochs.last!, .transcript(text, final: true, capturedAt: Double(clock) / 1000))
        for _ in 0..<5 { speech.finish() }
    }

    func testLegacyServerCannotArmToolAxisOrStartMicrophone() {
        bringUp(tool: false)
        model.toggleVoiceAxis()
        XCTAssertFalse(model.voiceAxisSession.enabled)
        XCTAssertEqual(model.voiceAxisFailure, .unsupportedTool)
        XCTAssertTrue(recognition.epochs.isEmpty)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
    }

    func testProductionSpeechRequestUsesLocalizedOnDeviceCommandHints() {
        let chinese = AxisSpeechRecognizer.makeRequest(language: "zh-TW")
        XCTAssertTrue(chinese.requiresOnDeviceRecognition)
        XCTAssertTrue(chinese.shouldReportPartialResults)
        XCTAssertTrue(chinese.contextualStrings.contains("只調高度"))
        XCTAssertTrue(chinese.contextualStrings.contains("只調整高度"))
        XCTAssertTrue(chinese.contextualStrings.contains("只調前後"))
        XCTAssertTrue(chinese.contextualStrings.contains("只調左右"))
        XCTAssertEqual(
            AxisSpeechRecognizer.makeRequest(language: "en-US").contextualStrings,
            [
                "height only", "forward back only", "left right only", "forward a little", "move forward a little",
                "up a little", "move up a little", "open gripper", "open the gripper", "close gripper",
                "close the gripper",
            ])
    }

    func testVoiceSelectsOnlyAndHeldPhoneMotionUsesToolWithNoOffAxisLeak() {
        bringUp()
        listen()
        choose()
        XCTAssertEqual(model.voiceAxisSession.axis, .height)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        model.keyEvent(.upper, down: true)
        let start = wire.messages("pose_start").last!["payload"] as! [String: Any]
        XCTAssertEqual(start["control_point"] as? String, "tool")
        XCTAssertEqual(start["calibration_id"] as? String, "test-tool")
        var moved = TestPose.portrait
        moved.columns.3.x += 0.01
        moved.columns.3.y -= 0.02
        moved.columns.3.z += 0.01
        camera = moved
        clock += 100
        model.link.tick()
        let update = wire.messages("pose_update").last!["payload"] as! [String: Any]
        let offset = update["p_rel_m"] as! [Double]
        XCTAssertEqual(offset[0], 0, accuracy: 0.00001)
        XCTAssertEqual(offset[1], 0, accuracy: 0.00001)
        XCTAssertEqual(offset[2], 0.004, accuracy: 0.0001)
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
        XCTAssertFalse(model.session.state.armMoving)
    }

    func testFormattedFinalSelectsHeightButNegatedAndPartialResultsDoNot() {
        bringUp()
        listen()
        let epoch = recognition.epochs.last!
        let captured = Double(clock) / 1000
        recognition.onEvent?(epoch, .transcript("不要只调高度。", final: true, capturedAt: captured))
        recognition.onEvent?(epoch, .transcript("只 调 高 度。", final: false, capturedAt: captured))
        XCTAssertNil(model.voiceAxisSession.axis)
        choose("只 调 高 度。")
        XCTAssertEqual(model.voiceAxisSession.axis, .height)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
    }

    func testPartialOldAndMidHoldTranscriptsCannotChangeAxis() {
        bringUp()
        listen()
        let old = recognition.epochs.last!
        recognition.onEvent?(old, .transcript("只調左右", final: false, capturedAt: 10))
        XCTAssertNil(model.voiceAxisSession.axis)
        choose()
        model.keyEvent(.upper, down: true)
        recognition.onEvent?(old, .transcript("只調左右", final: true, capturedAt: 10))
        XCTAssertEqual(model.voiceAxisSession.axis, .height)
        model.keyEvent(.upper, down: false)
    }

    func testJointLimitEndsToolHoldUntilUpperKeyIsPressedAgain() throws {
        bringUp()
        listen()
        choose()
        model.keyEvent(.upper, down: true)
        let firstStart = try XCTUnwrap(wire.messages("pose_start").last)
        let sequence = try XCTUnwrap(firstStart["seq"] as? Int)
        XCTAssertTrue(model.session.state.armMoving)

        var moved = TestPose.portrait
        moved.columns.3.y -= 0.02
        camera = moved
        clock += 100
        model.link.tick()
        let updatesBeforeRejection = wire.messages("pose_update").count
        XCTAssertGreaterThan(updatesBeforeRejection, 0)

        wire.receive("ack", ["seq": sequence, "status": "rejected", "reason": "tool_joint_limit"])
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(model.voiceAxisSession.axis, .height)
        for _ in 0..<3 {
            clock += 100
            state()
            model.link.tick()
        }
        XCTAssertEqual(wire.messages("pose_update").count, updatesBeforeRejection)
        XCTAssertEqual(wire.messages("pose_start").count, 1)

        model.keyEvent(.upper, down: false)
        model.keyEvent(.upper, down: true)
        let nextStart = try XCTUnwrap(wire.messages("pose_start").last)
        let payload = try XCTUnwrap(nextStart["payload"] as? [String: Any])
        XCTAssertNotEqual(nextStart["seq"] as? Int, sequence)
        XCTAssertEqual(payload["control_point"] as? String, "tool")
        model.keyEvent(.upper, down: false)
    }

    func testInterruptionClearsSelectionAndOldRecognitionCannotRestartMotion() {
        bringUp()
        listen()
        let old = recognition.epochs.last!
        choose()
        model.keyEvent(.upper, down: true)
        model.activeChanged(false)
        XCTAssertFalse(model.voiceAxisSession.enabled)
        XCTAssertNil(model.controller.arbiter.translationAxis)
        XCTAssertFalse(model.session.state.armMoving)
        model.activeChanged(true)
        recognition.onEvent?(old, .transcript("只調高度", final: true, capturedAt: 10))
        model.keyEvent(.upper, down: true)
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        model.keyEvent(.upper, down: false)
    }

    func testOutputSpeechInvalidatesRecognitionBeforeSubmission() {
        bringUp()
        listen()
        let epoch = recognition.epochs.last!
        speech.holds = true
        model.raise(.ready)
        XCTAssertNil(model.voiceAxisSession.listeningEpoch)
        recognition.onEvent?(epoch, .transcript("只調高度", final: true, capturedAt: 10))
        XCTAssertNil(model.voiceAxisSession.axis)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
    }

    func testPermissionFailureLeavesNoSelectedAxisOrMotion() {
        bringUp()
        listen()
        recognition.onEvent?(recognition.epochs.last!, .failed(.permission))
        XCTAssertEqual(model.voiceAxisFailure, .permission)
        XCTAssertFalse(model.voiceAxisSession.enabled)
        XCTAssertNil(model.controller.arbiter.translationAxis)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
    }
    func testStaleToolStateCannotStartAxisHold() {
        bringUp()
        listen()
        choose()
        clock += 1_000
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertFalse(model.session.state.armMoving)
    }

}
