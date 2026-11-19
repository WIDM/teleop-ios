import TeleopCore
import XCTest
@testable import Teleop

private final class TimingTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func receive(_ type: String, _ payload: [String: Any] = [:]) {
        let envelope: [String: Any] = ["v": 1, "type": type, "ts": 10_000, "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!)
    }
    func messages(_ type: String) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == type }.compactMap { $0["payload"] as? [String: Any] }
    }
    func events(_ kind: String) -> [[String: Any]] {
        messages("telemetry").filter { $0["kind"] as? String == kind }
    }
}

final class TimingIntegrationTests: XCTestCase {
    private var model: AppModel!
    private var control: TimingTransport!
    private var observer: TimingTransport!
    private var timing: ExperimentTiming!
    private var eventCounter = 0
    private var savedAddress: Any?

    override func setUp() {
        super.setUp()
        savedAddress = UserDefaults.standard.object(forKey: AppModel.serverAddressKey)
        control = TimingTransport()
        observer = TimingTransport()
        timing = ExperimentTiming(
            clientClockID: "test-phone-clock", now: { 7_000_000_000 },
            makeID: { [unowned self] in
                eventCounter += 1
                return "test-event-\(eventCounter)"
            })
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { TestPose.portrait }, liveLink: true,
            makeTransport: { [unowned self] _ in control },
            makeObserverTransport: { [unowned self] _ in observer },
            nowMs: { 10_000 }, inputClock: { 10 }, experimentTiming: timing)
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
    }

    override func tearDown() {
        model.link.closeQuietly()
        model = nil
        timing = nil
        UserDefaults.standard.set(savedAddress, forKey: AppModel.serverAddressKey)
        super.tearDown()
    }

    private func welcome() {
        control.receive(
            "welcome",
            [
                "telemetry_version": 1, "server_clock_id": "server-clock", "connection_id": "control-connection",
                "telemetry_acknowledgements": true,
            ])
    }

    private func state() {
        control.receive(
            "state",
            [
                "estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16],
                "tool_pos": [0.01, -0.17, 0.07], "study": ["trial_id": "trial-a"],
                "timing": [
                    "state_id": 41, "captured_monotonic_ns": 1_000_000_000,
                    "sent_monotonic_ns": 1_010_000_000, "server_clock_id": "server-clock",
                ],
            ])
    }

    func testControlWelcomeNegotiatesBeforeFirstDiagnosticSend() {
        welcome()
        XCTAssertTrue(timing.enabled)
        XCTAssertEqual(control.messages("clock_probe").count, 1)
        XCTAssertEqual(control.events("measurement_capabilities").count, 1)
        XCTAssertEqual(timing.connectionID, "control-connection")
        XCTAssertTrue(observer.messages("clock_probe").isEmpty)
    }

    func testObserverWelcomeCannotReplaceControlClockOrRestartProbe() {
        welcome()
        XCTAssertNotNil(observer.onText)
        observer.receive(
            "welcome",
            [
                "telemetry_version": 1, "server_clock_id": "other-clock", "connection_id": "observer-connection",
            ])
        XCTAssertEqual(timing.serverClockID, "server-clock")
        XCTAssertEqual(timing.connectionID, "control-connection")
        XCTAssertEqual(control.messages("clock_probe").count, 1)
        XCTAssertEqual(control.events("measurement_capabilities").count, 1)
    }

    func testLegacyWelcomeProducesNoDiagnosticProtocolMessages() {
        control.receive("welcome")
        state()
        model.measurementTick()
        XCTAssertFalse(timing.enabled)
        XCTAssertTrue(control.messages("clock_probe").isEmpty)
        XCTAssertTrue(control.messages("telemetry").isEmpty)
    }

    func testStateReceiptAndModelCommitPreserveMeasurementLimitations() throws {
        welcome()
        state()
        let received = try XCTUnwrap(control.events("state_received").last)
        let details = try XCTUnwrap(received["details"] as? [String: Any])
        XCTAssertEqual(details["state_id"] as? Int, 41)
        XCTAssertEqual(details["server_assembly_to_send_ms"] as? Double, 10)
        XCTAssertEqual(details["source_basis"] as? String, "server_state_snapshot_not_camera_capture")
        XCTAssertEqual(received["trial_id"] as? String, "trial-a")
        XCTAssertTrue(details["state_age_upper_ms"] is NSNull)
        let committed = try XCTUnwrap(control.events("state_model_commit").last?["details"] as? [String: Any])
        XCTAssertEqual(committed["presentation"] as? String, "not_measured")
        XCTAssertEqual(committed["source_binding"] as? String, "unavailable_typed_state_has_no_source_id")
    }

    func testSuspensionDisablesMeasurementsAndResumeStartsFreshProbe() {
        welcome()
        state()
        model.activeChanged(false)
        XCTAssertFalse(timing.enabled)
        XCTAssertEqual(control.events("app_suspended").count, 1)
        let count = control.messages("telemetry").count
        state()
        XCTAssertEqual(control.messages("telemetry").count, count)
        model.activeChanged(true)
        XCTAssertTrue(timing.enabled)
        XCTAssertEqual(control.messages("clock_probe").count, 2)
        XCTAssertEqual(timing.connectionID, "control-connection")
    }

    func testConnectionLossClearsTimingAndCannotResumeCachedWelcome() {
        welcome()
        state()
        control.onClose?()
        XCTAssertFalse(timing.enabled)
        XCTAssertNil(timing.serverClockID)
        XCTAssertNil(timing.connectionID)
        let count = control.messages("clock_probe").count
        model.activeChanged(true)
        XCTAssertFalse(timing.enabled)
        XCTAssertEqual(control.messages("clock_probe").count, count)
    }

    func testSpeechCallbacksRecordSubmissionAndStartWithoutInventingCausalState() throws {
        welcome()
        state()
        model.send(.stop)
        let speechEvents = control.events("speech").compactMap { $0["details"] as? [String: Any] }
        let started = try XCTUnwrap(speechEvents.last { $0["stage"] as? String == "start" })
        let id = try XCTUnwrap(started["utterance_id"] as? Int)
        XCTAssertTrue(speechEvents.contains { $0["stage"] as? String == "submit" && $0["utterance_id"] as? Int == id })
        XCTAssertNotNil(started["submit_to_start_callback_ms"] as? Double)
        XCTAssertEqual(started["causal_source"] as? String, "unavailable_no_bound_decision_identifier")
    }
}
