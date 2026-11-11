import XCTest
@testable import TeleopCore

/// §2.2: the zones and the filters (C-I3).
final class TouchFilterTests: XCTestCase {
    typealias Rig = ArbiterRig

    func testAPalmAtTouchDownIsIgnoredInTheControlSurface() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = Rig(scheme)
            XCTAssertEqual(rig.touchDown(1, at: Rig.rightHalf, radius: 32), [])
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
        // 12 mm up in 60 ms, then the contact grows past 32 pt at 80 ms: never opens, never cues.
        rig.slide(1, mm: 12, degrees: 90, dt: 0.005)
        XCTAssertEqual(rig.move(1, to: Rig.middle + SIMD2(0, -12 * Rig.pointsPerMm), radius: 35, after: 0.02), [])
        XCTAssertEqual(rig.wait(0.5), [])
        XCTAssertNil(rig.phase(.touch(1)))
        XCTAssertEqual(rig.rotate(turn: 20), [])

        var b = Rig(.keyTurns)
        b.touchDown(1, at: Rig.rightHalf, radius: 20)
        XCTAssertEqual(b.move(1, to: Rig.rightHalf, radius: 33, after: 0.09), [])
        XCTAssertEqual(b.wait(1), [], "no dwell completes for a palm")
    }

    func testARadiusGrowingAfterTheWindowChangesNothing() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90), [.startGripper(.open)])
        XCTAssertEqual(rig.move(1, to: Rig.middle, radius: 40, after: 0.1), [])
        XCTAssertEqual(rig.lift(1), [.stopGripper])

        var b = Rig(.keyTurns)
        b.touchDown(1, at: Rig.leftHalf)
        b.move(1, to: Rig.leftHalf, radius: 40, after: 0.12)
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
        XCTAssertEqual(rig.touchDown(2, at: Rig.bottomBand, radius: 60), [.emergencyStop])
        XCTAssertEqual(rig.touchDown(3, at: SIMD2(4, 800), radius: 10), [.emergencyStop], "edges count there too")
    }

    func testARestingFingerAtTheEdgeAndAPalmInTheTopBandDoNotReset() {
        var rig = Rig(.screenTurns)
        // A finger wrapped round the edge.
        rig.touchDown(1, at: SIMD2(6, 100))
        // The heel of the hand, large at touch-down.
        rig.touchDown(2, at: SIMD2(300, 100), radius: 45)
        // A contact that grows into a palm inside the window.
        rig.touchDown(3, at: SIMD2(200, 110), radius: 15)
        rig.move(3, to: SIMD2(200, 110), radius: 34, after: 0.05)
        XCTAssertEqual(rig.wait(3), [])
        XCTAssertFalse(rig.arbiter.isHoldingAnInput)
    }

    func testAPalmOnTheGearDoesNotOpenSettings() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.gear, radius: 40)
        XCTAssertEqual(rig.lift(1, after: 0.2), [])
    }
}
