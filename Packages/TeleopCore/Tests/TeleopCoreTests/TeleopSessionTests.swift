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
        var s = TeleopSession(start: .s5)
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
        s.perform(.openFallback)
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
    private func disconnected(at route: Route = .s5) -> TeleopSession {
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
        var s = TeleopSession(start: .s5)
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

    private func connectedFallback() -> TeleopSession {
        var s = TeleopSession(start: .s5)
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
        var s = connectedFallback()
        s.perform(.holdArmStart)
        XCTAssertTrue(s.state.armMoving)
        s.perform(.holdArmEnd)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertTrue(s.drainHaptics().isEmpty)
    }

    func testHoldStartRefusedWhenLatencyBlockedBuzzesThreeShort() {
        var s = connectedFallback()
        blockOnLatency(&s)
        _ = s.drainHaptics()
        s.perform(.holdArmStart)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
    }

    func testHoldStartIgnoredSilentlyWhenEStoppedOrDisconnected() {
        var stopped = connectedFallback()
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
        var s = connectedFallback()
        s.perform(.holdArmStart)
        blockOnLatency(&s)
        s.perform(.holdArmEnd)
        XCTAssertFalse(s.state.armMoving)
    }

    func testHighLatencyWhileHeldStopsArm() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        blockOnLatency(&s)
        XCTAssertFalse(s.state.armMoving)
    }

    func testDisconnectWhileHeldStopsArm() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.disconnect)
        XCTAssertFalse(s.state.armMoving)
    }

    func testHighLatencyWhileEStoppedKeepsS4Visible() {
        var s = connectedFallback()
        s.perform(.stop)
        blockOnLatency(&s)
        XCTAssertEqual(s.route, .s4)
        XCTAssertTrue(s.state.emergencyStop)
        XCTAssertTrue(s.state.commandsBlocked)
    }

    func testStopWhileEStoppedDoesNotRestartLongBuzz() {
        var s = connectedFallback()
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
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.stop)
        XCTAssertFalse(s.state.armMoving)
    }

    func testGripperWhileArmHeldIsBlockedWithCue() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
        s.perform(.holdArmEnd)
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripper, .closed)
    }

    func testGripperMovesOnlyWhileHeld() {
        var s = connectedFallback()
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.state.gripperMoving, .closed)
        XCTAssertEqual(s.state.gripper, .closed)
        s.perform(.gripperEnd)
        XCTAssertNil(s.state.gripperMoving)
        XCTAssertEqual(s.state.gripper, .closed, "the label keeps the last direction")
    }

    func testRepeatedStartWhileHeldBuzzesOnce() {
        var s = connectedFallback()
        s.perform(.gripperStart(.closed))
        s.perform(.gripperStart(.closed))
        XCTAssertEqual(s.drainHaptics(), [.play(.gripperClosed)])
    }

    func testArmHoldTakesOverFromTheGripper() {
        var s = connectedFallback()
        s.perform(.gripperStart(.open))
        s.perform(.holdArmStart)
        XCTAssertNil(s.state.gripperMoving)
        XCTAssertTrue(s.state.armMoving)
    }

    func testStopAndLatencyBlockAndDisconnectStopTheGripper() {
        var stopped = connectedFallback()
        stopped.perform(.gripperStart(.closed))
        stopped.perform(.stop)
        XCTAssertNil(stopped.state.gripperMoving)

        var slow = connectedFallback()
        slow.perform(.gripperStart(.closed))
        blockOnLatency(&slow)
        XCTAssertNil(slow.state.gripperMoving)

        var offline = connectedFallback()
        offline.perform(.gripperStart(.closed))
        offline.perform(.disconnect)
        XCTAssertNil(offline.state.gripperMoving)
    }

    func testJawTurnRunsOnlyWhileHeld() {
        var s = connectedFallback()
        s.perform(.turnStart(.positive))
        XCTAssertEqual(s.state.jawTurning, .positive)
        s.perform(.turnStart(.negative))
        XCTAssertEqual(s.state.jawTurning, .negative)
        s.perform(.turnEnd)
        XCTAssertNil(s.state.jawTurning)
    }

    func testJawTurnIsRefusedWhileTheArmMovesWithCue() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.turnStart(.positive))
        XCTAssertNil(s.state.jawTurning)
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
    }

    func testJawTurnIsIgnoredWhenDisconnectedAndRefusedWhenEStoppedOrBlocked() {
        var offline = disconnected()
        offline.perform(.turnStart(.positive))
        XCTAssertNil(offline.state.jawTurning)
        XCTAssertEqual(offline.drainHaptics(), [])

        var stopped = connectedFallback()
        stopped.perform(.stop)
        _ = stopped.drainHaptics()
        stopped.perform(.turnStart(.positive))
        XCTAssertNil(stopped.state.jawTurning)
        XCTAssertEqual(stopped.drainHaptics(), [])

        var slow = connectedFallback()
        blockOnLatency(&slow)
        slow.perform(.turnStart(.positive))
        XCTAssertNil(slow.state.jawTurning)
        XCTAssertEqual(slow.drainHaptics(), [.play(.commandBlocked)])
    }

    func testTheThreeHeldControlsTakeOverFromEachOther() {
        var s = connectedFallback()
        s.perform(.turnStart(.positive))
        s.perform(.gripperStart(.open))
        XCTAssertNil(s.state.jawTurning)
        XCTAssertEqual(s.state.gripperMoving, .open)
        s.perform(.turnStart(.negative))
        XCTAssertNil(s.state.gripperMoving)
        XCTAssertEqual(s.state.jawTurning, .negative)
        s.perform(.holdArmStart)
        XCTAssertNil(s.state.jawTurning)
        XCTAssertTrue(s.state.armMoving)
    }

    func testWristTiltRunsOnlyWhileHeldAndTakesOverFromEveryOtherControl() {
        var s = connectedFallback()
        s.perform(.turnStart(.tiltDown))
        XCTAssertEqual(s.state.jawTurning, .tiltDown)
        s.perform(.turnStart(.tiltUp))
        XCTAssertEqual(s.state.jawTurning, .tiltUp)
        s.perform(.turnStart(.positive))
        XCTAssertEqual(s.state.jawTurning, .positive, "roll and tilt are one wrist move at a time")
        s.perform(.turnStart(.tiltDown))
        s.perform(.gripperStart(.open))
        XCTAssertNil(s.state.jawTurning)
        s.perform(.turnStart(.tiltUp))
        XCTAssertNil(s.state.gripperMoving)
        s.perform(.holdArmStart)
        XCTAssertNil(s.state.jawTurning)
        s.perform(.turnStart(.tiltDown))
        XCTAssertNil(s.state.jawTurning, "refused while the arm is held")
        XCTAssertEqual(s.drainHaptics().last, .play(.commandBlocked))
        s.perform(.holdArmEnd)
        s.perform(.turnStart(.tiltDown))
        s.perform(.turnEnd)
        XCTAssertNil(s.state.jawTurning)
    }

    func testWristTiltHasTheSameExclusionsAsTheRoll() {
        var offline = disconnected()
        offline.perform(.turnStart(.tiltUp))
        XCTAssertNil(offline.state.jawTurning)
        XCTAssertEqual(offline.drainHaptics(), [])

        var stopped = connectedFallback()
        stopped.perform(.stop)
        _ = stopped.drainHaptics()
        stopped.perform(.turnStart(.tiltDown))
        XCTAssertNil(stopped.state.jawTurning)
        XCTAssertEqual(stopped.drainHaptics(), [])

        var slow = connectedFallback()
        blockOnLatency(&slow)
        slow.perform(.turnStart(.tiltDown))
        XCTAssertNil(slow.state.jawTurning)
        XCTAssertEqual(slow.drainHaptics(), [.play(.commandBlocked)])

        for end in [TeleopAction.stop, .disconnect, .switchLink, .resetScene] {
            var s = connectedFallback()
            s.perform(.turnStart(.tiltUp))
            s.perform(end)
            XCTAssertNil(s.state.jawTurning, "\(end)")
        }
        var slowed = connectedFallback()
        slowed.perform(.turnStart(.tiltUp))
        blockOnLatency(&slowed)
        XCTAssertNil(slowed.state.jawTurning)
    }

    func testStopLatencyBlockAndDisconnectEndTheJawTurn() {
        var stopped = connectedFallback()
        stopped.perform(.turnStart(.positive))
        stopped.perform(.stop)
        XCTAssertNil(stopped.state.jawTurning)

        var slow = connectedFallback()
        slow.perform(.turnStart(.positive))
        blockOnLatency(&slow)
        XCTAssertNil(slow.state.jawTurning)

        var offline = connectedFallback()
        offline.perform(.turnStart(.positive))
        offline.perform(.disconnect)
        XCTAssertNil(offline.state.jawTurning)

        var left = connectedFallback()
        left.perform(.turnStart(.positive))
        left.perform(.switchLink)
        XCTAssertNil(left.state.jawTurning)

        var reset = connectedFallback()
        reset.perform(.turnStart(.positive))
        reset.perform(.resetScene)
        XCTAssertNil(reset.state.jawTurning)
    }

    func testLiveLinkLossAndSlowLinkEndTheJawTurn() {
        var lost = connectedFallback()
        lost.state.liveLink = true
        lost.perform(.turnStart(.negative))
        lost.perform(.linkLost)
        XCTAssertNil(lost.state.jawTurning)

        var slow = connectedFallback()
        slow.state.liveLink = true
        slow.perform(.turnStart(.negative))
        slow.perform(.linkLatency(ms: 500))
        slow.perform(.linkLatency(ms: 500))
        XCTAssertNil(slow.state.jawTurning)
    }

    func testJawTurnEndWorksEvenWhenBlocked() {
        var s = connectedFallback()
        s.perform(.turnStart(.positive))
        s.state.commandsBlocked = true
        s.perform(.turnEnd)
        XCTAssertNil(s.state.jawTurning)
    }

    func testGripperEndWorksEvenWhenBlocked() {
        var s = connectedFallback()
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
        var s = connectedFallback()
        s.perform(.gripperStart(.closed))
        s.perform(.holdArmStart)
        _ = s.drainHaptics()
        s.perform(.resetScene)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertEqual(s.route, .s5)
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
