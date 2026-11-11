import XCTest
@testable import TeleopCore

/// Scheme B, "Key turns": one test per row of §2.5. Right hand unless a test says otherwise, so the near half is the
/// right half.
final class KeyTurnsTests: XCTestCase {
    typealias Rig = ArbiterRig

    func testB1VolUpStartsAndStopsTranslation() {
        var rig = Rig(.keyTurns)
        XCTAssertEqual(rig.press(.upper), [.startTranslation])
        XCTAssertEqual(rig.release(.upper, after: 0.4), [.stopTranslation])
    }

    func testB2VolDownStartsTheWristAtOnceWithTheIdentity() {
        var rig = Rig(.keyTurns)
        XCTAssertEqual(rig.press(.lower), [.startWrist, .wristUpdate(.identity)])
        XCTAssertEqual(rig.phase(.key(.lower)), .engaged(.wrist))
        // Identity until one axis reaches 5° and dominates.
        XCTAssertTrue(rig.rotate(turn: 4.9, tilt: 2).wristTargets.allSatisfy { $0 == .identity })
        let committed = rig.orient(turn: 5.2).wristTargets
        XCTAssertEqual(committed.first?.axis, .turn)
        // Scheme B starts from what it was sending, zero, and catches up through the smoothing.
        XCTAssertEqual(committed.first?.degrees, 0)
        var targets = rig.rotate(turn: 70, tilt: 2, steps: 60)
        XCTAssertEqual(targets.cues, [.limit])
        for _ in 0..<10 { targets += rig.orient(after: 1.0 / 60) }
        XCTAssertEqual(targets.wristTargets.last?.degrees ?? 0, 55, accuracy: 1e-6)
        XCTAssertTrue(targets.wristTargets.allSatisfy { $0.axis == .turn })
    }

    func testB2AnchorsAtThePressNotAtRest() {
        var rig = Rig(.keyTurns)
        rig.orient(turn: 30, tilt: -10)
        rig.press(.lower, after: 0.1)
        XCTAssertTrue(rig.rotate(turn: 33, tilt: -10).wristTargets.allSatisfy { $0 == .identity })
        let tilted = rig.rotate(tilt: -4, steps: 20).wristTargets
        XCTAssertEqual(tilted.last?.axis, .tilt)
    }

    func testB2RefusedWithoutTracking() {
        var rig = Rig(.keyTurns)
        rig.facts.trackingRefusal = .notTracking
        XCTAssertEqual(rig.press(.lower), [.cue(.refused(.notTracking))])
        XCTAssertEqual(rig.rotate(turn: 10), [])
        XCTAssertEqual(rig.release(.lower), [])
    }

    func testB2rVolDownEndedStopsTheWrist() {
        var rig = Rig(.keyTurns)
        rig.press(.lower)
        rig.rotate(tilt: 9)
        XCTAssertEqual(rig.release(.lower, after: 0.2), [.stopWrist])
        XCTAssertEqual(rig.rotate(tilt: 15), [])
    }

    func testB3TheNearHalfClosesAfterTheDwell() {
        var rig = Rig(.keyTurns)
        XCTAssertEqual(rig.touchDown(1, at: Rig.rightHalf), [])
        XCTAssertEqual(rig.wait(0.149), [])
        XCTAssertEqual(rig.wait(0.001), [.startGripper(.closed)])
        XCTAssertEqual(rig.phase(.touch(1)), .engaged(.gripper(.closed)))
    }

