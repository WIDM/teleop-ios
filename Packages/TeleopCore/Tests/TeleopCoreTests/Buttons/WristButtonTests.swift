import XCTest

@testable import TeleopCore

final class WristButtonTests: XCTestCase {
    func testEachButtonHasItsAxisAndSignedRate() {
        XCTAssertEqual(WristButton.tiltDown.axis, .tilt)
        XCTAssertEqual(WristButton.tiltDown.degreesPerSecond, 10)
        XCTAssertEqual(WristButton.tiltUp.degreesPerSecond, -10)
        XCTAssertEqual(WristButton.turnRight.axis, .turn)
        XCTAssertEqual(WristButton.turnRight.degreesPerSecond, 20)
        XCTAssertEqual(WristButton.turnLeft.degreesPerSecond, -20)
    }

    func testTheAngleWaitsForTheStartThenGrowsAtTheRate() {
        var ramp = WristButtonRamp(button: .turnRight, range: -55...55)
        XCTAssertEqual(ramp.target(at: 10), WristTarget(axis: .turn, degrees: 0), "start still waiting")
        ramp.started(at: 10)
        ramp.started(at: 11)
        XCTAssertEqual(ramp.startedAt, 10, "the first start time stands")
        XCTAssertEqual(ramp.target(at: 10.5).degrees, 10, accuracy: 1e-9)
        XCTAssertEqual(ramp.target(at: 11.5).degrees, 30, accuracy: 1e-9)
        XCTAssertFalse(ramp.atLimit(at: 11.5))
    }

    func testTheAngleStopsAtTheRangeAndSaysSo() {
        var ramp = WristButtonRamp(button: .tiltUp, range: -20...20)
        ramp.started(at: 0)
        XCTAssertEqual(ramp.target(at: 1.9).degrees, -19, accuracy: 1e-9)
        XCTAssertFalse(ramp.atLimit(at: 1.9))
        XCTAssertEqual(ramp.target(at: 5).degrees, -20)
        XCTAssertTrue(ramp.atLimit(at: 2.0))
        var other = WristButtonRamp(button: .tiltDown, range: -20...3)
        other.started(at: 0)
        XCTAssertEqual(other.target(at: 1).degrees, 3, "a window narrower than the per-hold clamp")
        XCTAssertTrue(other.atLimit(at: 0.3))
    }

    func testTheRangeUsedIsThePhoneWristHolds() {
        let readings = WristReadings(rollDeg: 140, flexDeg: 50, flexAtResetDeg: 40)
        let turn = RotationMapper.limits(for: .turn, readings: readings, commandedTiltSinceResetDeg: 0)
        XCTAssertEqual(turn.upperBound, 10, "150 degree window from a roll of 140")
        let tilt = RotationMapper.limits(for: .tilt, readings: readings, commandedTiltSinceResetDeg: 0)
        XCTAssertEqual(tilt.upperBound, 15, "25 degree window, 10 used since the reset")
        XCTAssertEqual(tilt.lowerBound, -20, "the per-hold clamp")
    }
}
