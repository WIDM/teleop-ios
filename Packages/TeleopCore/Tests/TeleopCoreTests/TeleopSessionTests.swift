import XCTest
@testable import TeleopCore

final class TeleopSessionTests: XCTestCase {
    func testAFreshSessionOpensOnPermissionsAndTheDemoLinkIsConnected() {
        let s = TeleopSession()
        XCTAssertEqual(s.route, .s2)
        XCTAssertEqual(s.navigator.stack, [.s2])
        XCTAssertTrue(s.state.connected)
        XCTAssertEqual(TeleopSession(start: .p4).route, .p4)
    }

    func testTutorialRunsThenSkipsOnceDone() {
        var s = TeleopSession()
        s.perform(.permissionsContinue)
        XCTAssertEqual(s.route, .t1)
        s.perform(.tutorialNext(step: 1))
        s.perform(.tutorialNext(step: 2))
        XCTAssertEqual(s.route, .t3)
        s.perform(.tutorialNext(step: 3))
        XCTAssertEqual(s.route, .p4)
        XCTAssertTrue(s.state.tutorialDone)
        s.perform(.replayTutorial)
        XCTAssertEqual(s.route, .t1)
        XCTAssertFalse(s.state.tutorialDone)
    }

    func testStopStartsLongBuzzAndReleaseCancelsIt() {
        var s = TeleopSession(start: .p4)
        s.perform(.stop)
        XCTAssertEqual(s.route, .s4)
        XCTAssertTrue(s.state.emergencyStop)
        XCTAssertEqual(s.drainHaptics(), [.play(.emergencyLoop)])
        XCTAssertTrue(s.drainHaptics().isEmpty)
        s.perform(.releaseStop)
        XCTAssertEqual(s.route, .p4)
        XCTAssertFalse(s.state.emergencyStop)
        // H15: cancel the long buzz, then one short buzz confirms the release.
        XCTAssertEqual(s.drainHaptics(), [.cancel, .play(.stopReleased)])
    }

