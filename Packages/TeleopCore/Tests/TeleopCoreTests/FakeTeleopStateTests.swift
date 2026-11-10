import XCTest
@testable import TeleopCore

final class FakeTeleopStateTests: XCTestCase {
    func testDefaults() {
        let s = FakeTeleopState()
        XCTAssertEqual(s.mode, .onSite)
        XCTAssertFalse(s.connected)
        XCTAssertEqual(s.latencyMs, 80)
        XCTAssertEqual(s.serverAddress, "192.168.x.x:8765")
    }

    func testMarkConnectedResetsLatency() {
        var s = FakeTeleopState()
        s.simulateHighLatency()
        s.markConnected()
        XCTAssertTrue(s.connected)
        XCTAssertEqual(s.latencyMs, 80)
        XCTAssertFalse(s.commandsBlocked)
    }

    func testHighLatencyBlocksCommandsAndIsAmber() {
        var s = FakeTeleopState()
        XCTAssertFalse(s.latencyIsAmber)
        s.simulateHighLatency()
        XCTAssertEqual(s.latencyMs, 420)
        XCTAssertTrue(s.commandsBlocked)
        XCTAssertTrue(s.latencyIsAmber)
        s.simulateNormalLatency()
        XCTAssertFalse(s.latencyIsAmber)
    }

    func testCloudFailKeepsEstopOkAndDropsHeartbeat() {
        var s = FakeTeleopState()
        s.simulateCloudFail()
        XCTAssertFalse(s.heartbeatOk)
        XCTAssertTrue(s.physicalEstopOk)
    }

    func testGripperMovesTowardATargetUntilStopped() {
        var s = FakeTeleopState()
        s.moveGripper(toward: .closed)
        XCTAssertEqual(s.gripper, .closed)
        XCTAssertEqual(s.gripperMoving, .closed)
        s.stopGripper()
        XCTAssertNil(s.gripperMoving)
        XCTAssertEqual(s.gripper, .closed)
        s.moveGripper(toward: .open)
        XCTAssertEqual(s.gripper, .open)
    }

    func testRecordingClock() {
        var s = FakeTeleopState()
        s.tickRecording()
        XCTAssertEqual(s.recordingElapsedSec, 0)
        s.startRecording()
        for _ in 0..<72 { s.tickRecording() }
        XCTAssertEqual(s.recordingTimeLabel, "01:12")
        s.stopRecording()
        s.tickRecording()
        XCTAssertEqual(s.recordingElapsedSec, 72)
    }
}
