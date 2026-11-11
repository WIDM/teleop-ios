import simd
import TeleopCore
import XCTest
@testable import Teleop

/// §7.2 as a table: every state row version 1 has, which one wins when several apply, the one-second refusal and the
/// two-second saved displays, and practice.
final class OperatingRulesTests: XCTestCase {
    private func connected(_ change: (inout OperatingFacts) -> Void = { _ in }) -> OperatingFacts {
        var facts = OperatingFacts()
        facts.connected = true
        facts.nowMs = 10_000
        change(&facts)
        return facts
    }

    func testEveryRow() {
        var lost = OperatingFacts()
        lost.connectionLost = true
        var connecting = OperatingFacts()
        connecting.connecting = true
        connecting.address = "100.64.0.7:8765"
        let rows: [(String, OperatingFacts, OperatingState)] = [
            ("not connected", OperatingFacts(), .notConnected(reason: nil)),
            ("connecting", connecting, .connecting(address: "100.64.0.7:8765")),
            ("link lost", lost, .linkLost),
            ("ready", connected(), .ready),
            ("moving", connected { $0.engaged = .translation }, .moving(catchingUp: false)),
            ("catching up", connected { $0.engaged = .translation; $0.catchingUp = true }, .moving(catchingUp: true)),
            ("turning", connected {
                $0.engaged = .wrist
                $0.wristTarget = WristTarget(axis: .turn, degrees: -42)
                $0.wristMeasured = true
            }, .turning(degrees: 42, limit: 55, estimated: false)),
            ("tilting, estimated", connected {
                $0.engaged = .wrist
                $0.wristTarget = WristTarget(axis: .tilt, degrees: 12)
            }, .tilting(degrees: 12, limit: 20, estimated: true)),
            ("wrist before it commits", connected { $0.engaged = .wrist; $0.wristMeasured = true },
             .turning(degrees: 0, limit: 55, estimated: false)),
            ("opening", connected { $0.engaged = .gripper(.open) }, .opening),
            ("closing", connected { $0.engaged = .gripper(.closed) }, .closing(gripped: false)),
            ("gripped", connected { $0.engaged = .gripper(.closed); $0.gripping = true }, .closing(gripped: true)),
            ("saving", connected { $0.serverSaving = true }, .wait(.saving)),
            ("resetting", connected { $0.serverResetting = true }, .wait(.resetting)),
            ("camera stopped", connected { $0.cameraStopped = true }, .trackingLost),
            ("refused", connected { $0.lastRefusal = (.slowLink, 9_500) }, .refused(.slowLink)),
            ("slow link", connected { $0.commandsBlocked = true; $0.latencyMs = 450 }, .slowLink(ms: 450)),
            ("stopped", connected { $0.emergencyStop = true; $0.stopCause = .button }, .stopped(cause: .button)),
            ("saved", connected { $0.lastSaved = (13, 8_500) }, .saved(count: 13)),
        ]
        for (name, facts, expected) in rows {
            XCTAssertEqual(OperatingRules.state(facts), expected, name)
        }
    }

    func testWhichRowWins() {
        let everything = connected {
            $0.emergencyStop = true
            $0.cameraStopped = true
            $0.engaged = .translation
            $0.lastRefusal = (.noLink, 9_900)
            $0.lastSaved = (3, 9_900)
            $0.serverSaving = true
            $0.commandsBlocked = true
        }
        XCTAssertEqual(OperatingRules.state(everything), .stopped(cause: nil), "the stop wins over everything")
        var stopped = everything
        stopped.emergencyStop = false
        stopped.connected = false
        XCTAssertEqual(OperatingRules.state(stopped), .notConnected(reason: nil), "then the link")
        stopped.connected = true
        XCTAssertEqual(OperatingRules.state(stopped), .trackingLost, "then the camera")
        stopped.cameraStopped = false
        XCTAssertEqual(OperatingRules.state(stopped), .saved(count: 3), "then a take just saved")
        stopped.lastSaved = nil
        XCTAssertEqual(OperatingRules.state(stopped), .moving(catchingUp: false), "then the hold")
        stopped.engaged = nil
        XCTAssertEqual(OperatingRules.state(stopped), .refused(.noLink), "then a refusal just heard")
        stopped.lastRefusal = nil
        XCTAssertEqual(OperatingRules.state(stopped), .wait(.saving), "then the server")
        stopped.serverSaving = false
        XCTAssertEqual(OperatingRules.state(stopped), .slowLink(ms: 0), "then a slow link")
    }

