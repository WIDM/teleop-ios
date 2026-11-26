import simd
import XCTest
@testable import TeleopCore

/// Lock, variant 2: while the upper key holds the arm, a thumb slid up the glass latches the follow, anywhere on the
/// control surface. A NO the thumb would owe in 1.0.1 waits while its slide is under way, and plays if it ends without
/// a latch; a thumb that does not slide is 1.0.1's.
final class LockHoldSlideTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// A rig in `scheme` with variant 2 and the upper key holding the arm.
    private func holding(_ scheme: InputScheme) -> Rig {
        var rig = Rig(scheme, assist: Rig.lockHoldSlide())
        XCTAssertEqual(rig.press(.upper, after: 0.1), [.startTranslation])
        return rig
    }

    private var latched: [InputCommand] { [.cue(.drive(.latched))] }

    func testSchemeAAThumbSlidingUpTenMillimetresLatches() {
        var rig = holding(.screenTurns)
        XCTAssertEqual(rig.touchDown(1, at: Rig.middle, after: 0.1), [])
        XCTAssertEqual(rig.wait(0.1), [])
        XCTAssertEqual(rig.slide(1, mm: 9, degrees: 90), [])
        XCTAssertEqual(rig.slide(1, mm: 1, degrees: 90), latched, "the latch, and no NO for the slide")
        XCTAssertEqual(rig.arbiter.engagement, .latched(since: rig.time))
        XCTAssertEqual(rig.phase(.key(.upper)), .dead)
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90), [])
        XCTAssertEqual(rig.rotate(turn: 20), [])
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertFalse(rig.log.contains(.cue(.dead)))
    }

    /// The centre band, where 1.0.1 makes every touch dead and silent, latches on a slide up.
    func testSchemeBTheCentreBandLatches() {
        var off = Rig(.keyTurns)
        off.press(.upper, after: 0.1)
        off.touchDown(1, at: Rig.middle, after: 0.1)
        off.wait(0.1)
        XCTAssertEqual(off.slide(1, mm: 12, degrees: 90), [], "1.0.1: silent")

        var rig = holding(.keyTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90), latched)
        XCTAssertTrue(rig.isLatched)
    }

    /// 12 mm over half a second runs past the 150 ms dwell: the dwell's NO waits, and the latch drops it.
    func testSchemeBASlowSlideOnAHalfWithholdsTheDwellNOAndLatches() {
        var rig = holding(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf, after: 0.1)
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90, dt: 0.5 / 12), latched)
        XCTAssertTrue(rig.isLatched)
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertFalse(rig.log.contains(.cue(.dead)))
    }

    /// 6 mm up, past the dwell, then lifted: the NO it withheld plays at the lift.
    func testSchemeBAWithheldNOPlaysWhenTheThumbLiftsShort() {
        var rig = holding(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf, after: 0.1)
        XCTAssertEqual(rig.slide(1, mm: 6, degrees: 90, dt: 0.04), [], "the dwell came at 4 mm: withheld")
        XCTAssertEqual(rig.lift(1, after: 0.1), [.cue(.dead)])
        XCTAssertEqual(rig.arbiter.engagement, .held(.key(.upper), .translation))
        XCTAssertEqual(rig.release(.upper, after: 0.1), [.stopTranslation])
    }

    /// The phone turned while the slide was under way: the turn's NO waits, and plays once the slide stops being
    /// mostly up.
    func testSchemeAAWithheldTurnNOPlaysWhenTheSlideTurnsSideways() {
        var rig = holding(.screenTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 5, degrees: 90), [])
        XCTAssertEqual(rig.rotate(turn: 8), [], "1.0.1 plays its NO here")
        XCTAssertEqual(rig.slide(1, mm: 4, degrees: 0), [], "still more up than sideways")
        XCTAssertEqual(rig.slide(1, mm: 1, degrees: 0), [.cue(.dead)], "as far sideways as up: no longer mostly up")
        XCTAssertEqual(rig.slide(1, mm: 20, degrees: 90), [], "spent: it never latches now")
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertEqual(rig.arbiter.engagement, .held(.key(.upper), .translation))
    }

    /// The 1.0.1 scripts of a thumb landing during a vol+ hold (`ScreenTurnsTests` A-3d, `KeyTurnsTests` B-6), with the
    /// slides up that would now latch taken out: the same commands at the same times.
    func testAThumbThatDoesNotSlideIsOneZeroOne() {
        let screenTurns: (inout Rig) -> [[InputCommand]] = { rig in
            [
                rig.press(.upper),
                rig.touchDown(1, at: Rig.middle),
                rig.lift(1, after: 0.2),
                rig.touchDown(2, at: Rig.middle, after: 0.1),
                rig.rotate(turn: 8, steps: 3, dt: 0.02),
                rig.wait(0.05),
                rig.lift(2),
                rig.orient(turn: 0),
                rig.touchDown(3, at: Rig.middle, after: 0.1),
                rig.slide(3, mm: 12, degrees: 0, dt: 0.02),
                rig.slide(3, mm: 15, degrees: 90),
                rig.release(.upper),
            ]
        }
        let keyTurns: (inout Rig) -> [[InputCommand]] = { rig in
            [
                rig.press(.upper),
                rig.touchDown(1, at: Rig.rightHalf),
                rig.wait(0.149),
                rig.wait(0.001),
                rig.wait(1),
                rig.lift(1),
                rig.touchDown(2, at: Rig.leftHalf),
                rig.lift(2, after: 0.1),
                rig.touchDown(3, at: Rig.leftHalf),
                rig.wait(0.1),
                rig.wait(0.5),
                rig.lift(3),
                rig.touchDown(4, at: Rig.middle),
                rig.wait(0.5),
                rig.release(.upper),
            ]
        }
        for (scheme, script) in [(InputScheme.screenTurns, screenTurns), (.keyTurns, keyTurns)] {
            var off = Rig(scheme)
            var on = Rig(scheme, assist: Rig.lockHoldSlide())
            let expected = script(&off)
            XCTAssertEqual(script(&on), expected, "\(scheme)")
            XCTAssertTrue(expected.joined().contains(.cue(.dead)), "\(scheme): the script has its NOs")
        }
    }

    /// A thumb that played its NO is spent: a slide after it does not latch.
    func testAThumbThatPlayedItsNOCannotLatch() {
        var rig = holding(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf, after: 0.1)
        XCTAssertEqual(rig.wait(0.15), [.cue(.dead)], "the dwell, with no slide under way")
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90), [])
        XCTAssertEqual(rig.arbiter.engagement, .held(.key(.upper), .translation))
    }

    /// A slide that was judged sideways never latches, even if it later goes up.
    func testASidewaysSlideNeverLatches() {
        var rig = holding(.screenTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 30), [])
        XCTAssertEqual(rig.slide(1, mm: 25, degrees: 90), [])
        XCTAssertEqual(rig.arbiter.engagement, .held(.key(.upper), .translation))

        var schemeB = holding(.keyTurns)
        schemeB.touchDown(1, at: Rig.middle, after: 0.1)
        schemeB.wait(0.1)
        XCTAssertEqual(schemeB.slide(1, mm: 14, degrees: 140), [])
        XCTAssertEqual(schemeB.slide(1, mm: 25, degrees: 90), [])
        XCTAssertEqual(schemeB.arbiter.engagement, .held(.key(.upper), .translation))
    }

    /// The phone tipped when the slide reaches 10 mm: no latch, and the NO 1.0.1 plays at that slide plays then.
    func testAPostureRefusalAtTheSlidePlaysTheOwedNOAndDoesNotLatch() {
        var off = Rig(.screenTurns)
        off.press(.upper, after: 0.1)
        off.touchDown(1, at: Rig.middle, after: 0.1)
        off.wait(0.1)
        off.slide(1, mm: 9, degrees: 90)
        off.facts.translationRefusal = .posture
        let expected = off.slide(1, mm: 1, degrees: 90)
        XCTAssertEqual(expected, [.cue(.dead)])

        var rig = holding(.screenTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 9, degrees: 90), [])
        rig.facts.translationRefusal = .posture
        XCTAssertEqual(rig.slide(1, mm: 1, degrees: 90), expected)
        XCTAssertEqual(rig.arbiter.engagement, .held(.key(.upper), .translation))
        rig.facts.translationRefusal = nil
        XCTAssertEqual(rig.slide(1, mm: 5, degrees: 90), [], "spent")
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])
    }

    /// Once latched, the upper key is dead: its release does nothing, and a new press ends the follow.
    func testReleasingTheKeyAfterTheLatchDoesNothing() {
        var rig = holding(.screenTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90), latched)
        XCTAssertEqual(rig.release(.upper, after: 0.3), [])
        XCTAssertEqual(rig.lift(1, after: 0.3), [])
        XCTAssertTrue(rig.isLatched)
        XCTAssertNil(rig.phase(.key(.upper)))
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.stopTranslation, .cue(.drive(.stoppedByYou))])
    }

    /// The key let go before the slide is done: the hold stops, the attempt with it, and the NO it withheld plays
    /// after the stop. A slide after that latches nothing.
    func testTheKeyReleasedBeforeTheSlideEndsTheAttempt() {
        var rig = holding(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf, after: 0.1)
        XCTAssertEqual(rig.slide(1, mm: 5, degrees: 90, dt: 0.04), [], "the dwell's NO withheld")
        XCTAssertEqual(rig.release(.upper), [.stopTranslation, .cue(.dead)])
        XCTAssertEqual(rig.slide(1, mm: 8, degrees: 90), [])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.lift(1), [])
    }

    /// A STOP in the call where the slide reaches 10 mm ends the attempt: nothing latches, in that call or in the next
    /// ones, even with no fact refusing and the thumb still up the glass. The NO the slide withheld plays after the
    /// stop.
    func testNoLatchInACallWithAStop() {
        var rig = holding(.screenTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        rig.slide(1, mm: 9, degrees: 90)
        let up = rig.sample(1, .moved, Rig.middle - SIMD2(0, 10 * Rig.pointsPerMm), radius: 8)
        let stop = rig.sample(2, .began, Rig.bottomBand, radius: 8)
        XCTAssertEqual(rig.batch([up, stop], after: 0.01), [.emergencyStop, .cue(.dead)])
        XCTAssertEqual(rig.facts, InputFacts(), "nothing refuses in the calls that follow")
        XCTAssertEqual(rig.wait(0.01), [], "no latch in the next call")
        XCTAssertEqual(rig.move(1, to: Rig.middle - SIMD2(0, 12 * Rig.pointsPerMm), after: 0.01), [])
        XCTAssertEqual(rig.wait(0.1), [])
        XCTAssertEqual(rig.arbiter.engagement, .held(.key(.upper), .translation))
        XCTAssertEqual(rig.send(.holdsEnded(.announced), after: 0.05), [.stopTranslation], "the NO played once")

        // With no connection up, the STOP's own refusal comes first, then the NO the attempt was holding back.
        var unlinked = holding(.screenTurns)
        unlinked.facts.connectionUp = false
        unlinked.touchDown(1, at: Rig.middle, after: 0.1)
        unlinked.wait(0.1)
        unlinked.slide(1, mm: 9, degrees: 90)
        XCTAssertEqual(
            unlinked.batch([up, stop], after: 0.01), [.emergencyStop, .cue(.refused(.notStopped)), .cue(.dead)])
    }

    /// A thumb that lands after a STOP in the same call is no latch attempt: it is 1.0.1's thumb, and its slide up in
    /// the next calls latches nothing.
    func testAThumbDownAfterAStopInItsCallCannotLatch() {
        let script: (inout Rig) -> [[InputCommand]] = { rig in
            let stop = rig.sample(2, .began, Rig.bottomBand, radius: 8)
            let thumb = rig.sample(1, .began, Rig.middle, radius: 8)
            return [
                rig.press(.upper, after: 0.1),
                rig.batch([stop, thumb], after: 0.1),
                rig.move(1, to: Rig.middle, after: 0.1),
                rig.slide(1, mm: 12, degrees: 90),
                rig.wait(0.1),
                rig.send(.holdsEnded(.announced), after: 0.05),
            ]
        }
        var off = Rig(.screenTurns)
        var on = Rig(.screenTurns, assist: Rig.lockHoldSlide())
        let expected = script(&off)
        XCTAssertEqual(script(&on), expected)
        XCTAssertTrue(expected.joined().contains(.cue(.dead)), "1.0.1 plays the slide's NO")
        XCTAssertFalse(on.log.contains(.cue(.drive(.latched))))
    }

    /// A gear touch and a top band touch that went down during the hold say nothing once the thumb latches: no
    /// "Let go first." when their palm window ends, none when they lift.
    func testInputsDownAtTheLatchAreDeadAndSilent() {
        var off = Rig(.screenTurns)
        off.press(.upper, after: 0.1)
        off.touchDown(2, at: Rig.gear, after: 0.05)
        XCTAssertEqual(off.wait(0.11), [.cue(.refused(.letGoFirst))], "1.0.1, the hold still engaged")

        var rig = holding(.screenTurns)
        rig.touchDown(1, at: Rig.middle, after: 0.01)
        rig.touchDown(2, at: Rig.gear, after: 0.04)
        rig.touchDown(3, at: Rig.topBand, after: 0.01)
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90, dt: 0.001), [], "inside its palm window")
        XCTAssertEqual(rig.wait(0.05), latched, "once the window is over")
        XCTAssertEqual(rig.wait(0.1), [], "the gear's and the band's palm windows end")
        XCTAssertEqual(rig.lift(2, after: 0.05), [])
        XCTAssertEqual(rig.lift(3, after: 0.05), [])
        XCTAssertEqual(rig.release(.upper, after: 0.05), [])
        XCTAssertEqual(rig.lift(1, after: 0.05), [])
        XCTAssertTrue(rig.isLatched)
    }
}
