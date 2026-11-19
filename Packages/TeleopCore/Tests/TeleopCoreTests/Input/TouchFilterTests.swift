import XCTest
@testable import TeleopCore

/// §2.2: the zones and the filters (C-I3).
final class TouchFilterTests: XCTestCase {
    typealias Rig = ArbiterRig

    func testAPalmAtTouchDownIsIgnoredInTheControlSurface() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = Rig(scheme)
            XCTAssertEqual(rig.touchDown(1, at: Rig.rightHalf, radius: 91), [])
            XCTAssertNil(rig.phase(.touch(1)))
            XCTAssertEqual(rig.wait(0.5), [])
            XCTAssertEqual(rig.slide(1, mm: 20, degrees: 90), [])
            XCTAssertEqual(rig.rotate(turn: 20), [])
            XCTAssertEqual(rig.lift(1), [])
        }
    }

    func testAPalmGrowingInsideTheWindowIsCaughtBeforeAFastCommit() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle, radius: 12)
        // 12 mm up in 60 ms, then the contact grows past 91 pt at 80 ms: never opens, never cues.
        rig.slide(1, mm: 12, degrees: 90, dt: 0.005)
        XCTAssertEqual(rig.move(1, to: Rig.middle + SIMD2(0, -12 * Rig.pointsPerMm), radius: 97, after: 0.02), [])
        XCTAssertEqual(rig.wait(0.5), [])
        XCTAssertNil(rig.phase(.touch(1)))
        XCTAssertEqual(rig.rotate(turn: 20), [])

        var b = Rig(.keyTurns)
        b.touchDown(1, at: Rig.rightHalf, radius: 61)
        XCTAssertEqual(b.move(1, to: Rig.rightHalf, radius: 97, after: 0.09), [])
        XCTAssertEqual(b.wait(1), [], "no dwell completes for a palm")
    }

    func testARadiusGrowingAfterTheWindowChangesNothing() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90), [.startGripper(.open)])
        XCTAssertEqual(rig.move(1, to: Rig.middle, radius: 109, after: 0.1), [])
        XCTAssertEqual(rig.lift(1), [.stopGripper])

        var b = Rig(.keyTurns)
        b.touchDown(1, at: Rig.leftHalf)
        b.move(1, to: Rig.leftHalf, radius: 109, after: 0.12)
        XCTAssertEqual(b.wait(0.03), [.startGripper(.open)])
    }

    func testAnEdgeGripIsIgnored() {
        var rig = Rig(.keyTurns)
        XCTAssertEqual(rig.touchDown(1, at: SIMD2(8, 440)), [])
        XCTAssertEqual(rig.touchDown(2, at: SIMD2(395, 300)), [])
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertFalse(rig.arbiter.isHoldingAnInput)
        // An edge touch does not block the thumb either.
        rig.touchDown(3, at: Rig.rightHalf)
        XCTAssertEqual(rig.wait(0.15), [.startGripper(.closed)])
    }

    func testExtraTouchesAreIgnored() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        XCTAssertEqual(rig.touchDown(2, at: Rig.leftHalf, after: 0.02), [])
        XCTAssertNil(rig.phase(.touch(2)))
        XCTAssertEqual(rig.wait(0.2), [.startGripper(.closed)])
        XCTAssertEqual(rig.lift(1), [.stopGripper])
        // Still ignored after the first lifts.
        XCTAssertEqual(rig.wait(1), [])

        // A dead touch is still a tracked thumb.
        var a = Rig(.screenTurns)
        a.touchDown(1, at: Rig.middle)
        a.wait(0.1)
        a.slide(1, mm: 10, degrees: 0)
        a.touchDown(2, at: Rig.middle + SIMD2(0, 100))
        a.wait(0.1)
        XCTAssertEqual(a.slide(2, mm: 10, degrees: 90), [])
    }

    func testASlideIntoABandNeverFiresIt() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: SIMD2(201, 700))
        rig.wait(0.1)
        // Straight down into the gap and the bottom band: A-5's NO, but no STOP.
        XCTAssertEqual(rig.slide(1, mm: 25, degrees: 270), [.cue(.dead)])
        rig.lift(1)
        rig.touchDown(2, at: Rig.gap)
        XCTAssertEqual(rig.slide(2, mm: 15, degrees: 270), [])
        rig.lift(2)
        // Up into the top band: no countdown.
        rig.touchDown(3, at: SIMD2(201, 140))
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(3, mm: 10, degrees: 90), [.startGripper(.open)])
        XCTAssertEqual(rig.wait(3), [])
        // From the top band into the control surface: still only a countdown.
        rig.lift(3)
        rig.touchDown(4, at: Rig.topBand)
        XCTAssertEqual(rig.slide(4, mm: 20, degrees: 270, dt: 0.004), [])
        XCTAssertEqual(rig.wait(0.2), [.resetCountdownStarted])
        XCTAssertEqual(rig.wait(2), [.fireReset])
    }

    func testTheGapDoesNothing() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = Rig(scheme)
            XCTAssertEqual(rig.touchDown(1, at: Rig.gap), [])
            XCTAssertEqual(rig.wait(3), [])
            XCTAssertEqual(rig.rotate(turn: 20), [])
            XCTAssertEqual(rig.lift(1), [])
            XCTAssertFalse(rig.arbiter.isHoldingAnInput)
        }
    }

    func testAPalmInTheBottomBandStillStopsTheRobot() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        XCTAssertEqual(rig.touchDown(2, at: Rig.bottomBand, radius: 121), [.emergencyStop])
        XCTAssertEqual(rig.touchDown(3, at: SIMD2(4, 800), radius: 10), [.emergencyStop], "edges count there too")
    }

    func testARestingFingerAtTheEdgeAndAPalmInTheTopBandDoNotReset() {
        var rig = Rig(.screenTurns)
        // A finger wrapped round the edge.
        rig.touchDown(1, at: SIMD2(6, 100))
        // The heel of the hand, large at touch-down.
        rig.touchDown(2, at: SIMD2(300, 100), radius: 97)
        // A contact that grows into a palm inside the window.
        rig.touchDown(3, at: SIMD2(200, 110), radius: 61)
        rig.move(3, to: SIMD2(200, 110), radius: 97, after: 0.05)
        XCTAssertEqual(rig.wait(3), [])
        XCTAssertFalse(rig.arbiter.isHoldingAnInput)
    }

    func testAPalmOnTheGearDoesNotOpenSettings() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.gear, radius: 97)
        XCTAssertEqual(rig.lift(1, after: 0.2), [])
    }

    /// The widest contacts a thumb made on a phone: 61 pt at touch-down growing to 85 pt inside the window, and
    /// wider still afterwards. Every one of them acts.
    func testAThumbPadAsWideAsOneMeasuredOnAPhoneIsNotAPalm() {
        var a = Rig(.screenTurns)
        a.touchDown(1, at: Rig.middle, radius: 61)
        a.move(1, to: Rig.middle, radius: 85, after: 0.04)
        a.wait(0.07)
        XCTAssertEqual(a.slide(1, mm: 10, degrees: 90), [.startGripper(.open)])
        XCTAssertEqual(a.move(1, to: Rig.middle + SIMD2(0, -10 * Rig.pointsPerMm), radius: 109, after: 0.1), [])
        XCTAssertEqual(a.lift(1), [.stopGripper])

        var turn = Rig(.screenTurns)
        turn.touchDown(1, at: Rig.middle, radius: 49)
        turn.move(1, to: Rig.middle, radius: 73, after: 0.05)
        turn.wait(0.1)
        XCTAssertEqual(turn.rotate(turn: 20).withoutUpdates, [.startWrist])

        var b = Rig(.keyTurns)
        b.touchDown(1, at: Rig.rightHalf, radius: 49)
        b.move(1, to: Rig.rightHalf, radius: 73, after: 0.05)
        XCTAssertEqual(b.wait(0.15), [.startGripper(.closed)])

        var gear = Rig(.screenTurns)
        gear.touchDown(1, at: Rig.gear, radius: 49)
        XCTAssertEqual(gear.lift(1, after: 0.1), [.openSettings])

        var band = Rig(.screenTurns)
        band.touchDown(1, at: Rig.topBand, radius: 49)
        band.move(1, to: Rig.topBand, radius: 61, after: 0.05)
        XCTAssertEqual(band.wait(0.2), [.resetCountdownStarted])
        XCTAssertEqual(band.wait(2), [.fireReset])
    }

    /// The rule is "this wide or wider": 91 pt is a palm and a hair less is not, at touch-down and inside the window.
    func testThePalmRadiusIsInclusive() {
        let limit = InputConstants.appendixA.palmRadiusPt
        XCTAssertEqual(limit, 91)

        var at = Rig(.screenTurns)
        at.touchDown(1, at: Rig.gear, radius: limit)
        XCTAssertEqual(at.lift(1, after: 0.2), [])
        var under = Rig(.screenTurns)
        under.touchDown(1, at: Rig.gear, radius: limit - 0.01)
        XCTAssertEqual(under.lift(1, after: 0.2), [.openSettings])

        var grown = Rig(.screenTurns)
        grown.touchDown(1, at: Rig.middle, radius: 61)
        grown.move(1, to: Rig.middle, radius: limit, after: 0.05)
        grown.wait(0.1)
        XCTAssertEqual(grown.slide(1, mm: 10, degrees: 90), [])
        var almost = Rig(.screenTurns)
        almost.touchDown(1, at: Rig.middle, radius: 61)
        almost.move(1, to: Rig.middle, radius: limit - 0.01, after: 0.05)
        almost.wait(0.1)
        XCTAssertEqual(almost.slide(1, mm: 10, degrees: 90), [.startGripper(.open)])
    }

    /// The sample that lifts a contact is judged like the ones before it.
    func testAContactThatIsAPalmWhenItLiftsInsideTheWindowIsIgnored() {
        var gear = Rig(.screenTurns)
        gear.touchDown(1, at: Rig.gear, radius: 61)
        XCTAssertEqual(gear.lift(1, radius: 97, after: 0.08), [], "a palm brushing the gear opens nothing")

        var thumb = Rig(.screenTurns)
        thumb.touchDown(1, at: Rig.gear, radius: 61)
        XCTAssertEqual(thumb.lift(1, radius: 85, after: 0.08), [.openSettings])

        // Past the window the radius changes nothing, as for a move.
        var late = Rig(.screenTurns)
        late.touchDown(1, at: Rig.gear, radius: 61)
        XCTAssertEqual(late.lift(1, radius: 97, after: 0.2), [.openSettings])

        // A top band touch that owes "Let go first." stays silent when it turns out to be a palm.
        var owing = Rig(.screenTurns)
        owing.press(.upper)
        owing.touchDown(1, at: Rig.topBand, radius: 61, after: 0.3)
        XCTAssertEqual(owing.lift(1, radius: 97, after: 0.05), [])
        owing.touchDown(2, at: Rig.topBand, radius: 61, after: 0.3)
        XCTAssertEqual(owing.lift(2, after: 0.05), [.cue(.refused(.letGoFirst))])
    }

    /// The narrowest palm measured on the same phone: 61 pt at touch-down, 97 pt inside the window.
    func testThePalmMeasuredOnAPhoneIsStillIgnored() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = Rig(scheme)
            rig.touchDown(1, at: Rig.leftHalf, radius: 61)
            XCTAssertEqual(rig.move(1, to: Rig.leftHalf, radius: 97, after: 0.05), [])
            XCTAssertEqual(rig.wait(1), [])
            XCTAssertEqual(rig.rotate(turn: 20), [])
            XCTAssertEqual(rig.slide(1, mm: 20, degrees: 90), [])
            XCTAssertEqual(rig.lift(1), [])
            XCTAssertFalse(rig.arbiter.isHoldingAnInput)
        }
    }
}