    func testARefusalShowsForOneSecondAndASavedTakeForTwo() {
        var facts = connected { $0.lastRefusal = (.notReady, 10_000) }
        facts.nowMs = 10_999
        XCTAssertEqual(OperatingRules.state(facts), .refused(.notReady))
        facts.nowMs = 11_000
        XCTAssertEqual(OperatingRules.state(facts), .ready)

        facts = connected { $0.lastSaved = (7, 10_000) }
        facts.nowMs = 11_999
        XCTAssertEqual(OperatingRules.state(facts), .saved(count: 7))
        facts.nowMs = 12_000
        XCTAssertEqual(OperatingRules.state(facts), .ready)
    }

    func testTheArmReadingComesFromTheNewestState() {
        let profile = RobotProfile.so101Simulator
        XCTAssertNil(OperatingRules.arm(nil, commanded: nil, gripping: false, profile: profile))
        let state = ServerState(payload: [
            "ee_pos": [0.02, -0.14, 0.16], "object_pos": [0.005, -0.2, 0.1025], "goal_pos": [0.075, -0.2, 0.1035],
            "gripper_deg": 48.5, "wrist_roll_deg": 90.0, "wrist_flex_deg": 40.0, "estop": false,
        ])
        let reading = OperatingRules.arm(state, commanded: SIMD3(0.03, -0.14, 0.16), gripping: true, profile: profile)
        assertClose(reading?.pinchPoint ?? .zero, SIMD3<Float>(0.027, -0.176, 0.072), accuracy: 1e-6)
        assertClose(reading?.commanded ?? .zero, SIMD3<Float>(0.037, -0.176, 0.072), accuracy: 1e-6)
        XCTAssertEqual(reading?.jawOpening ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reading?.wristTurnDeg, 90)
        XCTAssertEqual(reading?.wristTiltDeg, 40)
        assertClose(reading?.target ?? .zero, SIMD3<Float>(0.005, -0.2, 0.0525), accuracy: 1e-6)
        assertClose(reading?.goal ?? .zero, SIMD3<Float>(0.075, -0.2, 0.0535), accuracy: 1e-6)
        XCTAssertEqual(reading?.gripping, true)
        let unknown = ServerState(payload: ["ee_pos": [0.02, -0.14, 0.16], "estop": false])
        let bare = OperatingRules.arm(unknown, commanded: nil, gripping: false, profile: profile)
        XCTAssertNil(bare?.jawOpening)
        XCTAssertNil(bare?.target)
    }

    /// Practice stripes every state, is entered only by `startPractice`, and is never what a launch starts in.
    func testPracticeIsAFlagOnEveryStateAndNeverTheDefault() {
        XCTAssertTrue(AppModel.launchesOnTheRealServer(UserDefaults(suiteName: "OperatingRulesTests")!))
        let live = AppModel(start: .p4, haptics: NoHaptics(), pose: { nil }, makeTransport: { _ in NoTransport() })
        XCTAssertFalse(live.operating.practice)
        XCTAssertEqual(live.operating.state, .notConnected(reason: nil))
        live.startPractice()
        XCTAssertTrue(live.operating.practice)
        XCTAssertEqual(live.operating.state, .ready)
        XCTAssertNil(UserDefaults.standard.object(forKey: AppModel.liveLinkKey), "practice is not saved")
        live.send(.stop)
        XCTAssertEqual(live.operating.state, .stopped(cause: .button))
        XCTAssertTrue(live.operating.practice)
        live.leavePractice()
        XCTAssertTrue(live.operating.practice, "not while the robot is stopped")
    }
}

private final class NoTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    func open() {}
    func close() {}
    func send(_ text: String) {}
}

private func assertClose(
    _ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertLessThanOrEqual(simd_length(a - b), accuracy, "\(a) is not \(b)", file: file, line: line)
}