    func testB3TheFarHalfOpensAfterTheDwell() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.leftHalf)
        XCTAssertEqual(rig.wait(0.15), [.startGripper(.open)])
    }

    func testB3TheHandSettingSwapsTheHalves() {
        var rig = Rig(.keyTurns, hand: .left)
        rig.touchDown(1, at: Rig.leftHalf)
        XCTAssertEqual(rig.wait(0.15), [.startGripper(.closed)])
        rig.lift(1)
        rig.touchDown(2, at: Rig.rightHalf, after: 0.5)
        XCTAssertEqual(rig.wait(0.15), [.startGripper(.open)])
    }

    func testB3TheCentreBandIsDeadAndSilent() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.middle + SIMD2(20, 0))
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertEqual(rig.lift(1), [])
    }

    func testB3NeedsTheTouchStillDownAtTheEndOfTheDwell() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        // Lifted at 149 ms without any tick in between: nothing, ever.
        XCTAssertEqual(rig.lift(1, after: 0.149), [])
        XCTAssertEqual(rig.wait(1), [])
        // Lifted at 151 ms without any tick: the dwell completed while it was down, so the jaws moved and stop.
        rig.touchDown(2, at: Rig.rightHalf, after: 0.5)
        XCTAssertEqual(rig.lift(2, after: 0.151), [.startGripper(.closed), .stopGripper])
    }

    func testB3gOpeningWhileGrippingNeedsTheLongDwell() {
        var rig = Rig(.keyTurns)
        rig.facts.gripping = true
        rig.touchDown(1, at: Rig.leftHalf)
        XCTAssertEqual(rig.wait(0.15), [])
        XCTAssertEqual(rig.wait(0.349), [])
        XCTAssertEqual(rig.wait(0.001), [.startGripper(.open)])
        // A stray touch that lifts before 500 ms drops nothing.
        rig.lift(1)
        rig.touchDown(2, at: Rig.leftHalf, after: 0.5)
        XCTAssertEqual(rig.lift(2, after: 0.4), [])
    }

    func testB3cClosingWhileGrippingIsRefusedWithEnd() {
        var rig = Rig(.keyTurns)
        rig.facts.gripping = true
        rig.touchDown(1, at: Rig.rightHalf)
        XCTAssertEqual(rig.wait(0.15), [.cue(.alreadyGripping)])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertEqual(rig.lift(1), [])
    }

    func testB3mASwipeWithinTheDwellIsDead() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 9, degrees: 180, dt: 0.003), [])
        XCTAssertEqual(rig.slide(1, mm: 1, degrees: 180, dt: 0.003), [.cue(.dead)])
        XCTAssertEqual(rig.wait(0.2), [], "the dwell cannot complete")
        XCTAssertEqual(rig.lift(1), [])
    }

    func testB3mASwipeInsideThePalmWindowCuesWhenItEnds() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.leftHalf)
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90, dt: 0.004), [])
        XCTAssertEqual(rig.wait(0.052), [.cue(.dead)])
    }

    func testB3mMovingLessThanTenMillimetresIsStill() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        rig.slide(1, mm: 9, degrees: 45, dt: 0.01)
        XCTAssertEqual(rig.wait(0.06), [.startGripper(.closed)])
    }

    func testB3uATapNeverMovesTheJaws() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.leftHalf)
        rig.wait(0.12)
        XCTAssertEqual(rig.lift(1, after: 0.01), [])
        XCTAssertEqual(rig.wait(1), [])
        // A dead touch that lifts is silent too.
        rig.touchDown(2, at: Rig.leftHalf)
        rig.wait(0.1)
        rig.slide(2, mm: 10, degrees: 0, dt: 0.001)
        XCTAssertEqual(rig.lift(2), [])
    }

    func testB3rReleasingAGripperTouchStopsItAndCrossingTheCentreChangesNothing() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        rig.wait(0.15)
        XCTAssertEqual(rig.slide(1, mm: 40, degrees: 180), [])
        XCTAssertEqual(rig.lift(1, after: 0.3), [.stopGripper])

        rig.touchDown(2, at: Rig.leftHalf, after: 0.5)
        rig.wait(0.15)
        XCTAssertEqual(rig.lift(2, after: 0.2), [.stopGripper])
    }

    func testB4AKeyDuringTheDwellWinsAndTheTouchDiesSilently() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        rig.wait(0.12)
        XCTAssertEqual(rig.press(.upper), [.startTranslation])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])
        XCTAssertEqual(rig.wait(1), [], "releasing the key does not wake the touch")

        var wrist = Rig(.keyTurns)
        wrist.touchDown(1, at: Rig.leftHalf)
        XCTAssertEqual(wrist.press(.lower, after: 0.05), [.startWrist, .wristUpdate(.identity)])
        XCTAssertEqual(wrist.wait(1), [])
    }

    func testB5AKeyWhileAGripperTouchIsEngagedIsDead() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        rig.wait(0.15)
        XCTAssertEqual(rig.press(.lower), [.cue(.dead)])
        XCTAssertEqual(rig.rotate(turn: 20), [])
        XCTAssertEqual(rig.press(.upper), [.cue(.dead)])
        XCTAssertEqual(rig.lift(1), [.stopGripper])
        XCTAssertEqual(rig.release(.lower), [])
        XCTAssertEqual(rig.release(.upper), [])
    }

    func testB6ATouchWhileAKeyHoldIsEngagedCuesWhenItsDwellWouldHaveCompleted() {
        var rig = Rig(.keyTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.touchDown(1, at: Rig.rightHalf), [])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(0.149), [])
        XCTAssertEqual(rig.wait(0.001), [.cue(.dead)])
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertEqual(rig.lift(1), [])

        // One that lifts first, or swipes, or sits in the centre band, never would have acted: silent.
        rig.touchDown(2, at: Rig.leftHalf)
        XCTAssertEqual(rig.lift(2, after: 0.1), [])
        rig.touchDown(3, at: Rig.leftHalf)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(3, mm: 10, degrees: 90, dt: 0.001), [])
        XCTAssertEqual(rig.wait(0.5), [])
        rig.lift(3)
        rig.touchDown(4, at: Rig.middle)
        XCTAssertEqual(rig.wait(0.5), [])
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])
    }

    func testB6WhileGrippingTheFarHalfCuesAtTheLongDwell() {
        var rig = Rig(.keyTurns)
        rig.facts.gripping = true
        rig.press(.lower)
        rig.touchDown(1, at: Rig.leftHalf)
        XCTAssertEqual(rig.wait(0.45).withoutUpdates, [])
        XCTAssertEqual(rig.wait(0.05).withoutUpdates, [.cue(.dead)])
    }
}
