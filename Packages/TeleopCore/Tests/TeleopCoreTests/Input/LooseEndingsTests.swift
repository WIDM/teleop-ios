import simd
import XCTest
@testable import TeleopCore

/// Every way a move nobody holds ends: each stops it exactly once and plays the cue its ending gives, and an input
/// that ends it does nothing else until released. Inputs that were already down when it began end nothing and stay
/// silent. Run on a follow latched by a press of the upper key, and on a move to a tapped point.
final class LooseEndingsTests: XCTestCase {
    typealias Rig = ArbiterRig

    private let stoppedByYou: [InputCommand] = [.stopTranslation, .cue(.drive(.stoppedByYou))]

    /// A rig in `scheme` with a follow latched by a press of the upper key, already released.
    private func latched(_ scheme: InputScheme = .screenTurns, limit: Double = 30) -> Rig {
        var rig = Rig(scheme, assist: Rig.lockPressPress(limit: limit))
        rig.latchByPress(after: 0.1)
        XCTAssertTrue(rig.isLatched)
        return rig
    }

    private func ended(_ end: DriveEnd) -> [InputCommand] { [.stopTranslation, .cue(.drive(.ended(end)))] }

    // MARK: Inputs

    /// A press of either key ends it at once, ahead of the 1.0.1 key checks: the lower key inside the replay guard of
    /// the upper key's release, the upper key again, and a key held from before the app left.
    func testEitherKeyEndsItWithStoppedByYouEvenInsideTheReplayGuard() {
        for key in [InputKey.upper, .lower] {
            var rig = latched()
            XCTAssertEqual(rig.press(key, after: 0.05), stoppedByYou, "\(key)")
            XCTAssertNil(rig.arbiter.engagement, "\(key)")
            XCTAssertEqual(rig.phase(.key(key)), .dead, "\(key)")
            XCTAssertEqual(rig.rotate(turn: 15), [], "\(key): no wrist")
            XCTAssertEqual(rig.wait(1), [], "\(key)")
            XCTAssertEqual(rig.release(key, after: 0.3), [], "\(key)")
        }

        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        rig.press(.lower, after: 0.1)
        rig.send(.becameActive, after: 0.2)
        rig.latchByPress(after: 0.3)
        XCTAssertTrue(rig.isLatched, "a stale key is not a key down")
        XCTAssertEqual(rig.press(.lower, after: 0.2), stoppedByYou, "the stale key pressed again")
        XCTAssertEqual(rig.phase(.key(.lower)), .dead)
        XCTAssertEqual(rig.release(.lower, after: 0.2), [])
        XCTAssertNil(rig.phase(.key(.lower)), "released, it is no longer held, and no longer stale")
        XCTAssertEqual(rig.press(.lower, after: 0.5), [.startGripper(.closed)])
    }

