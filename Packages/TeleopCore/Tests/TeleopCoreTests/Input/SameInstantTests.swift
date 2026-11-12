import XCTest
@testable import TeleopCore

/// Events that share a timestamp: with each other (one `handle` call) and with a timer that runs out at that instant.
final class SameInstantTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// A scheme A thumb past its palm window, the phone turned 4°: one more sample at 8° would commit the wrist.
    private func undecidedThumb() -> Rig {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.15)
        rig.orient(turn: 4, after: 0.01)
        rig.turn = 8
        return rig
    }

    // MARK: One call

    func testNothingStartsInTheCallThatEndsEveryHold() {
        var rig = undecidedThumb()
        XCTAssertEqual(rig.batch([.endAllHolds, .attitude(rig.attitude)], after: 0.016), [])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)

        var modeRig = undecidedThumb()
        XCTAssertEqual(modeRig.batch([.modeChanged(.keyTurns, .right), .attitude(modeRig.attitude)], after: 0.016), [])
    }

    func testALiftGivenBeforeAnAttitudeSampleStartsNothing() {
        var rig = undecidedThumb()
        XCTAssertEqual(
            rig.batch([rig.sample(1, .ended, Rig.middle, radius: 8), .attitude(rig.attitude)], after: 0.016), [])
    }

    func testAnAttitudeSampleGivenFirstIsJudgedFirst() {
        var rig = undecidedThumb()
        let commands = rig.batch([.attitude(rig.attitude), rig.sample(1, .ended, Rig.middle, radius: 8)], after: 0.016)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist, .stopWrist])
    }

    func testAnAttitudeSampleStillGoesBeforeAMoveBehindATick() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.slide(1, mm: 9, degrees: 90)
        rig.turn = 6
        let up = Rig.middle + SIMD2(0, -10 * Rig.pointsPerMm)
        let commands = rig.batch([rig.sample(1, .moved, up, radius: 8), .tick, .attitude(rig.attitude)], after: 0.01)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist])
    }

    func testAnAttitudeSampleStillGoesBeforeAMoveBehindAKeyUpThatDoesNothing() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.slide(1, mm: 9, degrees: 90)
        rig.turn = 6
        let up = Rig.middle + SIMD2(0, -10 * Rig.pointsPerMm)
        // vol+ is not down, so its key-up does nothing.
        let commands = rig.batch(
            [rig.sample(1, .moved, up, radius: 8), .keyUp(.upper), .attitude(rig.attitude)], after: 0.01)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist])
    }

    func testAnAttitudeSampleNeverGoesBeforeAKeyUpThatEndsAHold() {
        var rig = Rig(.keyTurns)
        rig.press(.lower)
        rig.rotate(turn: 10)
        rig.turn = 20
        XCTAssertEqual(rig.batch([.keyUp(.lower), .attitude(rig.attitude)], after: 0.016), [.stopWrist])
        // Nor before one that ends a hold pressed earlier in the same call.
        rig.turn = 30
        XCTAssertEqual(
            rig.batch([.keyDown(.lower), .keyUp(.lower), .attitude(rig.attitude)], after: 1),
            [.startWrist, .wristUpdate(.identity), .stopWrist])
    }

    // MARK: An event at a timer's deadline

    func testAPalmSampleAtTheEndOfThePalmWindowIsStillAPalm() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.slide(1, mm: 11, degrees: 90, dt: 0.005)
        let top = Rig.middle + SIMD2(0, -11 * Rig.pointsPerMm)
        XCTAssertEqual(rig.move(1, to: top, radius: 40, after: 0.045), [])
        XCTAssertEqual(rig.wait(0.5), [])
        XCTAssertNil(rig.phase(.touch(1)), "ignored as a palm")
    }

    func testAPalmSampleAtTheEndOfTheTopBandPalmWindowIsStillAPalm() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        XCTAssertEqual(rig.move(1, to: Rig.topBand, radius: 40, after: 0.1), [])
        XCTAssertEqual(rig.wait(3), [])
        XCTAssertNil(rig.phase(.touch(1)), "ignored as a palm")
    }

    func testAPalmSampleAfterTheTopBandWindowRanOutAtTheSameInstantLeavesTheCountdownRunning() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        XCTAssertEqual(rig.wait(0.1), [.resetCountdownStarted])
        XCTAssertEqual(rig.move(1, to: Rig.topBand, radius: 40), [])
        XCTAssertEqual(rig.phase(.touch(1)), .countingDown)
        XCTAssertEqual(rig.wait(1.9), [.fireReset])
    }

    func testAnAttitudeSampleAtTheEndOfThePalmWindowIsJudgedWithTheSlide() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.slide(1, mm: 11, degrees: 90, dt: 0.005)
        rig.turn = 8
        // The slide crossed 10 mm inside the window; the dominant turn arrives exactly as it ends. Attitude first.
        XCTAssertEqual(rig.send(.attitude(rig.attitude), after: 0.045).withoutUpdates, [.startWrist])
    }

    func testALiftAtTheEndOfTheDwellIsATap() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        XCTAssertEqual(rig.lift(1, after: 0.15), [])
        XCTAssertEqual(rig.wait(1), [])
    }

    func testReachingTenMillimetresAtTheEndOfTheDwellIsASwipe() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        rig.wait(0.14)
        XCTAssertEqual(rig.move(1, to: Rig.rightHalf + SIMD2(0, -9 * Rig.pointsPerMm)), [])
        XCTAssertEqual(rig.move(1, to: Rig.rightHalf + SIMD2(0, -10 * Rig.pointsPerMm), after: 0.01), [.cue(.dead)])
        XCTAssertEqual(rig.wait(1), [])
    }

    func testLiftingTheTopBandAtTwoSecondsCancelsTheReset() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(0.1)
        XCTAssertEqual(rig.lift(1, after: 1.9), [.resetCountdownCancelled])
    }

    func testLeavingAtTwoSecondsCancelsTheReset() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(0.1)
        XCTAssertEqual(rig.send(.endAllHolds, after: 1.9), [.resetCountdownCancelled])
    }

    func testATimerThatRanOutBeforeTheEventStillFiresFirst() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(0.1)
        XCTAssertEqual(rig.send(.endAllHolds, after: 1.901), [.fireReset])
    }
}
