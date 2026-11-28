import XCTest

@testable import TeleopCore

/// The wrist rules run once per wrist: the SO-101's and bench arm B's (`TestWrist`). Each expectation is the one the
/// SO-101's own tests pin, written in terms of the wrist's numbers (a clamp, a window, a rate, a sign), so what holds
/// for B is what holds for the SO-101 with B's numbers in it; no number for B is typed twice.
final class WristAcrossWristsTests: XCTestCase {
    private let step = 1.0 / 30

    private func constants(_ wrist: WristProfile) -> InputConstants { InputConstants(wrist: wrist) }

    /// Sanity: B differs from the SO-101 wherever the profile lets an arm differ, so a rule that read the other's
    /// number would be caught.
    func testBenchBDiffersFromTheSO101InEveryWristNumber() {
        let a = TestWrist.so101, b = TestWrist.benchB
        XCTAssertNotEqual(a.rollSign, b.rollSign)
        // B's two signs are opposite, so a rule that reads one axis's sign for the other cannot pass for both wrists.
        XCTAssertNotEqual(b.rollSign, b.tiltSign)
        XCTAssertNotEqual(a.rollWindowDeg, b.rollWindowDeg)
        XCTAssertNotEqual(a.tiltWindowDeg, b.tiltWindowDeg)
        XCTAssertNotEqual(a.rollClampDeg, b.rollClampDeg)
        XCTAssertNotEqual(a.tiltClampDeg, b.tiltClampDeg)
        XCTAssertNotEqual(a.tiltCentre, b.tiltCentre)
        XCTAssertNotEqual(a.turnRateDegS, b.turnRateDegS)
        XCTAssertNotEqual(a.tiltRateDegS, b.tiltRateDegS)
        XCTAssertNotEqual(a.lead.leadDeg, b.lead.leadDeg)
        XCTAssertNotEqual(a.lead.rateMaxDegS, b.lead.rateMaxDegS)
        XCTAssertNotEqual(a.lead.memoryDeg, b.lead.memoryDeg)
        XCTAssertNotEqual(a.lead.freshStateMs, b.lead.freshStateMs)
    }

    /// The SO-101's wrist buttons: Tilt down 10 and Turn right 20 degrees a second (WristButtonTests), unchanged.
    func testTheSO101ButtonsKeepTheirRates() {
        let wrist = TestWrist.so101
        XCTAssertEqual(WristButton.tiltDown.degreesPerSecond(in: wrist), 10)
        XCTAssertEqual(WristButton.tiltUp.degreesPerSecond(in: wrist), -10)
        XCTAssertEqual(WristButton.turnRight.degreesPerSecond(in: wrist), 20)
        XCTAssertEqual(WristButton.turnLeft.degreesPerSecond(in: wrist), -20)
    }

