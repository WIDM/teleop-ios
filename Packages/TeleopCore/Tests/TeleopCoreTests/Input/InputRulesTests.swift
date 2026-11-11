import XCTest
@testable import TeleopCore

/// The rules both schemes share (§2.3): first press wins, one key at a time, the bands, leaving, and the wrist hold's
/// bookkeeping across holds.
final class InputRulesTests: XCTestCase {
    typealias Rig = ArbiterRig

    // MARK: I-2 First press wins

    func testI24ASecondKeyWhileTheFirstIsDownIsDead() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var rig = Rig(scheme)
            rig.press(.upper)
            XCTAssertEqual(rig.press(.lower, after: 0.3), [.cue(.dead)])
            XCTAssertEqual(rig.release(.upper, after: 0.3), [.stopTranslation])
            // I-2.3: releasing the engaged key does not wake the dead one.
            XCTAssertEqual(rig.rotate(turn: 20), [])
            XCTAssertEqual(rig.wait(1), [])
            XCTAssertEqual(rig.release(.lower), [])
        }
    }

    func testI24ASecondKeyIsDeadWhateverTheFirstIsDoing() {
        var rig = Rig(.screenTurns)
        // The first key was refused: still one key at a time.
        rig.facts.gripping = true
        XCTAssertEqual(rig.press(.lower), [.cue(.alreadyGripping)])
        XCTAssertEqual(rig.press(.upper, after: 0.3), [.cue(.dead)])
        rig.release(.lower)
        XCTAssertEqual(rig.release(.upper, after: 0.3), [])
    }

    func testI24BothKeysWithinFiftyMillisecondsTheEarlierWins() {
        // The guard for a replayed key is off here, so only the 50 ms chord rule applies.
        var noReplay = Rig(.screenTurns, constants: InputConstants(keyReplayGuard: false))
        noReplay.press(.lower)
        noReplay.release(.lower, after: 0.01)
        XCTAssertEqual(noReplay.press(.upper, after: 0.04), [.cue(.dead)])
        noReplay.release(.upper)
        XCTAssertEqual(noReplay.press(.upper, after: 0.2), [.startTranslation])
    }

    func testI24AKeyJustAfterTheOtherIsReleasedIsDeadWhileTheReplayGuardIsOn() {
        var rig = Rig(.keyTurns)
        rig.press(.upper)
        rig.release(.upper, after: 0.5)
        // The platform hands over the held vol− the moment vol+ is let go.
        XCTAssertEqual(rig.press(.lower), [.cue(.dead)])
        rig.release(.lower, after: 0.2)
        rig.press(.upper, after: 0.5)
        rig.release(.upper, after: 0.5)
        XCTAssertEqual(rig.press(.lower, after: 0.149), [.cue(.dead)])
        rig.release(.lower, after: 0.2)
        rig.press(.upper, after: 0.5)
        rig.release(.upper, after: 0.5)
        XCTAssertEqual(rig.press(.lower, after: 0.151), [.startWrist, .wristUpdate(.identity)])
    }

    func testARepeatedBeganWhileDownIsIgnored() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.press(.upper, after: 0.1), [])
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])
        XCTAssertEqual(rig.release(.upper), [])
    }

    // MARK: I-3 Bands

    func testTheBottomBandStopsOnTouchDownWhateverElseIsHeld() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.touchDown(1, at: Rig.bottomBand, after: 0.2), [.emergencyStop])
        // A second finger and a palm stop too: no filter applies there.
        XCTAssertEqual(rig.touchDown(2, at: Rig.bottomBand + SIMD2(100, 0), radius: 50), [.emergencyStop])
        XCTAssertEqual(rig.touchDown(3, at: SIMD2(2, 860)), [.emergencyStop])
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])
    }

    func testStopWithNoConnectionSaysSo() {
        var rig = Rig(.keyTurns)
        rig.facts.connectionUp = false
        XCTAssertEqual(rig.touchDown(1, at: Rig.bottomBand), [.emergencyStop, .cue(.refused(.notStopped))])
    }

    func testTheTopBandHeldTwoSecondsResets() {
        var rig = Rig(.screenTurns)
        XCTAssertEqual(rig.touchDown(1, at: Rig.topBand), [])
        XCTAssertEqual(rig.wait(0.099), [])
        XCTAssertEqual(rig.wait(0.001), [.resetCountdownStarted])
        XCTAssertEqual(rig.phase(.touch(1)), .countingDown)
        XCTAssertEqual(rig.wait(1.899), [])
        XCTAssertEqual(rig.wait(0.001), [.fireReset])
        XCTAssertEqual(rig.lift(1, after: 1), [])
        XCTAssertNil(rig.arbiter.nextDeadline)
    }

    func testTheCountdownWorksInTheEmergencyStopState() {
        var rig = Rig(.screenTurns)
        rig.facts.refusal = .stopped
        rig.touchDown(1, at: Rig.topBand)
        XCTAssertEqual(rig.wait(2), [.resetCountdownStarted, .fireReset])
    }

    func testLiftingBeforeTwoSecondsCancelsSilently() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(1)
        XCTAssertEqual(rig.lift(1, after: 0.5), [.resetCountdownCancelled])
        XCTAssertEqual(rig.wait(2), [])
        // A quick tap never starts it.
        rig.touchDown(2, at: Rig.topBand)
        XCTAssertEqual(rig.lift(2, after: 0.05), [])
        XCTAssertEqual(rig.wait(2), [])
    }

    func testTheCountdownCountsAsEngaged() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(0.5)
        XCTAssertEqual(rig.press(.upper), [.cue(.dead)])
        // A touch that would commit during the countdown is dead with NO.
        rig.touchDown(2, at: Rig.middle)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(2, mm: 10, degrees: 90), [.cue(.dead)])
        XCTAssertEqual(rig.wait(2), [.fireReset])
        XCTAssertEqual(rig.release(.upper), [])
    }

    func testAnUndecidedThumbHeldThroughTheCountdownStaysDeadAfterTheReset() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.15)
        rig.touchDown(2, at: Rig.topBand, after: 0.1)
        XCTAssertEqual(rig.wait(0.1), [.resetCountdownStarted])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.wait(1.9), [.fireReset])
        rig.lift(2, after: 0.05)
        // The thumb was down through the whole reset: turning the phone now starts nothing.
        XCTAssertEqual(rig.rotate(turn: 6, steps: 6).withoutUpdates, [.cue(.dead)])
        XCTAssertEqual(rig.lift(1), [])
    }

    func testAHoldThatBeginsInsideTheTopBandPalmWindowKillsTheTouch() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        XCTAssertEqual(rig.press(.upper, after: 0.02), [.startTranslation])
        XCTAssertEqual(rig.release(.upper, after: 0.03), [.stopTranslation])
        // Nothing is engaged when the window ends, but the touch was down during a hold.
        XCTAssertEqual(rig.wait(0.05), [.cue(.refused(.letGoFirst))])
        XCTAssertEqual(rig.wait(2.5), [])
        // Lifted inside the window, the NO plays at the lift.
        rig.lift(1)
        rig.touchDown(2, at: Rig.topBand, after: 1)
        rig.press(.upper, after: 0.02)
        rig.release(.upper, after: 0.02)
        XCTAssertEqual(rig.lift(2, after: 0.02), [.cue(.refused(.letGoFirst))])
    }

    func testARefusedKeyInsideTheTopBandPalmWindowLeavesTheCountdownAlone() {
        var rig = Rig(.screenTurns)
        rig.facts.refusal = .stopped
        rig.touchDown(1, at: Rig.topBand)
        XCTAssertEqual(rig.press(.upper, after: 0.02), [.cue(.refused(.stopped))])
        rig.release(.upper, after: 0.03)
        XCTAssertEqual(rig.wait(0.05), [.resetCountdownStarted])
        XCTAssertEqual(rig.wait(1.9), [.fireReset])
    }

    func testTheTopBandWhileSomethingIsEngagedIsDeadWithLetGoFirst() {
        var rig = Rig(.screenTurns)
        rig.press(.lower)
        XCTAssertEqual(rig.touchDown(1, at: Rig.topBand), [])
        XCTAssertEqual(rig.wait(0.1), [.cue(.refused(.letGoFirst))])
        XCTAssertEqual(rig.release(.lower), [.stopGripper])
        XCTAssertEqual(rig.wait(3), [], "it stays dead")
        // Lifted inside the palm window without growing: the NO plays at the lift.
        rig.press(.upper)
        rig.touchDown(2, at: Rig.topBand)
        XCTAssertEqual(rig.lift(2, after: 0.05), [.cue(.refused(.letGoFirst))])
    }

    func testTheTopBandDuringTheSuccessDisplaySaysWait() {
        var rig = Rig(.screenTurns)
        rig.facts.resetRefusal = .wait
        rig.touchDown(1, at: Rig.topBand)
        XCTAssertEqual(rig.wait(0.1), [.cue(.refused(.wait))])
        XCTAssertEqual(rig.wait(3), [])
    }

    func testTheResetChecksRunAgainAtTwoSeconds() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(1)
        rig.facts.resetRefusal = .wait
        XCTAssertEqual(rig.wait(1), [.resetCountdownCancelled, .cue(.refused(.wait))])
        XCTAssertEqual(rig.lift(1), [])
    }

    func testATapOnTheGearOpensSettingsWhenNothingIsEngaged() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.gear)
        XCTAssertEqual(rig.lift(1, after: 0.3), [.openSettings])
        // Held 0.5 s or more: nothing. The gear never starts the countdown.
        rig.touchDown(2, at: Rig.gear, after: 1)
        XCTAssertEqual(rig.wait(3), [])
        XCTAssertEqual(rig.lift(2), [])
    }

    func testTheGearWhileSomethingIsEngagedIsDeadWithLetGoFirst() {
        var rig = Rig(.keyTurns)
        rig.press(.upper)
        rig.touchDown(1, at: Rig.gear)
        XCTAssertEqual(rig.wait(0.1), [.cue(.refused(.letGoFirst))])
        XCTAssertEqual(rig.lift(1, after: 0.1), [])
        // Engaged by the end of the palm window, though not at the touch-down: dead with NO, Settings does not open.
        rig.release(.upper, after: 1)
        rig.touchDown(2, at: Rig.gear, after: 0.5)
        rig.press(.upper, after: 0.05)
        XCTAssertEqual(rig.lift(2, after: 0.1), [.cue(.refused(.letGoFirst))])
        // Engaged only at the lift of a tap: dead with NO too.
        rig.release(.upper, after: 1)
        rig.touchDown(3, at: Rig.gear, after: 0.5)
        rig.wait(0.15)
        rig.press(.upper)
        XCTAssertEqual(rig.lift(3, after: 0.1), [.cue(.refused(.letGoFirst))])
        // Held 0.5 s or more, it is not a tap: silent.
        rig.release(.upper, after: 1)
        rig.touchDown(4, at: Rig.gear, after: 0.5)
        rig.wait(0.15)
        rig.press(.upper)
        XCTAssertEqual(rig.lift(4, after: 0.4), [])
    }

    // MARK: I-11 Leaving

    func testLeavingEndsTheHoldAndEveryHeldInputStaysDead() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        rig.touchDown(1, at: Rig.middle)
        XCTAssertEqual(rig.send(.endAllHolds, after: 0.2), [.stopTranslation])
        XCTAssertEqual(rig.phase(.key(.upper)), .dead)
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.release(.upper, after: 1), [])
        XCTAssertEqual(rig.slide(1, mm: 15, degrees: 90), [])
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertEqual(rig.press(.upper, after: 1), [.startTranslation])
    }

    func testAKeyWhoseReleaseWasLostWhileAwayCostsOnePressWithNo() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.send(.endAllHolds, after: 0.2), [.stopTranslation])
        // Let go of while the app was inactive: no key-up arrives.
        XCTAssertEqual(rig.send(.becameActive, after: 3), [])
        XCTAssertTrue(rig.arbiter.held.isEmpty)
        XCTAssertFalse(rig.arbiter.isHoldingAnInput)
        // The next press might be the platform handing over a key held all along: dead, with NO.
        XCTAssertEqual(rig.press(.upper, after: 1), [.cue(.dead)])
        XCTAssertEqual(rig.release(.upper, after: 0.2), [])
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.startTranslation])
        XCTAssertEqual(rig.release(.upper, after: 0.2), [.stopTranslation])
    }

    func testAKeyStaleFromBeforeLeavingDoesNotBlockTheOtherKey() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        rig.send(.endAllHolds, after: 0.2)
        rig.send(.becameActive, after: 3)
        XCTAssertEqual(rig.press(.lower, after: 1), [.startGripper(.closed)])
        XCTAssertEqual(rig.release(.lower, after: 0.3), [.stopGripper])
    }

    func testAKeyHeldAcrossLeavingAndReleasedAfterReturnIsFreeAgain() {
        var rig = Rig(.keyTurns)
        rig.press(.lower)
        rig.send(.endAllHolds, after: 0.2)
        rig.send(.becameActive, after: 3)
        XCTAssertEqual(rig.release(.lower, after: 0.5), [])
        XCTAssertEqual(rig.press(.lower, after: 0.5), [.startWrist, .wristUpdate(.identity)])
    }

    func testATouchWhoseLiftWasLostWhileAwayDoesNotBlockTheSurface() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.2)
        XCTAssertEqual(rig.rotate(turn: 8).withoutUpdates, [.startWrist])
        XCTAssertEqual(rig.send(.endAllHolds, after: 0.2), [.stopWrist])
        rig.send(.becameActive, after: 3)
        XCTAssertTrue(rig.arbiter.held.isEmpty)
        // Late samples of the forgotten touch do nothing.
        XCTAssertEqual(rig.move(1, to: Rig.middle + SIMD2(0, -80)), [])
        rig.orient(turn: 0, after: 1)
        rig.touchDown(2, at: Rig.leftHalf, after: 1)
        rig.wait(0.2)
        XCTAssertEqual(rig.rotate(turn: 8).withoutUpdates, [.startWrist])
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertEqual(rig.lift(2), [.stopWrist])

        var keyTurns = Rig(.keyTurns)
        keyTurns.touchDown(1, at: Rig.rightHalf)
        keyTurns.wait(0.2)
        XCTAssertEqual(keyTurns.send(.endAllHolds, after: 0.1), [.stopGripper])
        keyTurns.send(.becameActive, after: 2)
        keyTurns.touchDown(2, at: Rig.leftHalf, after: 1)
        XCTAssertEqual(keyTurns.wait(0.5), [.startGripper(.open)])
    }

    func testReturningEndsAHoldThatWasNotEndedOnLeaving() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.send(.becameActive, after: 1), [.stopTranslation])
        XCTAssertEqual(rig.release(.upper), [])
    }

    func testLeavingDuringTheCountdownCancelsIt() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.topBand)
        rig.wait(0.5)
        XCTAssertEqual(rig.send(.endAllHolds), [.resetCountdownCancelled])
        XCTAssertEqual(rig.wait(3), [])
    }

    func testLeavingDuringAWristHoldStopsIt() {
        var rig = Rig(.keyTurns)
        rig.press(.lower)
        rig.rotate(turn: 15)
        XCTAssertEqual(rig.send(.endAllHolds), [.stopWrist])
        XCTAssertEqual(rig.rotate(turn: 30), [])
        XCTAssertEqual(rig.release(.lower), [])
    }

    func testAModeChangeEndsEveryHoldAndSwitchesScheme() {
        var rig = Rig(.screenTurns)
        rig.press(.lower)
        XCTAssertEqual(rig.send(.modeChanged(.keyTurns, .left), after: 0.5), [.stopGripper])
        XCTAssertEqual(rig.arbiter.scheme, .keyTurns)
        XCTAssertEqual(rig.arbiter.hand, .left)
        XCTAssertEqual(rig.release(.lower), [])
        XCTAssertEqual(rig.press(.lower, after: 1), [.startWrist, .wristUpdate(.identity)])
    }

    // MARK: Wrist bookkeeping across holds

    func testALateStartDropsRotationMadeWhileWaiting() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        let committed = rig.rotate(turn: 6, steps: 6)
        XCTAssertEqual(committed.withoutUpdates, [.startWrist])
        // The link held the start back while the phone turned on to 16°.
        rig.rotate(turn: 16)
        // The target from the moment the start goes out is the commit angle again, without waiting for a sample.
        let atSend = rig.send(.wristStartSent, after: 0.01)
        XCTAssertEqual(atSend.wristTargets.count, 1)
        XCTAssertEqual(atSend.wristTargets.first?.degrees ?? 0, committed.wristTargets.first!.degrees, accuracy: 1e-9)
        let after = rig.orient(after: 1.0 / 30).wristTargets
        XCTAssertEqual(after.last?.degrees ?? 0, committed.wristTargets.first!.degrees, accuracy: 1e-6)

        // Scheme B goes back to the identity and commits afresh.
        var keyTurns = Rig(.keyTurns)
        keyTurns.press(.lower)
        XCTAssertEqual(keyTurns.rotate(turn: 10).wristTargets.last?.axis, .turn)
        XCTAssertEqual(keyTurns.send(.wristStartSent, after: 0.01), [.wristUpdate(.identity)])
        // Without an engaged wrist hold it does nothing.
        keyTurns.release(.lower)
        XCTAssertEqual(keyTurns.send(.wristStartSent, after: 0.01), [])
    }

    func testOnAnUnknownServerTheTiltWindowCountsCommandedTiltUntilAReset() {
        var rig = Rig(.screenTurns)
        func tiltHold(_ id: Int, to tilt: Double) -> [InputCommand] {
            rig.orient(turn: 0, tilt: 0, after: 0.5)
            rig.touchDown(id, at: Rig.middle)
            rig.wait(0.1)
            var commands = rig.rotate(tilt: tilt, steps: 40)
            for _ in 0..<20 { commands += rig.orient(after: 1.0 / 60) }
            commands += rig.lift(id)
            return commands
        }
        let first = tiltHold(1, to: 15)
        XCTAssertEqual(first.wristTargets.last?.degrees ?? 0, 15, accuracy: 1e-3)
        XCTAssertEqual(first.cues, [])
        // 15° already commanded: 10° more reach the 25° window.
        let second = tiltHold(2, to: 18)
        XCTAssertEqual(second.cues, [.limit])
        XCTAssertEqual(second.wristTargets.last?.degrees ?? 0, 10, accuracy: 1e-3)
        rig.send(.sceneReset)
        let third = tiltHold(3, to: 18)
        XCTAssertEqual(third.cues, [])
        XCTAssertEqual(third.wristTargets.last?.degrees ?? 0, 18, accuracy: 1e-3)
    }

    func testAResetDuringATiltHoldCountsOnlyTheTiltCommandedAfterIt() {
        var rig = Rig(.keyTurns)
        func settle() -> [InputCommand] { (0..<20).flatMap { _ in rig.orient(after: 1.0 / 60) } }
        rig.press(.lower)
        let before = rig.rotate(tilt: -18, steps: 30) + settle()
        XCTAssertEqual(before.wristTargets.last?.degrees ?? 0, -18, accuracy: 1e-3)
        // The reset takes the arm home while the hold is still engaged; the tilt before it is gone.
        rig.send(.sceneReset, after: 0.1)
        rig.release(.lower, after: 0.1)
        rig.orient(turn: 0, tilt: 0, after: 0.5)
        func tiltHold(by tilt: Double) -> [InputCommand] {
            var commands = rig.press(.lower, after: 0.5)
            commands += rig.rotate(tilt: rig.tilt + tilt, steps: 60) + settle()
            return commands + rig.release(.lower)
        }
        XCTAssertEqual(tiltHold(by: 30).wristTargets.last?.degrees ?? 0, 20, accuracy: 1e-3)
        // 20° commanded since the reset: 5° more reach the 25° window.
        let second = tiltHold(by: 30)
        XCTAssertEqual(second.wristTargets.last?.degrees ?? 0, 5, accuracy: 1e-3)
        XCTAssertEqual(second.cues, [.limit])
    }

    func testOnAPatchedServerTheWindowsComeFromTheMeasuredAngles() {
        var rig = Rig(.keyTurns)
        rig.facts.wrist = WristReadings(rollDeg: 130, flexDeg: 0, flexAtResetDeg: 0)
        rig.press(.lower)
        var commands = rig.rotate(turn: 40, steps: 40)
        for _ in 0..<20 { commands += rig.orient(after: 1.0 / 60) }
        XCTAssertEqual(commands.cues, [.limit])
        XCTAssertEqual(commands.wristTargets.last?.degrees ?? 0, 20, accuracy: 1e-3)
    }

    // MARK: Reading the state

    func testHoldingAnInputCountsKeysAndValidTouches() {
        var rig = Rig(.screenTurns)
        XCTAssertFalse(rig.arbiter.isHoldingAnInput)
        rig.touchDown(1, at: Rig.bottomBand)
        rig.touchDown(2, at: Rig.gap)
        rig.touchDown(3, at: Rig.middle, radius: 40)
        XCTAssertFalse(rig.arbiter.isHoldingAnInput, "STOP, the gap and a palm are not holding an input")
        rig.touchDown(4, at: Rig.middle)
        XCTAssertTrue(rig.arbiter.isHoldingAnInput)
        rig.lift(4)
        rig.facts.refusal = .noLink
        rig.press(.upper)
        XCTAssertTrue(rig.arbiter.isHoldingAnInput, "a refused key is still held")
    }

    func testNextDeadlineNamesTheNextTimer() {
        var rig = Rig(.keyTurns)
        rig.touchDown(1, at: Rig.rightHalf)
        XCTAssertEqual(rig.arbiter.nextDeadline ?? 0, rig.time + 0.1, accuracy: 1e-9)
        rig.wait(0.1)
        XCTAssertEqual(rig.arbiter.nextDeadline ?? 0, rig.time + 0.05, accuracy: 1e-9)
    }
}
