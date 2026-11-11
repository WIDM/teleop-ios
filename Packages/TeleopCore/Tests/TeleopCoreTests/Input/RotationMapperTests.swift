import simd
import XCTest
@testable import TeleopCore

/// Attitudes built from the operator's words: a clockwise steering turn and a tip of the top edge away.
enum Phone {
    static let z = SIMD3<Double>(0, 0, 1), x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0)
    /// An arbitrary resting attitude, so nothing depends on starting at the identity.
    static let rest = simd_normalize(simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(0.3, -0.5, 0.8))))

    static func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
    /// Turned clockwise by `turn` and then tipped away by `tilt`, both in degrees, from `base`.
    static func attitude(turn: Double = 0, tilt: Double = 0, from base: simd_quatd = rest) -> simd_quatd {
        let tip = simd_quatd(angle: -rad(tilt), axis: x)
        let steer = simd_quatd(angle: -rad(turn), axis: z)
        return simd_normalize(base * tip * steer)
    }
}

final class PhoneAttitudeTests: XCTestCase {
    func testUprightPortraitCameraIsTheIdentity() {
        // Phone upright facing the operator in ARKit's world (y up): camera x points down the long side toward the
        // bottom edge, camera y toward the portrait right edge, camera z out of the screen.
        let transform = simd_float4x4(columns: (
            SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0.1, 1.2, -0.3, 1)
        ))
        let portrait = PhoneAttitude.portrait(cameraTransform: transform)
        assertEqual(portrait.act(Phone.x), Phone.x)
        assertEqual(portrait.act(Phone.y), Phone.y)
        assertEqual(portrait.act(Phone.z), Phone.z)
    }

    func testCameraRotationsReadAsTurnAndTilt() {
        let camera = simd_normalize(simd_quatd(angle: 1.1, axis: simd_normalize(SIMD3(1, 2, -0.5))))
        let anchor = PhoneAttitude.portrait(camera: camera)
        // Steering clockwise is a negative turn about the screen normal, camera z.
        let steered = PhoneAttitude.portrait(camera: camera * simd_quatd(angle: -Phone.rad(12), axis: Phone.z))
        XCTAssertEqual(WristAngles(from: anchor, to: steered).turn, 12, accuracy: 1e-9)
        XCTAssertEqual(WristAngles(from: anchor, to: steered).tilt, 0, accuracy: 1e-9)
        // Portrait x is camera y: tipping the top away is a negative turn about camera y.
        let tipped = PhoneAttitude.portrait(camera: camera * simd_quatd(angle: -Phone.rad(7), axis: Phone.y))
        XCTAssertEqual(WristAngles(from: anchor, to: tipped).tilt, 7, accuracy: 1e-9)
        XCTAssertEqual(WristAngles(from: anchor, to: tipped).turn, 0, accuracy: 1e-9)
    }

    func testSwingTwistSplit() {
        let pure = WristAngles(from: Phone.rest, to: Phone.attitude(turn: -30))
        XCTAssertEqual(pure.turn, -30, accuracy: 1e-9)
        XCTAssertEqual(pure.tilt, 0, accuracy: 1e-9)
        let tilt = WristAngles(from: Phone.rest, to: Phone.attitude(tilt: 15))
        XCTAssertEqual(tilt.tilt, 15, accuracy: 1e-9)
        XCTAssertEqual(tilt.turn, 0, accuracy: 1e-9)
        let both = WristAngles(from: Phone.rest, to: Phone.attitude(turn: 20, tilt: -10))
        XCTAssertEqual(both.turn, 20, accuracy: 1e-9)
        XCTAssertEqual(both.tilt, -10, accuracy: 1e-9)
        // Rotation about the phone's y axis is ignored.
        let sideways = WristAngles(from: Phone.rest, to: Phone.rest * simd_quatd(angle: Phone.rad(25), axis: Phone.y))
        XCTAssertEqual(sideways.turn, 0, accuracy: 1e-9)
        XCTAssertEqual(sideways.tilt, 0, accuracy: 1e-9)
    }

    private func assertEqual(_ a: SIMD3<Double>, _ b: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), 1e-6, "\(a) != \(b)", file: file, line: line)
    }
}

final class RotationMapperTests: XCTestCase {
    let wide = -55.0...55.0
    /// 30 Hz samples, so one sample keeps exactly `angleSmoothing` of the previous value.
    let step = 1.0 / 30

