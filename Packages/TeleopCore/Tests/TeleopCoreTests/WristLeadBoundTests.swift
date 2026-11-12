import XCTest
@testable import TeleopCore

/// C-I6, the lead bound: a wrist frozen mid-turn is never led by more than `leadDeg` + `rateMaxDegS` × the state's
/// age; the next hold starts from the remembered lead and does not add to it; a reset clears it.
final class WristLeadBoundTests: XCTestCase {
    private func roll(_ degrees: Double) -> WristReadings { WristReadings(rollDeg: degrees, flexDeg: 40) }
    private func turn(_ degrees: Double) -> WristTarget { WristTarget(axis: .turn, degrees: degrees) }

    func testAFreeWristIsNotHeldBack() {
        var bound = WristLeadBound()
        bound.holdStarted(measured: roll(90))
        // The wrist trails the command by under a degree, as a freely moving one does.
        for step in 1...40 {
            let asked = Double(step)
            let sent = bound.bounded(turn(asked), measured: roll(90 + asked - 0.8), ageMs: 100)
            XCTAssertEqual(sent, turn(asked), "step \(step)")
        }
    }

    func testAFrozenWristIsNeverLedByMoreThanTheAllowance() {
        var bound = WristLeadBound()
        bound.holdStarted(measured: roll(90))
        for asked in stride(from: 0.0, through: 55, by: 5) {
            for age in [0, 100, 200, 400] {
                let sent = bound.bounded(turn(asked), measured: roll(95), ageMs: age)
                let lead = 90 + sent.degrees - 95
                let allowance = 2 + 10 * Double(age) / 1000
                XCTAssertLessThanOrEqual(abs(lead), allowance + 1e-9, "asked \(asked), age \(age)")
                // Inside the allowance the command is what was asked.
                if abs(90 + asked - 95) <= allowance { XCTAssertEqual(sent.degrees, asked, accuracy: 1e-9) }
            }
        }
    }

    func testTheBoundHoldsTurningTheOtherWayAndOnTheTilt() {
        var bound = WristLeadBound()
        bound.holdStarted(measured: WristReadings(rollDeg: 0, flexDeg: 40))
        XCTAssertEqual(bound.bounded(turn(-30), measured: roll(-10), ageMs: 0), turn(-12))
        var tilt = WristLeadBound()
        tilt.holdStarted(measured: WristReadings(rollDeg: 0, flexDeg: 40))
        let sent = tilt.bounded(
            WristTarget(axis: .tilt, degrees: 15), measured: WristReadings(rollDeg: 0, flexDeg: 41), ageMs: 200)
        XCTAssertEqual(sent.degrees, 41 + 4 - 40, accuracy: 1e-9)
    }

    func testWithoutAFreshStateTheCommandDoesNotMoveFurtherFromTheWrist() {
        var bound = WristLeadBound()
        bound.holdStarted(measured: roll(90))
        XCTAssertEqual(bound.bounded(turn(10), measured: roll(88), ageMs: 0), turn(0))
        // The newest state is old now: 0 sent is 2 ahead of the wrist, and stays at most that.
        XCTAssertEqual(bound.bounded(turn(20), measured: roll(88), ageMs: 900), turn(0))
        XCTAssertEqual(
            bound.bounded(turn(-1), measured: roll(88), ageMs: 900), turn(-1), "back toward the wrist is fine")
        XCTAssertEqual(bound.bounded(turn(20), measured: roll(88), ageMs: nil), turn(-1))
    }

    func testTheNextHoldStartsFromTheRememberedLeadInsteadOfAddingToIt() {
        var bound = WristLeadBound()
        bound.holdStarted(measured: roll(90))
        _ = bound.bounded(turn(30), measured: roll(92), ageMs: 200)
        bound.holdEnded(measured: roll(92))
        // 90 + 6 sent, the wrist at 92: the server keeps 4 degrees of lead.
        XCTAssertEqual(bound.rememberedLead(.turn) ?? .nan, 4, accuracy: 1e-9)

        bound.holdStarted(measured: roll(92.3))
        // The hold starts from the wrist plus the kept lead, as the server anchors at its kept target. Asking for
        // nothing more pulls the target back to the wrist + 2.
        let first = bound.bounded(turn(0), measured: roll(92.3), ageMs: 0)
        XCTAssertEqual(92.3 + 4 + first.degrees, 92.3 + 2, accuracy: 1e-9)
        let more = bound.bounded(turn(20), measured: roll(92.3), ageMs: 0)
        XCTAssertEqual(92.3 + 4 + more.degrees, 92.3 + 2, accuracy: 1e-9, "the lead never grows past the bound")
    }

    func testTheRememberedLeadIsForgottenOnceTheWristMovedOrAfterAReset() {
        var moved = WristLeadBound()
        moved.holdStarted(measured: roll(90))
        _ = moved.bounded(turn(30), measured: roll(92), ageMs: 200)
        moved.holdEnded(measured: roll(92))
        moved.holdStarted(measured: roll(93))
        XCTAssertNil(moved.rememberedLead(.turn))
        XCTAssertEqual(moved.bounded(turn(1), measured: roll(93), ageMs: 0), turn(1))

        var reset = WristLeadBound()
        reset.holdStarted(measured: roll(90))
        _ = reset.bounded(turn(30), measured: roll(92), ageMs: 200)
        reset.holdEnded(measured: roll(92))
        reset.sceneReset()
        XCTAssertNil(reset.rememberedLead(.turn))
    }

    func testAnUnknownServerAndAnUncommittedHoldPassUnchanged() {
        var bound = WristLeadBound()
        bound.holdStarted(measured: .unknown)
        XCTAssertEqual(bound.bounded(turn(40), measured: .unknown, ageMs: 0), turn(40))
        var identity = WristLeadBound()
        identity.holdStarted(measured: roll(90))
        XCTAssertEqual(identity.bounded(.identity, measured: roll(80), ageMs: 0), .identity)
    }
}
