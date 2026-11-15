import simd
import XCTest
@testable import TeleopCore

/// Tap-to-go in the input rules: a short, still touch that began inside the guide's view from above with nothing
/// engaged sends the arm to the place drawn under it, at the travel height, unless something refuses it. Every other
/// touch keeps its 1.0.1 meaning.
final class TapToGoTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// The arm at the box's centre, at the travel height.
    private let arm = SIMD3(0.027617, -0.177418, Rig.travelZ)
    /// Inside the panel, on a half in both schemes (x 167.8): left of and below the panel's centre.
    private let point = Rig.inPanel(0.3, 0.65)
    /// Inside the panel, in scheme B's centre band.
    private let centre = Rig.inPanel(0.5, 0.65)

    private func aided(_ scheme: InputScheme = .screenTurns, assist: Assist = Rig.goTo()) -> Rig {
        var rig = Rig(scheme, assist: assist)
        rig.facts = Rig.goFacts(arm: arm)
        return rig
    }

    /// The same script on a rig with tap-to-go and on a 1.0.1 rig given the same facts.
    private func both(_ scheme: InputScheme, _ script: (inout Rig) -> [[InputCommand]]) -> (on: Rig, off: Rig) {
        var on = aided(scheme)
        var off = aided(scheme, assist: .off)
        XCTAssertEqual(script(&on), script(&off), "\(scheme)")
        return (on, off)
    }

    func testATapStartsAGoTowardTheTappedPointAtTravelHeight() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = aided(scheme)
            XCTAssertEqual(rig.touchDown(1, at: point, after: 0.1), [], "\(scheme)")
            XCTAssertEqual(rig.phase(.touch(1)), .waiting, "\(scheme)")
            XCTAssertEqual(rig.lift(1, after: 0.08), [.startTranslation], "\(scheme)")
            let target = Rig.target(of: point)
            XCTAssertEqual(rig.arbiter.engagement, .going(target: target, since: rig.time), "\(scheme)")
            XCTAssertEqual(target.z, Rig.travelZ, "exactly the travel height above the table")
            // The place drawn under the finger: a fifth of the 20.8 cm view left of the centre, 15% nearer.
            XCTAssertEqual(target.x, 0.027617 + 0.2 * 0.208, accuracy: 1e-9)
            XCTAssertEqual(target.y, -0.177418 + 0.15 * 0.208, accuracy: 1e-9)
            XCTAssertEqual(rig.arbiter.startsThisCall, [.going], "\(scheme)")
            XCTAssertEqual(rig.arbiter.engagedHold, .translation, "the session runs one translation hold for it")
            XCTAssertEqual(rig.arbiter.goOffset(at: rig.time), .zero, "it starts where the arm is")
            XCTAssertTrue(rig.arbiter.held.isEmpty)
        }
    }

    /// Refused as a held start is, with the refusal's NO and reason, and nothing starts.
    func testATapIsRefusedForEachPadRefusal() {
        for refusal in [InputRefusal.noLink, .stopped, .slowLink, .settingsOpen, .wait] {
            var rig = aided()
            rig.facts.refusal = refusal
            XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.cue(.refused(refusal))], "\(refusal)")
            XCTAssertNil(rig.arbiter.engagement, "\(refusal)")
            XCTAssertEqual(rig.arbiter.startsThisCall, [], "\(refusal)")
        }
    }

    /// The phone does not steer the move, so its tracking and posture are no reasons.
    func testATapIsNotRefusedForTrackingOrPosture() {
        var rig = aided()
        rig.facts.trackingRefusal = .notTracking
        rig.facts.translationRefusal = .posture
        XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.startTranslation])
        XCTAssertTrue(rig.isGoing)
    }

    /// A tap in the panel's margin around the box asks for a place outside it: refused, with no slack.
    func testATargetOutsideTheBoxIsRefused() {
        for (across, down) in [(0.05, 0.5), (0.95, 0.5), (0.5, 0.05), (0.5, 0.95), (0.1, 0.1)] {
            var rig = aided()
            XCTAssertEqual(
                rig.tap(1, at: Rig.inPanel(across, down), after: 0.1), [.cue(.refused(.outsideWorkArea))],
                "\(across), \(down)")
            XCTAssertNil(rig.arbiter.engagement)
        }
        // The box as drawn, moved by the reading's box shift: a place in the profile's box but outside the drawn one.
        var shifted = aided()
        shifted.facts.goPanel = Rig.panel(shift: SIMD3(0, 0, 0.1))
        XCTAssertLessThan(Rig.travelZ, Rig.boxLow.z + 0.1)
        XCTAssertGreaterThan(Rig.travelZ, Rig.boxLow.z)
        XCTAssertEqual(
            shifted.tap(1, at: point, after: 0.1), [.cue(.refused(.outsideWorkArea))], "the travel height under it")
    }

    /// A travel height that puts the target above the box is refused for every tap.
    func testATravelHeightOutsideTheBoxIsRefused() {
        var limits = Rig.goLimits
        limits.travelHeightM = 0.12
        var rig = aided(assist: Rig.goTo(limits))
        XCTAssertGreaterThan(Rig.table + 0.12, Rig.boxHigh.z)
        XCTAssertEqual(rig.tap(1, at: Rig.inPanel(0.5, 0.5), after: 0.1), [.cue(.refused(.outsideWorkArea))])
        XCTAssertNil(rig.arbiter.engagement)
    }

    /// The move starts from a measured position: none, or one older than 0.4 s, refuses the tap.
    func testATapWithNoFreshArmIsRefused() {
        for (name, fix) in [("no position", nil), ("0.41 s old", 0.41)] as [(String, Double?)] {
            var rig = aided()
            rig.facts = Rig.goFacts(arm: fix == nil ? nil : arm, ageS: fix ?? 0)
            XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.cue(.refused(.noArmData))], name)
            XCTAssertNil(rig.arbiter.engagement, name)
        }
        var rig = aided()
        rig.facts = Rig.goFacts(arm: arm, ageS: 0.4)
        XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.startTranslation], "0.4 s old is still fresh")
    }

    /// The arm within 8 mm of the place tapped: "Arrived.", and nothing moves.
    func testATapOnTheArmItselfSaysArrivedAndMovesNothing() {
        let target = Rig.target(of: point)
        for offset in [SIMD3<Double>.zero, SIMD3(0.007, 0, 0), SIMD3(0, -0.004, 0.006)] {
            var rig = aided()
            rig.facts = Rig.goFacts(arm: target + offset)
            XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.cue(.drive(.arrived))], "\(offset)")
            XCTAssertNil(rig.arbiter.engagement)
            XCTAssertEqual(rig.arbiter.startsThisCall, [])
        }
        var near = aided()
        near.facts = Rig.goFacts(arm: target + SIMD3(0.0081, 0, 0))
        XCTAssertEqual(near.tap(1, at: point, after: 0.1), [.startTranslation], "8.1 mm away goes")
    }

    /// The whole touch counts: one that went 4 mm away and came back is no tap; one that went 2.9 mm is.
    func testAnExcursionOverThreeMillimetresThatComesBackIsNotATap() {
        let mm = Rig.pointsPerMm
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            let (on, _) = both(scheme) { rig in
                [
                    rig.touchDown(1, at: point, after: 0.1),
                    rig.move(1, to: point + SIMD2(4 * mm, 0), after: 0.03),
                    rig.move(1, to: point, after: 0.03),
                    rig.lift(1, after: 0.03),
                ]
            }
            XCTAssertNil(on.arbiter.engagement, "\(scheme)")
        }
        var rig = aided()
        rig.touchDown(1, at: point, after: 0.1)
        rig.move(1, to: point + SIMD2(0, 2.9 * mm), after: 0.03)
        rig.move(1, to: point, after: 0.03)
        XCTAssertEqual(rig.lift(1, after: 0.03), [.startTranslation])
    }

    /// A tap goes to the place under the finger where it came down, not where its last sample was: a thumb that drifted
    /// 2 mm before it lifted, still a tap, sends the arm to its touch-down point.
    func testATapGoesToItsTouchDownPointNotItsLastSample() {
        let drifted = point + SIMD2(0, 2 * Rig.pointsPerMm)
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = aided(scheme)
            rig.touchDown(1, at: point, after: 0.1)
            rig.move(1, to: drifted, after: 0.03)
            XCTAssertEqual(rig.lift(1, after: 0.03), [.startTranslation], "\(scheme): still a tap")
            XCTAssertEqual(rig.arbiter.engagement, .going(target: Rig.target(of: point), since: rig.time), "\(scheme)")
            XCTAssertGreaterThan(
                simd_distance(Rig.target(of: drifted), Rig.target(of: point)), 0.002,
                "the drifted point asks for another place")
        }
    }

    /// The lift sample counts too: a lift that lands 4 mm away is no tap, although no move came before it.
    func testALiftFarAwayIsNotATap() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            let away = point + SIMD2(0, -4 * Rig.pointsPerMm)
            let (on, _) = both(scheme) { rig in
                [
                    rig.touchDown(1, at: point, after: 0.1),
                    rig.send(rig.sample(1, .ended, away, radius: 8), after: 0.08),
                ]
            }
            XCTAssertNil(on.arbiter.engagement, "\(scheme)")
        }
    }

    /// A lift sample as wide as a palm is no tap, although the palm window was over and 1.0.1 ignores it then.
    func testAPalmWideLiftIsNotATap() {
        let away = point + SIMD2(Rig.pointsPerMm, 0)
        let (on, off) = both(.screenTurns) { rig in
            [
                rig.touchDown(1, at: point, radius: 20, after: 0.1),
                rig.send(rig.sample(1, .ended, away, radius: 130), after: 0.2),
            ]
        }
        XCTAssertNil(on.arbiter.engagement)
        XCTAssertEqual(on.log, off.log, "no start, no cue")

        var narrow = aided()
        narrow.touchDown(1, at: point, radius: 20, after: 0.1)
        XCTAssertEqual(
            narrow.send(narrow.sample(1, .ended, away, radius: 20), after: 0.2), [.startTranslation],
            "the same touch lifted narrow")
    }

    /// Scheme A: a touch that lingers past 0.30 s, turns the phone 5 degrees or slides 10 mm up does what it does in
    /// 1.0.1, and is no tap.
    func testSchemeAATouchThatLingersOrTurnsOrSlidesIsOneZeroOne() {
        let lingers = both(.screenTurns) { rig in
            [rig.touchDown(1, at: point, after: 0.1), rig.lift(1, after: 0.31)]
        }
        XCTAssertNil(lingers.on.arbiter.engagement)
        // Both commit after the palm window and lift well inside 0.30 s.
        let turns = both(.screenTurns) { rig in
            [
                rig.touchDown(1, at: point, after: 0.1), rig.wait(0.1),
                rig.rotate(turn: 6, steps: 3, dt: 0.02), rig.lift(1, after: 0.02),
            ]
        }
        XCTAssertTrue(turns.off.log.contains(.startWrist), "the wrist")
        XCTAssertNil(turns.on.arbiter.engagement)
        let slides = both(.screenTurns) { rig in
            [
                rig.touchDown(1, at: point, after: 0.1), rig.wait(0.1),
                rig.slide(1, mm: 10, degrees: 90), rig.lift(1, after: 0.01),
            ]
        }
        XCTAssertTrue(slides.off.log.contains(.startGripper(.open)), "the jaws open")
        XCTAssertNil(slides.on.arbiter.engagement)
    }

    /// Scheme B on a half: a tap lifted before its dwell goes; one held through the dwell moves the jaws as before.
    func testSchemeBAHalfTapLiftedBeforeItsDwellGoesAndOneHeldClosesAsBefore() {
        var rig = aided(.keyTurns)
        rig.touchDown(1, at: point, after: 0.1)
        XCTAssertEqual(rig.lift(1, after: 0.149), [.startTranslation])

        let near = Rig.inPanel(0.7, 0.65)
        XCTAssertEqual(ArbiterRig.layout.side(x: near.x, hand: .right), .near)
        let held = both(.keyTurns) { rig in
            [rig.touchDown(1, at: near, after: 0.1), rig.wait(0.2), rig.lift(1, after: 0.05)]
        }
        XCTAssertEqual(held.off.log.suffix(2), [.startGripper(.closed), .stopGripper])
        XCTAssertNil(held.on.arbiter.engagement)
    }

    /// The dwell completes before a lift at 151 ms: a jaw move, as in 1.0.1, and no tap.
    func testSchemeBALiftAt151msIsAJawMove() {
        let (on, off) = both(.keyTurns) { rig in
            [rig.touchDown(1, at: point, after: 0.1), rig.lift(1, after: 0.151)]
        }
        XCTAssertEqual(off.log.suffix(2), [.startGripper(.open), .stopGripper])
        XCTAssertNil(on.arbiter.engagement)
    }

    /// Scheme B's centre band, dead and silent in 1.0.1, takes a tap inside the panel and does nothing else there.
    func testSchemeBTheCentreBandInsideThePanelTakesTapsAndNothingElse() {
        var rig = aided(.keyTurns)
        XCTAssertEqual(ArbiterRig.layout.side(x: centre.x, hand: .right), .centre)
        rig.touchDown(1, at: centre, after: 0.1)
        XCTAssertEqual(rig.phase(.touch(1)), .dead, "reported as 1.0.1 reports it")
        XCTAssertEqual(rig.lift(1, after: 0.08), [.startTranslation])

        let nothingElse = both(.keyTurns) { rig in
            [
                rig.touchDown(1, at: centre, after: 0.1), rig.wait(0.6), rig.lift(1),
                rig.touchDown(2, at: centre, after: 0.1), rig.slide(2, mm: 12, degrees: 90), rig.lift(2),
                rig.touchDown(3, at: centre, after: 0.1), rig.slide(3, mm: 12, degrees: 0), rig.lift(3),
            ]
        }
        XCTAssertEqual(nothingElse.off.log, [], "dead and silent")
        XCTAssertNil(nothingElse.on.arbiter.engagement)
    }

    func testATouchOutsideThePanelLiftedQuicklyDoesNothing() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            for outside in [Rig.middle, Rig.rightHalf, Rig.inPanel(-0.02, 0.5), Rig.inPanel(0.5, 1)] {
                let (on, off) = both(scheme) { rig in
                    [rig.touchDown(1, at: outside, after: 0.1), rig.lift(1, after: 0.08)]
                }
                XCTAssertEqual(off.log, [], "\(scheme) \(outside)")
                XCTAssertNil(on.arbiter.engagement)
            }
        }
    }

    /// Without tap-to-go, or with no panel drawn, the same touches are 1.0.1's.
    func testWithoutGoToOrPanelEveryTouchIsOneZeroOne() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            let script: (inout Rig) -> [[InputCommand]] = { rig in
                [
                    rig.tap(1, at: self.point, after: 0.1), rig.tap(2, at: self.centre, after: 0.1),
                    rig.tap(3, at: self.point, lastingS: 0.2, after: 0.1),
                ]
            }
            var off = aided(scheme, assist: .off)
            let expected = script(&off)
            var noGoTo = aided(scheme, assist: Rig.lockPressPress())
            XCTAssertEqual(script(&noGoTo), expected, "\(scheme): lock alone")
            var noPanel = aided(scheme)
            noPanel.facts.goPanel = nil
            XCTAssertEqual(script(&noPanel), expected, "\(scheme): no panel drawn")
            XCTAssertNil(noPanel.arbiter.engagement)
        }
    }

    /// One thing at a time: a touch that begins during a hold or the countdown is dead from its touch-down, as in
    /// 1.0.1, and never a tap, also when the hold or the countdown ends before its quick lift.
    func testATouchDuringAHoldOrTheCountdownIsNeverATap() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            let duringAHold = both(scheme) { rig in
                [
                    rig.press(.upper, after: 0.1), rig.tap(1, at: self.point, after: 0.1),
                    rig.tap(2, at: self.centre, after: 0.1), rig.release(.upper, after: 0.1),
                ]
            }
            XCTAssertNil(duringAHold.on.arbiter.engagement, "\(scheme)")
            let heldUntilJustBefore = both(scheme) { rig in
                [
                    rig.press(.upper, after: 0.1), rig.touchDown(1, at: self.centre, after: 0.05),
                    rig.release(.upper, after: 0.05), rig.lift(1, after: 0.05),
                    rig.press(.upper, after: 0.5), rig.touchDown(2, at: self.point, after: 0.05),
                    rig.release(.upper, after: 0.05), rig.lift(2, after: 0.05),
                ]
            }
            XCTAssertNil(heldUntilJustBefore.on.arbiter.engagement, "\(scheme)")
            let duringTheCountdown = both(scheme) { rig in
                [
                    rig.touchDown(9, at: Rig.topBand, after: 0.1), rig.wait(0.15),
                    rig.touchDown(1, at: self.point, after: 0.1), rig.lift(9, after: 0.05),
                    rig.lift(1, after: 0.05),
                ]
            }
            XCTAssertTrue(duringTheCountdown.off.log.contains(.resetCountdownStarted), "\(scheme)")
            XCTAssertNil(duringTheCountdown.on.arbiter.engagement, "\(scheme)")
            // Down first, undecided or in scheme B's centre band, when the countdown starts: dead from then on.
            let downWhenItStarts = both(scheme) { rig in
                [
                    rig.touchDown(1, at: self.centre, after: 0.1), rig.touchDown(9, at: Rig.topBand, after: 0.01),
                    rig.wait(0.1), rig.lift(9, after: 0.05), rig.lift(1, after: 0.05),
                ]
            }
            XCTAssertTrue(downWhenItStarts.off.log.contains(.resetCountdownStarted), "\(scheme)")
            XCTAssertNil(downWhenItStarts.on.arbiter.engagement, "\(scheme)")
        }
    }

    /// A key wins over an undecided touch, and over one that could only have been a tap.
    func testAKeyDownKillsAnUndecidedTap() {
        for (scheme, p) in [(InputScheme.screenTurns, point), (.keyTurns, point), (.keyTurns, centre)] {
            let (on, _) = both(scheme) { rig in
                [
                    rig.touchDown(1, at: p, after: 0.1), rig.press(.lower, after: 0.02),
                    rig.release(.lower, after: 0.02), rig.lift(1, after: 0.02),
                ]
            }
            XCTAssertNil(on.arbiter.engagement, "\(scheme) \(p)")
        }
    }

    /// A tap is judged against the panel of its touch-down: a panel drawn elsewhere by the lift changes nothing, a
    /// touch that began with no panel drawn is no tap, and one whose panel went away before the lift still is.
    func testThePanelOfTheTouchDownJudgesTheTap() {
        let moved = Rig.panel(SurfaceLayout.Rect(x: 140, y: 300, width: 120, height: 120))
        var rig = aided()
        rig.touchDown(1, at: point, after: 0.1)
        rig.facts.goPanel = moved
        XCTAssertEqual(rig.lift(1, after: 0.08), [.startTranslation])
        XCTAssertEqual(rig.arbiter.engagement, .going(target: Rig.target(of: point), since: rig.time))
        XCTAssertNotEqual(Rig.target(of: point, on: moved), Rig.target(of: point))

        var none = aided()
        none.facts.goPanel = nil
        none.touchDown(1, at: point, after: 0.1)
        none.facts.goPanel = Rig.panel()
        XCTAssertEqual(none.lift(1, after: 0.08), [], "no panel at its touch-down")

        var gone = aided()
        gone.touchDown(1, at: point, after: 0.1)
        gone.facts.goPanel = nil
        XCTAssertEqual(gone.lift(1, after: 0.08), [.startTranslation], "its panel went away before the lift")
    }

    /// The facts of a call are from before a STOP in it, so a tap after the STOP in the same call is refused as the
    /// robot being stopped.
    func testATapAfterStopInTheSameCallIsRefused() {
        var rig = aided()
        rig.touchDown(1, at: point, after: 0.1)
        let stop = rig.sample(2, .began, Rig.bottomBand, radius: 8)
        let lift = rig.sample(1, .ended, point, radius: 8)
        XCTAssertEqual(rig.batch([stop, lift], after: 0.08), [.emergencyStop, .cue(.refused(.stopped))])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.arbiter.startsThisCall, [])
    }

    /// A tap is before a STOP in the same call in time: it goes, and the STOP ends it, with the stop going out first
    /// and no ending cue of the move's own. The start is still recorded as a move to a point, for its owner to carry.
    func testATapBeforeStopInTheSameCallIsRecordedAsGoing() {
        var rig = aided()
        rig.touchDown(1, at: point, after: 0.1)
        let lift = rig.sample(1, .ended, point, radius: 8)
        let stop = rig.sample(2, .began, Rig.bottomBand, radius: 8)
        XCTAssertEqual(rig.batch([lift, stop], after: 0.08), [.startTranslation, .emergencyStop, .stopTranslation])
        XCTAssertEqual(rig.arbiter.startsThisCall, [.going])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertNil(rig.arbiter.goOffset(at: rig.time))
    }
}