    func testGripperStartEmitsMatchingCue() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        s.perform(.gripperStart(.closed))
        s.perform(.gripperEnd)
        s.perform(.gripperStart(.open))
        XCTAssertEqual(s.drainHaptics(), [.play(.gripperClosed), .play(.gripperOpened)])
    }

    func testGripperRefusedAfterEStopAndNavigationRoundTrip() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        s.perform(.stop)
        s.perform(.openConnection)
        s.perform(.closeConnection)
        s.perform(.openSettings)
        s.perform(.settingsDone)
        _ = s.drainHaptics()
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertTrue(s.drainHaptics().isEmpty)
    }

    func testCloseConnectionWhileEStoppedReturnsToS4() {
        var s = TeleopSession(start: .p4)
        s.perform(.stop)
        s.perform(.openConnection)
        XCTAssertEqual(s.route, .p5)
        s.perform(.closeConnection)
        XCTAssertEqual(s.route, .s4)
    }

    func testCloseConnectionReturnsToStartingKeyboardScreen() {
        var s = TeleopSession(start: .p7)
        s.perform(.openConnection)
        XCTAssertEqual(s.route, .p5)
        s.perform(.closeConnection)
        XCTAssertEqual(s.route, .p7)
    }

    func testCloseConnectionReturnsToStartingScreenFromP4() {
        var s = TeleopSession(start: .p4)
        s.perform(.openConnection)
        s.perform(.closeConnection)
        XCTAssertEqual(s.route, .p4)
    }

    func testCloseConnectionWithoutOriginFallsBackToP4() {
        var s = TeleopSession(start: .p5)
        s.perform(.closeConnection)
        XCTAssertEqual(s.route, .p4)
    }

    func testStaleOriginIsDroppedAfterLeavingConnectionScreens() {
        var s = TeleopSession(start: .p7)
        s.perform(.openConnection)
        s.perform(.back)
        s.perform(.openSettings)
        s.perform(.settingsDone)
        s.perform(.connect)
        s.perform(.closeConnection)
        XCTAssertEqual(s.route, .p4)
    }

    /// A session with its link down. The demo link starts connected, so it is cut first.
    private func disconnected(at route: Route = .p4) -> TeleopSession {
        var s = TeleopSession(start: route)
        s.state.markDisconnected()
        return s
    }

    func testGripperRefusedWhenDisconnected() {
        var s = disconnected()
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertTrue(s.drainHaptics().isEmpty)
    }

    func testGripperRefusedWhenCommandsBlocked() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        blockOnLatency(&s)
        _ = s.drainHaptics()
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .open)
        // H3: a refused command buzzes 3 short.
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
    }

    func testGripperWorksAgainAfterReleasingStop() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        s.perform(.stop)
        s.perform(.releaseStop)
        _ = s.drainHaptics()
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .closed)
    }

    func testSettingsDoneReturnsToStandby() {
        var s = TeleopSession(start: .p4)
        s.perform(.openSettings)
        s.perform(.settingsDone)
        XCTAssertEqual(s.route, .p4)
    }

    // MARK: hold area (N2), blocked cues (N4), release cue (N5), settings (S6)

    private func connectedOnStandby() -> TeleopSession {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        return s
    }

    /// Two slow round trips in a row on a live link: the only thing that blocks commands.
    private func blockOnLatency(_ s: inout TeleopSession) {
        s.state.liveLink = true
        s.perform(.linkLatency(ms: FakeTeleopState.blockLatencyMs))
        s.perform(.linkLatency(ms: FakeTeleopState.blockLatencyMs))
        XCTAssertTrue(s.state.commandsBlocked)
    }

    func testHoldStartThenEndMovesAndStopsArm() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        XCTAssertTrue(s.state.armMoving)
        s.perform(.holdArmEnd)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertTrue(s.drainHaptics().isEmpty)
    }

    func testHoldStartRefusedWhenLatencyBlockedBuzzesThreeShort() {
        var s = connectedOnStandby()
        blockOnLatency(&s)
        _ = s.drainHaptics()
        s.perform(.holdArmStart)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
    }

    func testHoldStartIgnoredSilentlyWhenEStoppedOrDisconnected() {
        var stopped = connectedOnStandby()
        stopped.perform(.stop)
        _ = stopped.drainHaptics()
        stopped.perform(.holdArmStart)
        XCTAssertFalse(stopped.state.armMoving)
        XCTAssertTrue(stopped.drainHaptics().isEmpty)

        var offline = disconnected()
        offline.perform(.holdArmStart)
        XCTAssertFalse(offline.state.armMoving)
        XCTAssertTrue(offline.drainHaptics().isEmpty)
    }

    func testHoldEndStopsEvenWhenBlockedWhileHeld() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        blockOnLatency(&s)
        s.perform(.holdArmEnd)
        XCTAssertFalse(s.state.armMoving)
    }

    func testHighLatencyWhileHeldStopsArm() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        blockOnLatency(&s)
        XCTAssertFalse(s.state.armMoving)
    }

    func testDisconnectWhileHeldStopsArm() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        s.perform(.disconnect)
        XCTAssertFalse(s.state.armMoving)
    }

    func testHighLatencyWhileEStoppedKeepsS4Visible() {
        var s = connectedOnStandby()
        s.perform(.stop)
        blockOnLatency(&s)
        XCTAssertEqual(s.route, .s4)
        XCTAssertTrue(s.state.emergencyStop)
        XCTAssertTrue(s.state.commandsBlocked)
    }

    func testStopWhileEStoppedDoesNotRestartLongBuzz() {
        var s = connectedOnStandby()
        s.perform(.stop)
        XCTAssertEqual(s.drainHaptics(), [.play(.emergencyLoop)])
        s.perform(.openConnection)
        s.perform(.stop)
        XCTAssertEqual(s.route, .s4)
        XCTAssertEqual(s.drainHaptics(), [])
        s.perform(.releaseStop)
        XCTAssertEqual(s.drainHaptics(), [.cancel, .play(.stopReleased)])
    }

    func testStopClearsArmHold() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        s.perform(.stop)
        XCTAssertFalse(s.state.armMoving)
    }

    func testGripperWhileArmHeldIsBlockedWithCue() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
        s.perform(.holdArmEnd)
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .closed)
    }

    func testGripperMovesOnlyWhileHeld() {
        var s = connectedOnStandby()
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripperMoving, .closed)
        XCTAssertEqual(s.state.gripper, .closed)
        s.perform(.gripperEnd)
        XCTAssertNil(s.state.gripperMoving)
        XCTAssertEqual(s.state.gripper, .closed, "the label keeps the last direction")
    }

    func testRepeatedStartWhileHeldBuzzesOnce() {
        var s = connectedOnStandby()
        s.perform(.gripperStart(.closed))
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.drainHaptics(), [.play(.gripperClosed)])
    }

    func testArmHoldTakesOverFromTheGripper() {
        var s = connectedOnStandby()
        s.perform(.gripperStart(.open))
        s.perform(.holdArmStart)
        XCTAssertNil(s.state.gripperMoving)
        XCTAssertTrue(s.state.armMoving)
    }

    func testStopAndLatencyBlockAndDisconnectStopTheGripper() {
        var stopped = connectedOnStandby()
        stopped.perform(.gripperStart(.closed))
        stopped.perform(.stop)
        XCTAssertNil(stopped.state.gripperMoving)

        var slow = connectedOnStandby()
        slow.perform(.gripperStart(.closed))
        blockOnLatency(&slow)
        XCTAssertNil(slow.state.gripperMoving)

        var offline = connectedOnStandby()
        offline.perform(.gripperStart(.closed))
        offline.perform(.disconnect)
        XCTAssertNil(offline.state.gripperMoving)
    }

    func testTheThreeHeldControlsTakeOverFromEachOther() {
        var s = connectedOnStandby()
        s.perform(.wristStart)
        s.perform(.gripperStart(.open))
        XCTAssertFalse(s.state.wristMoving)
        XCTAssertEqual(s.state.gripperMoving, .open)
        s.perform(.wristStart)
        XCTAssertNil(s.state.gripperMoving)
        XCTAssertTrue(s.state.wristMoving)
        s.perform(.holdArmStart)
        XCTAssertFalse(s.state.wristMoving)
        XCTAssertTrue(s.state.armMoving)
    }

    func testWristHoldRunsOnlyWhileHeldAndTakesOverFromEveryOtherControl() {
        var s = connectedOnStandby()
        s.perform(.wristStart)
        XCTAssertTrue(s.state.wristMoving)
        s.perform(.wristEnd)
        XCTAssertFalse(s.state.wristMoving)
        s.perform(.wristStart)
        XCTAssertTrue(s.state.wristMoving)
        s.perform(.gripperStart(.open))
        XCTAssertFalse(s.state.wristMoving)
        s.perform(.wristStart)
        XCTAssertNil(s.state.gripperMoving)
        s.perform(.holdArmStart)
        XCTAssertFalse(s.state.wristMoving)
        _ = s.drainHaptics()
        s.perform(.wristStart)
        XCTAssertFalse(s.state.wristMoving, "refused while the arm is held")
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
    }

    func testWristHoldIsRefusedAndEndedLikeTheOtherControls() {
        var offline = disconnected()
        offline.perform(.wristStart)
        XCTAssertFalse(offline.state.wristMoving)
        XCTAssertEqual(offline.drainHaptics(), [])

        var stopped = connectedOnStandby()
        stopped.perform(.stop)
        _ = stopped.drainHaptics()
        stopped.perform(.wristStart)
        XCTAssertFalse(stopped.state.wristMoving)
        XCTAssertEqual(stopped.drainHaptics(), [])

        var slow = connectedOnStandby()
        blockOnLatency(&slow)
        slow.perform(.wristStart)
        XCTAssertFalse(slow.state.wristMoving)
        XCTAssertEqual(slow.drainHaptics(), [.play(.commandBlocked)])

        for end in [TeleopAction.stop, .disconnect, .switchLink, .resetScene, .wristEnd] {
            var s = connectedOnStandby()
            s.perform(.wristStart)
            s.perform(end)
            XCTAssertFalse(s.state.wristMoving, "\(end)")
        }
        var slowed = connectedOnStandby()
        slowed.perform(.wristStart)
        blockOnLatency(&slowed)
        XCTAssertFalse(slowed.state.wristMoving)

        var lost = connectedOnStandby()
        lost.state.liveLink = true
        lost.perform(.wristStart)
        lost.perform(.linkLost)
        XCTAssertFalse(lost.state.wristMoving)

        var blocked = connectedOnStandby()
        blocked.perform(.wristStart)
        blocked.state.commandsBlocked = true
        blocked.perform(.wristEnd)
        XCTAssertFalse(blocked.state.wristMoving, "release always stops")
    }

    func testGripperEndWorksEvenWhenBlocked() {
        var s = connectedOnStandby()
        s.perform(.gripperStart(.closed))
        s.state.commandsBlocked = true
        s.perform(.gripperEnd)
        XCTAssertNil(s.state.gripperMoving)
    }

    func testBlockedGripperCueIsThreeShortPulses() {
        XCTAssertEqual(HapticCue.commandBlocked.pattern.pulses.count, 3)
    }

    func testReleaseStopCueIsOneShortBuzz() {
        XCTAssertEqual(HapticCue.stopReleased.pattern, HapticPattern.shortBuzz(count: 1))
        XCTAssertFalse(HapticCue.stopReleased.pattern.repeats)
    }

    func testSmoothingSurvivesNavigation() {
        var s = TeleopSession(start: .p4)
        s.perform(.openSettings)
        s.state.setSmoothing(0.8)
        s.perform(.settingsDone)
        s.perform(.openSettings)
        XCTAssertEqual(s.route, .s6)
        XCTAssertEqual(s.state.smoothing, 0.8)
    }

    func testSettingsDefaultsMatchFigma() {
        let state = FakeTeleopState()
        XCTAssertEqual(state.sensitivity, 1.0)
        XCTAssertEqual(state.smoothing, 0.3)
    }

    func testSettingsValuesAreClamped() {
        var state = FakeTeleopState()
        state.setSmoothing(-1)
        XCTAssertEqual(state.smoothing, 0)
        state.setSmoothing(2)
        XCTAssertEqual(state.smoothing, 1)
    }

    func testResetFromHighLatencyReturnsToStandbyUnblocked() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        blockOnLatency(&s)
        XCTAssertEqual(s.route, .p6)
        s.perform(.resetScene)
        XCTAssertEqual(s.route, .p4)
        XCTAssertFalse(s.state.commandsBlocked)
        XCTAssertNil(s.state.latencyMs, "the old samples no longer count")
        s.perform(.linkLatency(ms: FakeTeleopState.blockLatencyMs))
        XCTAssertFalse(s.state.commandsBlocked, "after a reset, one slow sample is noise again")
        XCTAssertEqual(s.route, .p4)
    }

    func testResetStopsArmAndOpensGripperWithoutHaptics() {
        var s = connectedOnStandby()
        s.perform(.gripperStart(.closed))
        s.perform(.holdArmStart)
        _ = s.drainHaptics()
        s.perform(.resetScene)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertEqual(s.route, .p4)
        XCTAssertTrue(s.drainHaptics().isEmpty)
    }

    func testResetIgnoredWhenEStoppedOrDisconnected() {
        var stopped = TeleopSession(start: .p4)
        stopped.state.markConnected()
        stopped.perform(.gripperStart(.closed))
        stopped.perform(.stop)
        stopped.perform(.resetScene)
        XCTAssertEqual(stopped.state.gripper, .closed)
        XCTAssertEqual(stopped.route, .s4)

        var offline = disconnected(at: .p4)
        offline.state.gripper = .closed
        offline.perform(.resetScene)
        XCTAssertEqual(offline.state.gripper, .closed)
    }

    /// §6.5: a scene reset clears the emergency stop, so a reset the server confirmed releases the latch, ends the long
    /// buzz and leaves S4. "Ready." comes with the server's new episode.
    func testAConfirmedResetReleasesTheStop() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        s.perform(.stop)
        _ = s.drainHaptics()
        s.perform(.resetScene)
        XCTAssertTrue(s.state.emergencyStop, "asking for a reset releases nothing")
        s.perform(.sceneResetDone)
        XCTAssertFalse(s.state.emergencyStop)
        XCTAssertEqual(s.route, .p4)
        XCTAssertEqual(s.drainHaptics(), [.cancel])
    }

    func testAConfirmedResetOutsideTheStopChangesNothing() {
        var s = connectedOnStandby()
        s.perform(.holdArmStart)
        _ = s.drainHaptics()
        let before = s
        s.perform(.sceneResetDone)
        XCTAssertEqual(s, before)
    }

    /// A reset releases only the stop it was asked for in: a STOP after the request, a request before the stop, no
    /// request at all, or a lost link in between all leave the stop latched.
    func testOnlyAResetAskedForInTheStopStateReleasesIt() {
        var stopAgain = TeleopSession(start: .p4)
        stopAgain.state.markConnected()
        stopAgain.perform(.stop)
        stopAgain.perform(.resetScene)
        stopAgain.perform(.stop)
        stopAgain.perform(.sceneResetDone)
        XCTAssertTrue(stopAgain.state.emergencyStop, "STOP after the request")

        var askedBefore = TeleopSession(start: .p4)
        askedBefore.state.markConnected()
        askedBefore.perform(.resetScene)
        askedBefore.perform(.stop)
        askedBefore.perform(.sceneResetDone)
        XCTAssertTrue(askedBefore.state.emergencyStop, "request before the stop")

        var unasked = TeleopSession(start: .p4)
        unasked.state.markConnected()
        unasked.perform(.stop)
        unasked.perform(.sceneResetDone)
        XCTAssertTrue(unasked.state.emergencyStop, "no request")

        var state = FakeTeleopState()
        state.liveLink = true
        var lost = TeleopSession(state: state, start: .p4)
        lost.perform(.linkUp(gripper: .open))
        lost.perform(.stop)
        lost.perform(.resetScene)
        lost.perform(.linkLost)
        lost.perform(.linkUp(gripper: .open))
        lost.perform(.sceneResetDone)
        XCTAssertTrue(lost.state.emergencyStop, "the link was lost after the request")

        var offline = disconnected(at: .p4)
        offline.perform(.stop)
        offline.perform(.resetScene)
        XCTAssertFalse(offline.state.resetClearsStop, "with no link no reset was asked for")
    }

    /// Found by the safety checker: staying on P5 would let Close lead back to S4 with no stop latched.
    func testAConfirmedResetOnAConnectionScreenGoesToStandby() {
        var s = TeleopSession(start: .p4)
        s.state.markConnected()
        s.perform(.stop)
        s.perform(.resetScene)
        s.perform(.openConnection)
        s.perform(.sceneResetDone)
        XCTAssertFalse(s.state.emergencyStop)
        XCTAssertEqual(s.route, .p4)
        s.perform(.openConnection)
        s.perform(.closeConnection)
        XCTAssertEqual(s.route, .p4)
    }

    func testSwitchingToTheRealServerDropsTheDemoAndStaysOnSettings() {
        var s = TeleopSession(start: .p4)
        s.perform(.holdArmStart)
        s.perform(.openSettings)
        s.state.liveLink = true
        s.perform(.switchLink)
        XCTAssertEqual(s.route, .s6)
        XCTAssertFalse(s.state.connected, "the real server is connected only when it says so")
        XCTAssertFalse(s.state.armMoving)
        s.perform(.back)
        XCTAssertEqual(s.route, .p4)
    }

    func testSwitchingBackToTheDemoConnectsIt() {
        var state = FakeTeleopState()
        state.liveLink = true
        var s = TeleopSession(state: state, start: .s6)
        XCTAssertFalse(s.state.connected)
        s.state.liveLink = false
        s.perform(.switchLink)
        XCTAssertTrue(s.state.connected)
        XCTAssertEqual(s.route, .s6)
    }

    func testSwitchLinkIgnoredWhileEStopped() {
        var s = TeleopSession(start: .s6)
        s.state.markConnected()
        s.perform(.stop)
        s.perform(.switchLink)
        XCTAssertEqual(s.route, .s4)
        XCTAssertTrue(s.state.emergencyStop)
    }
}
