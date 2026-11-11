import XCTest
@testable import TeleopCore

final class FakeTeleopStateTests: XCTestCase {
    func testDefaults() {
        let s = FakeTeleopState()
        XCTAssertFalse(s.connected)
        XCTAssertNil(s.latencyMs, "nothing measured yet")
        XCTAssertEqual(s.serverAddress, "")
    }

    func testMarkConnectedResetsLatency() {
        var s = FakeTeleopState()
        s.latencyMs = 420
        s.commandsBlocked = true
        s.markConnected()
        XCTAssertTrue(s.connected)
        XCTAssertNil(s.latencyMs, "a new connection has no sample yet")
        XCTAssertFalse(s.commandsBlocked)
    }

    func testLatencyIsAmberWhenBlockedOrSlow() {
        var s = FakeTeleopState()
        XCTAssertFalse(s.latencyIsAmber)
        s.commandsBlocked = true
        XCTAssertTrue(s.latencyIsAmber)
        s.clearLatency()
        XCTAssertFalse(s.commandsBlocked)
        XCTAssertFalse(s.latencyIsAmber)
        s.latencyMs = FakeTeleopState.amberLatencyMs
        XCTAssertTrue(s.latencyIsAmber)
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


}