    func testAxisLockAtFiveDegreesWithTheSixtyPercentRule() {
        let mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        XCTAssertNil(mapper.dominantAxis(.init(turn: 4.9, tilt: 0)))
        XCTAssertEqual(mapper.dominantAxis(.init(turn: 5, tilt: 2.99)), .turn)
        XCTAssertNil(mapper.dominantAxis(.init(turn: 5, tilt: 3)))
        XCTAssertEqual(mapper.dominantAxis(.init(turn: -1, tilt: -5)), .tilt)
        XCTAssertNil(mapper.dominantAxis(.init(turn: 6, tilt: -6)))
        XCTAssertTrue(mapper.reachedLockAngle(.init(turn: 6, tilt: -6)))
    }

    func testMixedRotationGivesOneAxis() {
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        _ = mapper.lock(.turn, range: wide, attitude: Phone.attitude(turn: 5), at: 0)
        // Hold the turn at 20° and tip the phone back and forth: only the turn reaches the target.
        var last = WristTarget.identity
        for (i, tilt) in stride(from: 0.0, through: 18, by: 1.5).enumerated() {
            last = mapper.target(for: Phone.attitude(turn: 20, tilt: tilt), at: Double(i + 1) * step).target
        }
        XCTAssertEqual(last.axis, .turn)
        XCTAssertEqual(last.degrees, 20, accuracy: 1e-3)
    }

    func testCommitAngleCountsInSchemeAAndSchemeBStartsFromZero() {
        var a = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        XCTAssertEqual(a.lock(.tilt, range: -20...20, attitude: Phone.attitude(tilt: 5), at: 0).target.degrees, 5, accuracy: 1e-9)
        var b = RotationMapper(anchor: Phone.rest, startsAtCommit: false)
        XCTAssertEqual(b.lock(.tilt, range: -20...20, attitude: Phone.attitude(tilt: 5), at: 0).target.degrees, 0)
        // One 30 Hz sample later the smoothing has covered 80% of the way.
        XCTAssertEqual(b.target(for: Phone.attitude(tilt: 5), at: step).target.degrees, 4, accuracy: 1e-9)
    }