    /// A button and the phone make the same server angle for the same motion in the operator's terms: Turn right is a
    /// clockwise turn, Tilt down tips the top of the phone away; one pair of signs serves both.
    func testAButtonAndThePhoneAgreeOnTheSign() {
        for (name, wrist) in TestWrist.all {
            let phone: [(WristButton, WristAxis, Double, Double)] = [
                (.turnRight, .turn, 10, 0), (.turnLeft, .turn, -10, 0), (.tiltDown, .tilt, 0, 10),
                (.tiltUp, .tilt, 0, -10),
            ]
            for (button, axis, turn, tilt) in phone {
                var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true, constants: constants(wrist))
                let fromPhone = mapper.lock(
                    axis, range: -90...90, attitude: Phone.attitude(turn: turn, tilt: tilt), at: 0
                ).target
                let rate = button.degreesPerSecond(in: wrist)
                var ramp = WristButtonRamp(button: button, range: -90...90, wrist: wrist)
                ramp.started(at: 0)
                let seconds = 10 / abs(rate)
                let fromButton = ramp.target(at: seconds)
                XCTAssertEqual(fromButton.axis, fromPhone.axis, "\(name) \(button)")
                XCTAssertEqual(fromButton.degrees, fromPhone.degrees, accuracy: 1e-9, "\(name) \(button)")
            }
        }
    }

    func testAButtonMovesAtItsWristsRate() {
        for (name, wrist) in TestWrist.all {
            for button in WristButton.allCases {
                let rate = button.axis == .turn ? wrist.turnRateDegS : wrist.tiltRateDegS
                var ramp = WristButtonRamp(button: button, range: -90...90, wrist: wrist)
                ramp.started(at: 4)
                XCTAssertEqual(abs(ramp.target(at: 5).degrees), rate, accuracy: 1e-9, "\(name) \(button)")
                XCTAssertEqual(abs(ramp.target(at: 4.5).degrees), rate / 2, accuracy: 1e-9, "\(name) \(button)")
            }
        }
    }

    /// The button's hold ends at the limit it runs toward, whichever way the sign makes that.
    func testAButtonSaysItReachedTheLimitOnTheSideItRunsToward() {
        for (name, wrist) in TestWrist.all {
            for button in WristButton.allCases {
                let range = -wrist.tiltClampDeg...wrist.rollClampDeg
                var ramp = WristButtonRamp(button: button, range: range, wrist: wrist)
                ramp.started(at: 0)
                let rate = button.degreesPerSecond(in: wrist)
                let edge = rate > 0 ? range.upperBound : range.lowerBound
                let seconds = abs(edge / rate)
                XCTAssertFalse(ramp.atLimit(at: seconds * 0.99), "\(name) \(button)")
                XCTAssertTrue(ramp.atLimit(at: seconds), "\(name) \(button)")
                XCTAssertEqual(ramp.target(at: seconds * 3).degrees, edge, "\(name) \(button)")
            }
        }
    }

    /// The SO-101's cases of `RotationMapper.limits`: the clamp alone with no reading; a roll near the window's edge;
    /// a tilt part way through its window since the reset. In each, B's range comes from B's own clamp, window and
    /// centre.
    func testTheRangesAHoldMayCommandComeFromTheWristsOwnNumbers() {
        for (name, wrist) in TestWrist.all {
            let c = constants(wrist)
            let none = WristReadings()
            XCTAssertEqual(
                RotationMapper.limits(for: .turn, readings: none, commandedTiltSinceResetDeg: 0, constants: c),
                -wrist.rollClampDeg...wrist.rollClampDeg, name)
            // The roll 10 degrees inside the window's edge: 10 degrees more may be asked that way, the clamp the other.
            let nearEdge = WristReadings(rollDeg: wrist.rollWindowDeg - 10, flexDeg: 0)
            XCTAssertEqual(
                RotationMapper.limits(for: .turn, readings: nearEdge, commandedTiltSinceResetDeg: 0, constants: c),
                -wrist.rollClampDeg...10, name)
            let nearOtherEdge = WristReadings(rollDeg: -wrist.rollWindowDeg + 10, flexDeg: 0)
            XCTAssertEqual(
                RotationMapper.limits(for: .turn, readings: nearOtherEdge, commandedTiltSinceResetDeg: 0, constants: c),
                -10...wrist.rollClampDeg, name)
            // The flex 10 degrees from the window's centre: the window leaves (window - 10) that way, (window + 10)
            // the other, each held to the clamp.
            let centre = wrist.tiltCentreDeg(measuredAfterReset: 40)
            let tilted = WristReadings(rollDeg: 0, flexDeg: (centre ?? 0) + 10, flexAtResetDeg: centre)
            let upper = min(wrist.tiltClampDeg, wrist.tiltWindowDeg - 10)
            let lower = max(-wrist.tiltClampDeg, -wrist.tiltWindowDeg - 10)
            XCTAssertEqual(
                RotationMapper.limits(for: .tilt, readings: tilted, commandedTiltSinceResetDeg: 0, constants: c),
                lower...upper, name)
            // Without the flex readings the window counts the tilts commanded since the reset.
            let unknown = RotationMapper.limits(
                for: .tilt, readings: none, commandedTiltSinceResetDeg: 10, constants: c)
            XCTAssertEqual(unknown, lower...upper, name)
            // Past a window the range still holds 0, so the wrist may turn back.
            let past = WristReadings(rollDeg: wrist.rollWindowDeg + 20, flexDeg: 0)
            XCTAssertEqual(
                RotationMapper.limits(for: .turn, readings: past, commandedTiltSinceResetDeg: 0, constants: c)
                    .upperBound, 0, name)
        }
    }

    func testTheTiltWindowIsCentredWhereTheProfileSaysAndOnlyThere() {
        for (name, wrist) in TestWrist.all {
            switch wrist.tiltCentre {
            case .measuredAfterReset:
                XCTAssertEqual(wrist.tiltCentreDeg(measuredAfterReset: 37), 37, name)
                XCTAssertNil(wrist.tiltCentreDeg(measuredAfterReset: nil), name)
            case .fixed(let centre):
                XCTAssertEqual(wrist.tiltCentreDeg(measuredAfterReset: 37), centre, name)
                XCTAssertEqual(wrist.tiltCentreDeg(measuredAfterReset: nil), centre, name)
            }
        }
        var measured = TestWrist.so101
        measured.tiltCentre = .measuredAfterReset
        var fixed = measured
        fixed.tiltCentre = .fixed(0)
        XCTAssertEqual(measured.tiltCentreDeg(measuredAfterReset: 12), 12)
        XCTAssertEqual(fixed.tiltCentreDeg(measuredAfterReset: 12), 0)
    }

    /// A phone hold turned past the clamp stops at the wrist's clamp, with its sign, and says so once.
    func testAPhoneHoldStopsAtTheWristsClampWithItsSign() {
        for (name, wrist) in TestWrist.all {
            let c = constants(wrist)
            let range = RotationMapper.limits(
                for: .turn, readings: WristReadings(rollDeg: 0, flexDeg: 0), commandedTiltSinceResetDeg: 0,
                constants: c)
            var mapper = RotationMapper(anchor: Phone.rest, startsAtCommit: true, constants: c)
            _ = mapper.lock(.turn, range: range, attitude: Phone.attitude(turn: 5), at: 0)
            var target = WristTarget.identity
            var time = 0.0
            var ends = 0
            for turn in stride(from: 5.0, through: wrist.rollClampDeg + 40, by: 1) {
                time += step
                let result = mapper.target(for: Phone.attitude(turn: turn), at: time)
                if result.limitReached { ends += 1 }
                target = result.target
            }
            for _ in 0..<30 {
                time += step
                target = mapper.target(for: Phone.attitude(turn: wrist.rollClampDeg + 40), at: time).target
            }
            XCTAssertEqual(ends, 1, name)
            XCTAssertEqual(target.degrees, wrist.rollSign * wrist.rollClampDeg, accuracy: 1e-9, name)
        }
    }

    private func roll(_ degrees: Double) -> WristReadings { WristReadings(rollDeg: degrees, flexDeg: 40) }
    private func turn(_ degrees: Double) -> WristTarget { WristTarget(axis: .turn, degrees: degrees) }

    /// The SO-101's frozen wrist (WristLeadBoundTests): never led by more than the lead plus the rate times the
    /// state's age, with B's numbers in place of the SO-101's.
    func testAFrozenWristIsNeverLedByMoreThanItsOwnAllowance() {
        for (name, wrist) in TestWrist.all {
            var bound = WristLeadBound(limits: wrist.lead)
            bound.holdStarted(measured: roll(90))
            let fresh = Double(wrist.lead.freshStateMs)
            for asked in stride(from: 0.0, through: 55, by: 5) {
                for age in [0, fresh / 4, fresh / 2, fresh] {
                    let sent = bound.bounded(turn(asked), measured: roll(95), ageMs: Int(age))
                    let lead = 90 + sent.degrees - 95
                    let allowance = wrist.lead.leadDeg + wrist.lead.rateMaxDegS * age / 1000
                    XCTAssertLessThanOrEqual(abs(lead), allowance + 1e-9, "\(name) asked \(asked), age \(age)")
                    if abs(90 + asked - 95) <= allowance {
                        XCTAssertEqual(sent.degrees, asked, accuracy: 1e-9, "\(name)")
                    }
                }
            }
        }
    }

    /// A state older than the wrist's own freshness limit is not fresh: the command may only come back toward the
    /// wrist. One a millisecond inside the limit still is.
    func testAStateIsFreshOnlyWithinTheWristsOwnLimit() {
        for (name, wrist) in TestWrist.all {
            let limit = wrist.lead.freshStateMs
            var inside = WristLeadBound(limits: wrist.lead)
            inside.holdStarted(measured: roll(90))
            let allowed = wrist.lead.leadDeg + wrist.lead.rateMaxDegS * Double(limit) / 1000
            let sentInside = inside.bounded(turn(allowed + 20), measured: roll(90), ageMs: limit)
            XCTAssertEqual(sentInside.degrees, allowed, accuracy: 1e-9, name)
            var outside = WristLeadBound(limits: wrist.lead)
            outside.holdStarted(measured: roll(90))
            XCTAssertEqual(outside.bounded(turn(allowed + 20), measured: roll(90), ageMs: limit + 1), turn(0), name)
        }
    }

    /// The lead left by one hold counts for the next only while the wrist stayed within the wrist's memory distance.
    func testTheRememberedLeadIsKeptOnlyWithinTheWristsMemoryDistance() {
        for (name, wrist) in TestWrist.all {
            let memory = wrist.lead.memoryDeg
            func lead(after movedBy: Double) -> Double? {
                var bound = WristLeadBound(limits: wrist.lead)
                bound.holdStarted(measured: roll(90))
                _ = bound.bounded(turn(40), measured: roll(90), ageMs: 0)
                bound.holdEnded(measured: roll(90))
                bound.holdStarted(measured: roll(90 + movedBy))
                return bound.rememberedLead(.turn)
            }
            XCTAssertNotNil(lead(after: memory), name)
            XCTAssertNil(lead(after: memory + 0.1), name)
        }
    }
}