    /// A new thumb ends it even while another thumb is tracked, which 1.0.1 would ignore. It then moves the jaws or
    /// the wrist no more than a dead thumb does.
    func testAnAcceptedTouchEndsItEvenWithAnotherThumbTracked() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        rig.touchDown(1, at: Rig.leftHalf, after: 0.1)
        rig.latchByPress(after: 0.05)
        XCTAssertTrue(rig.isLatched)
        XCTAssertEqual(rig.touchDown(2, at: Rig.rightHalf, after: 0.2), stoppedByYou)
        XCTAssertEqual(rig.phase(.touch(2)), .dead)
        XCTAssertEqual(rig.slide(2, mm: 12, degrees: 90), [], "no jaws")
        XCTAssertEqual(rig.rotate(turn: 20), [], "no wrist")
        XCTAssertEqual(rig.lift(2, after: 0.1), [])
        XCTAssertEqual(rig.lift(1, after: 0.1), [])
    }

    /// Scheme B's centre band, dead and silent in 1.0.1, ends it too.
    func testTheCentreBandTouchEndsIt() {
        var rig = latched(.keyTurns)
        XCTAssertEqual(rig.touchDown(1, at: Rig.middle, after: 0.2), stoppedByYou)
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(0.6), [], "no dwell")
        XCTAssertEqual(rig.lift(1), [])
    }

    func testTheTopBandTouchThatEndsItNeverCountsDown() {
        var rig = latched()
        XCTAssertEqual(rig.touchDown(1, at: Rig.topBand, after: 0.2), stoppedByYou)
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(0.1), [], "no \"Let go first.\" when its palm window ends")
        XCTAssertEqual(rig.wait(2.5), [], "no countdown")
        XCTAssertEqual(rig.lift(1), [])
    }

    func testTheGearTouchThatEndsItNeverOpensSettings() {
        var rig = latched()
        XCTAssertEqual(rig.touchDown(1, at: Rig.gear, after: 0.2), stoppedByYou)
        XCTAssertEqual(rig.lift(1, after: 0.2), [], "no Settings and no \"Let go first.\"")
    }

    /// A touch the filters drop, or one in the gap or the bottom safe area, is nothing, so it ends nothing.
    func testAFilteredTouchDoesNotEndIt() {
        let touches: [(String, SIMD2<Double>, Double)] = [
            ("a palm on the surface", Rig.middle, 130),
            ("a palm on the top band", Rig.topBand, 130),
            ("a palm on the gear", Rig.gear, 130),
            ("the side edge", SIMD2(5, 440), 8),
            ("the gap", Rig.gap, 8),
            ("the bottom safe area", SIMD2(201, 860), 8),
        ]
        for (name, point, radius) in touches {
            var rig = latched()
            XCTAssertEqual(rig.touchDown(1, at: point, radius: radius, after: 0.2), [], name)
            XCTAssertTrue(rig.isLatched, name)
            XCTAssertEqual(rig.lift(1, after: 0.2), [], name)
            XCTAssertTrue(rig.isLatched, name)
        }
    }

    // MARK: STOP

    func testStopEmitsTheEmergencyStopFirstAndNoDriveCue() {
        var rig = latched()
        XCTAssertEqual(rig.touchDown(1, at: Rig.bottomBand, after: 0.2), [.emergencyStop, .stopTranslation])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.lift(1, after: 0.2), [])
    }

    func testStopWithNoConnectionAddsOnlyTheOneZeroOneRefusal() {
        var rig = latched()
        rig.facts.connectionUp = false
        XCTAssertEqual(
            rig.touchDown(1, at: Rig.bottomBand, after: 0.2),
            [.emergencyStop, .stopTranslation, .cue(.refused(.notStopped))])
        XCTAssertNil(rig.arbiter.engagement)
    }

    /// The limit passed between calls; the next call holds a STOP. The STOP ends it, and no time limit is heard.
    func testStopEndsItAheadOfAnOverdueDeadline() {
        var rig = latched(limit: 1)
        var ticked = rig
        XCTAssertEqual(ticked.wait(1.5), ended(.timeLimit), "the overdue limit, had the call held no STOP")
        XCTAssertEqual(rig.touchDown(1, at: Rig.bottomBand, after: 1.5), [.emergencyStop, .stopTranslation])
        XCTAssertNil(rig.arbiter.engagement)
    }

    // MARK: Every hold ends

    func testEachInterruptionPlaysItsEnding() {
        let named: [(Interruption, DriveEnd)] = [
            (.unnamed, .unnamed), (.appLeft, .appLeft), (.cameraStopped, .cameraStopped),
            (.leftScreen, .leftScreen), (.slowLink, .slowLink),
        ]
        for (reason, end) in named {
            var rig = latched()
            XCTAssertEqual(rig.send(.holdsEnded(reason), after: 0.2), ended(end), "\(reason)")
            XCTAssertNil(rig.arbiter.engagement, "\(reason)")
        }
    }

    func testAnnouncedAndStartRefusedPlayNothing() {
        for reason in [Interruption.announced, .startRefused] {
            var rig = latched()
            XCTAssertEqual(rig.send(.holdsEnded(reason), after: 0.2), [.stopTranslation], "\(reason)")
            XCTAssertNil(rig.arbiter.engagement, "\(reason)")
        }
    }

    /// The shorthand names no reason, so a path written with it is heard: "Stopped here." alone.
    func testUnnamedSaysStoppedHere() {
        var rig = latched()
        XCTAssertEqual(rig.send(.endAllHolds, after: 0.2), [.stopTranslation, .cue(.drive(.ended(.unnamed)))])
        XCTAssertEqual(CueTable.row(for: .drive(.ended(.unnamed))).speech, [.driveStoppedHere])
    }

    /// Several endings in one call: the first stops it and plays its cue, the rest find nothing to end.
    func testTwoDoorsInOneCallStopOnce() {
        var rig = latched()
        rig.facts.translationRefusal = .posture
        let touch = rig.sample(1, .began, Rig.rightHalf, radius: 8)
        XCTAssertEqual(rig.batch([.keyDown(.lower), touch, .holdsEnded(.appLeft)], after: 0.2), stoppedByYou)
        XCTAssertNil(rig.arbiter.engagement)
    }

    /// Sent only from Settings, where nothing is engaged; should one come during a follow, it still ends heard.
    func testAModeOrAssistChangeEndsIt() {
        var rig = latched()
        XCTAssertEqual(rig.send(.modeChanged(.keyTurns, .left), after: 0.2), ended(.unnamed))
        XCTAssertEqual(rig.arbiter.scheme, .keyTurns)

        rig = latched()
        XCTAssertEqual(rig.send(.assistChanged(Rig.lockPressPress(limit: 10)), after: 0.2), ended(.unnamed))
        XCTAssertEqual(rig.arbiter.assist, Rig.lockPressPress(limit: 10))

        rig = latched()
        XCTAssertEqual(rig.send(.assistChanged(.off), after: 0.2), ended(.unnamed))
        XCTAssertEqual(rig.arbiter.assist, .off)
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.startTranslation], "a held start again")
    }

    /// Coming back to the app with no resign before it: the follow ran while the app was away.
    func testBecameActiveEndsIt() {
        var rig = latched()
        XCTAssertEqual(rig.send(.becameActive, after: 0.2), ended(.appLeft))
        XCTAssertNil(rig.arbiter.engagement)
    }

    /// The aids' configuration changing ends a hold tied to an input as a mode change does: the stop goes out, the
    /// key stays dead until released, and the rules hold the new configuration.
    func testAnAssistChangeEndsAHeldHold() {
        var rig = Rig(.screenTurns)
        XCTAssertEqual(rig.press(.upper, after: 0.1), [.startTranslation])
        XCTAssertEqual(rig.send(.assistChanged(Rig.lockPressPress()), after: 0.2), [.stopTranslation])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.phase(.key(.upper)), .dead)
        XCTAssertEqual(rig.arbiter.assist, Rig.lockPressPress())
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertEqual(rig.release(.upper, after: 0.2), [])
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.startTranslation, .cue(.drive(.latched))])

        var countdown = Rig(.screenTurns)
        countdown.touchDown(1, at: Rig.topBand, after: 0.1)
        XCTAssertEqual(countdown.wait(0.5), [.resetCountdownStarted])
        XCTAssertEqual(countdown.send(.assistChanged(Rig.lockPressPress()), after: 0.2), [.resetCountdownCancelled])
        XCTAssertEqual(countdown.wait(3), [], "the reset never fires")
    }

    // MARK: The gate

    /// "Wait" means the server shows a success or is resetting, and ends the hold itself: two seconds of it end
    /// nothing, and its final answer ends the follow silently. The refusals that mean the session cannot run a hold
    /// end it, heard as "Stopped here.".
    func testTheBackstopEndsItForNoLinkStoppedSlowLinkAndSettingsButNotForWait() {
        var rig = latched()
        rig.facts.refusal = .wait
        for _ in 0..<60 { XCTAssertEqual(rig.wait(1.0 / 30), []) }
        XCTAssertTrue(rig.isLatched)
        XCTAssertEqual(rig.send(.holdsEnded(.announced)), [.stopTranslation])

        for refusal in [InputRefusal.noLink, .stopped, .slowLink, .settingsOpen] {
            var rig = latched()
            rig.facts.refusal = refusal
            XCTAssertEqual(rig.wait(1.0 / 30), ended(.unnamed), "\(refusal)")
            XCTAssertNil(rig.arbiter.engagement, "\(refusal)")
        }
    }

    func testTrackingAndPostureEndItInTheGate() {
        var rig = latched()
        rig.facts.trackingRefusal = .notTracking
        XCTAssertEqual(rig.wait(0.1), ended(.tracking))

        rig = latched()
        rig.facts.translationRefusal = .posture
        XCTAssertEqual(rig.wait(0.1), ended(.posture))

        rig = latched()
        rig.facts.trackingRefusal = .notTracking
        rig.facts.translationRefusal = .posture
        XCTAssertEqual(rig.wait(0.1), ended(.tracking), "one ending, tracking first")
    }

    func testTheLimitEndsItInTheFirstCallAtOrAfterItsDeadline() {
        var rig = latched(limit: 2)
        let since = rig.time
        XCTAssertEqual(rig.arbiter.nextDeadline, since + 2)
        XCTAssertEqual(rig.wait(1.9), [])
        XCTAssertEqual(rig.wait(0.09), [])
        XCTAssertTrue(rig.isLatched)
        XCTAssertEqual(rig.wait(0.01), ended(.timeLimit), "at its deadline")
        XCTAssertNil(rig.arbiter.nextDeadline)

        rig = latched(limit: 2)
        XCTAssertEqual(rig.wait(7), ended(.timeLimit), "the first call after it, however late")
    }

    // MARK: What does nothing while it runs

    /// Inputs already down when the follow began end nothing and stay silent: a key held from before the app left, a
    /// thumb (undecided, or dead but owing a NO), a top band touch in its palm window and a gear touch.
    func testInputsDownWhenItBeganAreDeadAndSilent() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        rig.press(.lower, after: 0.1)
        rig.send(.becameActive, after: 0.2)
        rig.touchDown(1, at: Rig.middle, after: 0.2)
        rig.touchDown(2, at: Rig.gear, after: 0.2)
        let gearDown = rig.time
        rig.touchDown(3, at: Rig.topBand, after: 0.05)
        let bandWindowEnds = rig.time + rig.arbiter.constants.palmWindowMs / 1000
        XCTAssertEqual(rig.press(.upper, after: 0.02), [.startTranslation, .cue(.drive(.latched))])
        for input in [HeldInput.touch(1), .touch(2), .touch(3), .key(.upper)] {
            XCTAssertEqual(rig.phase(input), .dead, "\(input)")
        }
        // A top band touch still in its palm window when a hold begins says "Let go first." when the window ends, in
        // 1.0.1. This one, dead since the follow began, says nothing when its window ends inside this wait.
        XCTAssertLessThan(rig.time, bandWindowEnds)
        XCTAssertEqual(rig.wait(0.1), [], "the band's palm window passed: no \"Let go first.\"")
        XCTAssertGreaterThan(rig.time, bandWindowEnds, "the band's window ended inside the wait")
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90), [], "the thumb slid up")
        XCTAssertEqual(rig.rotate(turn: 8), [], "the phone turned")
        // A gear touch lifted inside its tap time is a tap: 1.0.1 opens Settings for it with nothing engaged, and says
        // "Let go first." with something engaged. This one, dead since the follow began, does neither.
        XCTAssertEqual(
            rig.lift(2, after: 0.02), [], "the gear lifted inside its tap time: no Settings, no \"Let go first.\"")
        XCTAssertLessThan(rig.time - gearDown, rig.arbiter.constants.gearTapS, "the gear's lift is a tap")
        XCTAssertEqual(rig.lift(3, after: 0.05), [], "the band lifted")
        XCTAssertEqual(rig.release(.lower, after: 0.05), [], "the stale key released")
        XCTAssertEqual(rig.lift(1, after: 0.05), [], "the thumb lifted")
        XCTAssertEqual(rig.release(.upper, after: 0.05), [])
        XCTAssertTrue(rig.isLatched, "none of them ended it")

        // A thumb that began during a hold owes a NO if it ever would act; once the follow begins it owes nothing.
        var owing = Rig(.screenTurns, assist: Rig.lockPressPress())
        owing.press(.lower, after: 0.1)
        owing.touchDown(1, at: Rig.middle, after: 0.1)
        owing.release(.lower, after: 0.1)
        XCTAssertEqual(owing.latchByPress(after: 0.3), [.startTranslation, .cue(.drive(.latched))])
        XCTAssertEqual(owing.rotate(turn: 10), [], "1.0.1 plays its NO here")
        XCTAssertEqual(owing.slide(1, mm: 12, degrees: 90), [])
        XCTAssertEqual(owing.lift(1, after: 0.1), [])
        XCTAssertTrue(owing.isLatched)

        var schemeB = Rig(.keyTurns, assist: Rig.lockPressPress())
        schemeB.touchDown(1, at: Rig.rightHalf, after: 0.1)
        XCTAssertEqual(schemeB.press(.upper, after: 0.05), [.startTranslation, .cue(.drive(.latched))])
        XCTAssertEqual(schemeB.wait(0.6), [], "no dwell")
        XCTAssertEqual(schemeB.lift(1), [])
        XCTAssertTrue(schemeB.isLatched)
    }

    /// The phone's turns are stored but steer nothing, and the scene reset and a wrist start going out change nothing.
    func testAttitudeSceneResetAndWristStartSentChangeNothing() {
        var rig = latched()
        XCTAssertEqual(rig.rotate(turn: 30, tilt: 10), [])
        XCTAssertEqual(rig.send(.sceneReset, after: 0.1), [])
        XCTAssertEqual(rig.send(.wristStartSent, after: 0.1), [])
        XCTAssertTrue(rig.isLatched)
    }

    // MARK: A move to a tapped point

    /// The arm at the box's centre, at the travel height, standing still: within the 2 s these tests run the move
    /// neither arrives nor is judged stalled.
    private let armStart = SIMD3(0.027617, -0.177418, Rig.travelZ)
    /// Inside the guide's panel, on a half in both schemes.
    private let tapPoint = Rig.inPanel(0.3, 0.65)

    /// A rig in `scheme` with a move going to `tapPoint`, started by a tap of touch 1.
    private func going(
        _ scheme: InputScheme = .screenTurns, limits: GoToLimits = Rig.goLimits, file: StaticString = #filePath,
        line: UInt = #line
    ) -> Rig {
        var rig = Rig(scheme, assist: Rig.goTo(limits))
        rig.facts = Rig.goFacts(arm: armStart)
        XCTAssertEqual(rig.tap(1, at: tapPoint, after: 0.1), [.startTranslation], file: file, line: line)
        XCTAssertTrue(rig.isGoing, file: file, line: line)
        return rig
    }

    func testEitherKeyEndsAGoingMove() {
        for key in [InputKey.upper, .lower] {
            var rig = going()
            XCTAssertEqual(rig.press(key, after: 0.1), stoppedByYou, "\(key)")
            XCTAssertNil(rig.arbiter.engagement, "\(key)")
            XCTAssertNil(rig.arbiter.goOffset(at: rig.time), "\(key)")
            XCTAssertEqual(rig.phase(.key(key)), .dead, "\(key)")
            XCTAssertEqual(rig.rotate(turn: 15), [], "\(key): no wrist")
            XCTAssertEqual(rig.release(key, after: 0.3), [], "\(key)")
        }
    }

    /// A new thumb anywhere on the surface ends it: in the panel, where its quick lift is no tap, and in scheme B's
    /// centre band. It then moves nothing.
    func testAnAcceptedTouchEndsAGoingMoveAndIsNoTap() {
        for (scheme, p) in [
            (InputScheme.screenTurns, tapPoint), (.keyTurns, tapPoint), (.keyTurns, Rig.middle),
            (.keyTurns, Rig.inPanel(0.5, 0.5)),
        ] {
            var rig = going(scheme)
            XCTAssertEqual(rig.touchDown(2, at: p, after: 0.2), stoppedByYou, "\(scheme) \(p)")
            XCTAssertEqual(rig.phase(.touch(2)), .dead, "\(scheme) \(p)")
            XCTAssertEqual(rig.lift(2, after: 0.05), [], "\(scheme) \(p): no tap")
            XCTAssertNil(rig.arbiter.engagement, "\(scheme) \(p)")
        }
        var rig = going(.keyTurns)
        rig.touchDown(2, at: Rig.rightHalf, after: 0.2)
        XCTAssertEqual(rig.wait(0.6), [], "no dwell")
        XCTAssertEqual(rig.slide(2, mm: 12, degrees: 90), [])
        XCTAssertEqual(rig.lift(2), [])
    }

    func testTheTopBandAndTheGearThatEndAGoingMoveDoNothingElse() {
        var band = going()
        XCTAssertEqual(band.touchDown(2, at: Rig.topBand, after: 0.2), stoppedByYou)
        XCTAssertEqual(band.wait(0.1), [], "no \"Let go first.\" when its palm window ends")
        XCTAssertEqual(band.wait(2.5), [], "no countdown")
        XCTAssertEqual(band.lift(2), [])

        var gear = going()
        XCTAssertEqual(gear.touchDown(2, at: Rig.gear, after: 0.2), stoppedByYou)
        XCTAssertEqual(gear.lift(2, after: 0.2), [], "no Settings and no \"Let go first.\"")
    }

    func testAFilteredTouchDoesNotEndAGoingMove() {
        let touches: [(String, SIMD2<Double>, Double)] = [
            ("a palm in the panel", tapPoint, 130), ("a palm on the gear", Rig.gear, 130),
            ("the side edge", SIMD2(5, 440), 8), ("the gap", Rig.gap, 8), ("the bottom safe area", SIMD2(201, 860), 8),
        ]
        for (name, point, radius) in touches {
            var rig = going()
            XCTAssertEqual(rig.touchDown(2, at: point, radius: radius, after: 0.2), [], name)
            XCTAssertEqual(rig.lift(2, after: 0.05), [], name)
            XCTAssertTrue(rig.isGoing, name)
        }
    }

    func testStopEndsAGoingMoveWithTheEmergencyStopFirstAndNoDriveCue() {
        var rig = going()
        XCTAssertEqual(rig.touchDown(2, at: Rig.bottomBand, after: 0.2), [.emergencyStop, .stopTranslation])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.lift(2, after: 0.2), [])

        var unlinked = going()
        unlinked.facts.connectionUp = false
        XCTAssertEqual(
            unlinked.touchDown(2, at: Rig.bottomBand, after: 0.2),
            [.emergencyStop, .stopTranslation, .cue(.refused(.notStopped))])
    }

    /// Its deadline passed between calls; the next call holds a STOP. The STOP ends it, and no time limit is heard.
    func testStopEndsAGoingMoveAheadOfAnOverdueDeadline() {
        var limits = Rig.goLimits
        limits.timeFactor = 1
        limits.allowanceS = 0
        var rig = going(limits: limits)
        var ticked = rig
        XCTAssertEqual(ticked.wait(1.5), ended(.timeLimit), "the overdue deadline, had the call held no STOP")
        XCTAssertEqual(rig.touchDown(2, at: Rig.bottomBand, after: 1.5), [.emergencyStop, .stopTranslation])
        XCTAssertNil(rig.arbiter.engagement)
    }

    func testEachInterruptionEndsAGoingMoveWithItsEnding() {
        let named: [(Interruption, DriveEnd)] = [
            (.unnamed, .unnamed), (.appLeft, .appLeft), (.cameraStopped, .cameraStopped),
            (.leftScreen, .leftScreen), (.slowLink, .slowLink),
        ]
        for (reason, end) in named {
            var rig = going()
            XCTAssertEqual(rig.send(.holdsEnded(reason), after: 0.2), ended(end), "\(reason)")
            XCTAssertNil(rig.arbiter.engagement, "\(reason)")
        }
        for reason in [Interruption.announced, .startRefused] {
            var rig = going()
            XCTAssertEqual(rig.send(.holdsEnded(reason), after: 0.2), [.stopTranslation], "\(reason)")
            XCTAssertNil(rig.arbiter.engagement, "\(reason)")
        }
    }

    func testTwoDoorsInOneCallStopAGoingMoveOnce() {
        var rig = going()
        let touch = rig.sample(2, .began, Rig.rightHalf, radius: 8)
        XCTAssertEqual(rig.batch([.keyDown(.lower), touch, .holdsEnded(.appLeft)], after: 0.2), stoppedByYou)
        XCTAssertNil(rig.arbiter.engagement)
    }

    func testAModeOrAssistChangeOrAReturnToTheAppEndsAGoingMove() {
        var rig = going()
        XCTAssertEqual(rig.send(.modeChanged(.keyTurns, .left), after: 0.2), ended(.unnamed))
        rig = going()
        XCTAssertEqual(rig.send(.assistChanged(.off), after: 0.2), ended(.unnamed))
        XCTAssertEqual(rig.arbiter.assist, .off)
        rig = going()
        XCTAssertEqual(rig.send(.becameActive, after: 0.2), ended(.appLeft))
        XCTAssertNil(rig.arbiter.engagement)
    }

    /// Two seconds of "wait" end nothing, and its final answer ends the move silently; the refusals that mean the
    /// session cannot run a hold end it, heard as "Stopped here.".
    func testTheBackstopEndsAGoingMoveButNotForWait() {
        var rig = going()
        rig.facts.refusal = .wait
        for _ in 0..<60 { XCTAssertEqual(rig.wait(1.0 / 30), []) }
        XCTAssertTrue(rig.isGoing)
        XCTAssertEqual(rig.send(.holdsEnded(.announced)), [.stopTranslation])

        for refusal in [InputRefusal.noLink, .stopped, .slowLink, .settingsOpen] {
            var rig = going()
            rig.facts.refusal = refusal
            XCTAssertEqual(rig.wait(1.0 / 30), ended(.unnamed), "\(refusal)")
            XCTAssertNil(rig.arbiter.engagement, "\(refusal)")
        }
    }

    /// Inputs already down when the tap started the move end nothing and stay silent: a key that was refused, a gear
    /// touch past its palm window and a top band touch still inside it.
    func testInputsDownWhenAGoBeganAreDeadAndSilent() {
        var rig = Rig(.screenTurns, assist: Rig.goTo())
        rig.facts = Rig.goFacts(arm: armStart)
        rig.facts.refusal = .wait
        XCTAssertEqual(rig.press(.upper, after: 0.1), [.cue(.refused(.wait))])
        rig.facts.refusal = nil
        rig.touchDown(2, at: Rig.gear, after: 0.1)
        let gearDown = rig.time
        rig.touchDown(1, at: tapPoint, after: 0.05)
        rig.touchDown(3, at: Rig.topBand, after: 0.05)
        let bandWindowEnds = rig.time + rig.arbiter.constants.palmWindowMs / 1000
        XCTAssertEqual(rig.lift(1, after: 0.03), [.startTranslation])
        for input in [HeldInput.touch(2), .touch(3), .key(.upper)] {
            XCTAssertEqual(rig.phase(input), .dead, "\(input)")
        }
        XCTAssertLessThan(rig.time, bandWindowEnds)
        XCTAssertEqual(rig.wait(0.1), [], "the band's palm window passed: no \"Let go first.\"")
        XCTAssertGreaterThan(rig.time, bandWindowEnds, "the band's window ended inside the wait")
        XCTAssertEqual(
            rig.lift(2, after: 0.02), [], "the gear lifted inside its tap time: no Settings, no \"Let go first.\"")
        XCTAssertLessThan(rig.time - gearDown, rig.arbiter.constants.gearTapS, "the gear's lift is a tap")
        XCTAssertEqual(rig.lift(3, after: 0.05), [], "the band lifted")
        XCTAssertEqual(rig.release(.upper, after: 0.05), [], "the refused key released")
        XCTAssertTrue(rig.isGoing, "none of them ended it")
    }

    func testAttitudeSceneResetAndWristStartSentChangeNothingWhileGoing() {
        var rig = going()
        XCTAssertEqual(rig.rotate(turn: 30, tilt: 10), [])
        XCTAssertEqual(rig.send(.sceneReset, after: 0.1), [])
        XCTAssertEqual(rig.send(.wristStartSent, after: 0.1), [])
        XCTAssertTrue(rig.isGoing)
    }

    // MARK: A control the rules do not see

    /// The fine panel's entry button ends a follow latched by a press, or a move to a tapped point, as a press would.
    /// No input of the rules is down afterwards, so the next press starts afresh.
    func testTheFinePanelEntryEndsAMoveNobodyHolds() {
        for (name, start) in [("latched", latched()), ("going", going())] {
            var rig = start
            XCTAssertEqual(rig.send(.controlPressed, after: 0.2), stoppedByYou, name)
            XCTAssertNil(rig.arbiter.engagement, name)
            XCTAssertFalse(rig.arbiter.isHoldingAnInput, name)
            XCTAssertEqual(rig.send(.controlPressed, after: 0.1), [], "\(name): nothing left to end")
            XCTAssertEqual(rig.wait(1), [], name)
        }
    }

    /// It ends nothing else: a hold tied to a key that is down, and the idle rules, are untouched.
    func testTheFinePanelEntryLeavesAHeldHoldAlone() {
        var held = Rig(.screenTurns)
        XCTAssertEqual(held.press(.upper, after: 0.1), [.startTranslation])
        XCTAssertEqual(held.send(.controlPressed, after: 0.1), [])
        XCTAssertEqual(held.arbiter.engagedHold, .translation)
        XCTAssertEqual(held.release(.upper, after: 0.1), [.stopTranslation])

        var idle = Rig(.screenTurns)
        XCTAssertEqual(idle.send(.controlPressed, after: 0.1), [])
        XCTAssertNil(idle.arbiter.engagement)
    }
}
