import XCTest
@testable import TeleopCore

final class FakeTeleopStateTests: XCTestCase {
    func testDefaults() {
        let s = FakeTeleopState()
        XCTAssertFalse(s.connected)
        XCTAssertEqual(s.latencyMs, 80)
        XCTAssertEqual(s.serverAddress, "")
    }

    func testMarkConnectedResetsLatency() {
        var s = FakeTeleopState()
        s.latencyMs = 420
        s.commandsBlocked = true
        s.markConnected()
        XCTAssertTrue(s.connected)
        XCTAssertEqual(s.latencyMs, 80)
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

    func testJawsTurnTowardADirectionUntilStopped() {
        var s = FakeTeleopState()
        s.turnJaws(toward: .negative)
        XCTAssertEqual(s.jawTurning, .negative)
        s.turnJaws(toward: .positive)
        XCTAssertEqual(s.jawTurning, .positive)
        s.turnJaws(toward: .tiltDown)
        XCTAssertEqual(s.jawTurning, .tiltDown)
        s.stopTurn()
        XCTAssertNil(s.jawTurning)
    }

    func testOnlyTheTwoPitchDirectionsAreTilts() {
        XCTAssertEqual([TurnDirection.positive, .negative, .tiltDown, .tiltUp].map(\.isTilt), [false, false, true, true])
    }

}