    func testSmoothingIsTheSameAtSixtyHertz() {
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: false)
        _ = mapper.lock(.turn, range: wide, attitude: Phone.attitude(turn: 10), at: 0)
        _ = mapper.target(for: Phone.attitude(turn: 10), at: step / 2)
        XCTAssertEqual(mapper.target(for: Phone.attitude(turn: 10), at: step).target.degrees, 8, accuracy: 1e-9)
    }

    func testRollSignAppliesToTheOutput() {
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true, constants: InputConstants(rollSign: -1))
        XCTAssertEqual(mapper.lock(.turn, range: wide, attitude: Phone.attitude(turn: 6), at: 0).target.degrees, -6, accuracy: 1e-9)
    }

    func testTurnClampGivesEndOnceAndTurningBackMovesTheTargetAtOnce() {
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        var time = 0.0
        var ends = 0
        func feed(_ turn: Double) -> WristTarget {
            time += step
            let result = mapper.target(for: Phone.attitude(turn: turn), at: time)
            if result.limitReached { ends += 1 }
            return result.target
        }
        _ = mapper.lock(.turn, range: wide, attitude: Phone.attitude(turn: 5), at: time)
        var target = WristTarget.identity
        for turn in stride(from: 5.0, through: 80, by: 1) { target = feed(turn) }
        for _ in 0..<20 { target = feed(80) }
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(target.degrees, 55, accuracy: 1e-9)
        // Back under the clamp: the very next target is below the edge, with no wind-up to unwind first.
        XCTAssertLessThan(feed(52).degrees, 55)
        XCTAssertEqual(ends, 1, "backing off 3° does not re-arm")
        _ = feed(56)
        XCTAssertEqual(ends, 1)
        _ = feed(49.9)
        _ = feed(55)
        XCTAssertEqual(ends, 2, "re-armed after backing off 5°")
        // The other edge counts as a new limit.
        for turn in stride(from: 55.0, through: -60, by: -1) { _ = feed(turn) }
        XCTAssertEqual(ends, 3)
    }

    func testTiltClampGivesEndOnce() {
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        let range = RotationMapper.limits(for: .tilt, readings: .unknown, commandedTiltSinceResetDeg: 0)
        XCTAssertEqual(range, -20...20)
        var ends = mapper.lock(.tilt, range: range, attitude: Phone.attitude(tilt: -5), at: 0).limitReached ? 1 : 0
        var last = 0.0
        for (i, tilt) in stride(from: -5.0, through: -40, by: -1).enumerated() {
            let result = mapper.target(for: Phone.attitude(tilt: tilt), at: Double(i + 1) * step)
            if result.limitReached { ends += 1 }
            last = result.target.degrees
        }
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(last, -20, accuracy: 1e-3)
    }

    func testTiltWindowAroundTheResetFlex() {
        // The flex has already moved 10° down since the reset: 15° more reach the 25° window before the 20° clamp.
        let readings = WristReadings(rollDeg: 0, flexDeg: 40, flexAtResetDeg: 30)
        XCTAssertEqual(RotationMapper.limits(for: .tilt, readings: readings, commandedTiltSinceResetDeg: 99), -20...15)
        assertOneEnd(axis: .tilt, range: RotationMapper.limits(for: .tilt, readings: readings, commandedTiltSinceResetDeg: 0),
                     sweep: stride(from: 5.0, through: 30, by: 1), edge: 15)
    }

    func testTiltWindowOnAnUnknownServerCountsCommandedTilt() {
        XCTAssertEqual(RotationMapper.limits(for: .tilt, readings: .unknown, commandedTiltSinceResetDeg: -18), -7...20)
        // Partly known readings fall back to the commanded sum too.
        XCTAssertEqual(RotationMapper.limits(for: .tilt, readings: .init(flexDeg: 3), commandedTiltSinceResetDeg: 15), -20...10)
    }

    func testRollWindowFromTheMeasuredRoll() {
        let range = RotationMapper.limits(for: .turn, readings: .init(rollDeg: 120), commandedTiltSinceResetDeg: 0)
        XCTAssertEqual(range, -55...30)
        assertOneEnd(axis: .turn, range: range, sweep: stride(from: 5.0, through: 50, by: 1), edge: 30)
        // On an unknown server only the clamp applies.
        XCTAssertEqual(RotationMapper.limits(for: .turn, readings: .unknown, commandedTiltSinceResetDeg: 0), -55...55)
    }

    func testAWristAlreadyPastAWindowMayOnlyTurnBack() {
        let range = RotationMapper.limits(for: .turn, readings: .init(rollDeg: 155), commandedTiltSinceResetDeg: 0)
        XCTAssertEqual(range, -55...0)
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        let first = mapper.lock(.turn, range: range, attitude: Phone.attitude(turn: 5), at: 0)
        XCTAssertTrue(first.limitReached)
        XCTAssertEqual(first.target.degrees, 0)
    }

    func testALateStartDropsTheRotationMadeWhileItWaited() {
        var a = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        _ = a.lock(.turn, range: wide, attitude: Phone.attitude(turn: 5), at: 0)
        // The start waits behind a finishing hold while the phone turns on to 17°.
        let atSend = Phone.attitude(turn: 17)
        a.startSent(attitude: atSend, at: 0.5)
        XCTAssertEqual(a.target(for: atSend, at: 0.5 + step).target.degrees, 5, accuracy: 1e-9)
        XCTAssertEqual(a.target(for: Phone.attitude(turn: 27), at: 0.5 + 40 * step).target.degrees, 15, accuracy: 1e-6)

        var b = RotationMapper(anchor: Phone.rest, startsAtCommit: false)
        _ = b.lock(.tilt, range: -20...20, attitude: Phone.attitude(tilt: 6), at: 0)
        b.startSent(attitude: Phone.attitude(tilt: 9), at: 0.4)
        XCTAssertNil(b.axis)
        XCTAssertEqual(b.target(for: Phone.attitude(tilt: 9), at: 0.5).target, .identity)
        XCTAssertEqual(b.angles(Phone.attitude(tilt: 12)).tilt, 3, accuracy: 1e-9)
    }

    private func assertOneEnd(
        axis: WristAxis, range: ClosedRange<Double>, sweep: StrideThrough<Double>, edge: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true)
        func attitude(_ angle: Double) -> simd_quatd { axis == .turn ? Phone.attitude(turn: angle) : Phone.attitude(tilt: angle) }
        var ends = 0
        var last = 0.0
        var time = 0.0
        if mapper.lock(axis, range: range, attitude: attitude(5), at: time).limitReached { ends += 1 }
        for angle in sweep {
            time += step
            let result = mapper.target(for: attitude(angle), at: time)
            if result.limitReached { ends += 1 }
            last = result.target.degrees
        }
        XCTAssertEqual(ends, 1, file: file, line: line)
        XCTAssertEqual(last, edge, accuracy: 1e-3, file: file, line: line)
    }
}
