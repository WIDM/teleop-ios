import XCTest
@testable import TeleopCore

final class TeleopSessionTests: XCTestCase {
    func testOnSiteNextGoesToPermissions() {
        var s = TeleopSession()
        s.perform(.modeNext)
        XCTAssertEqual(s.route, .s2)
        XCTAssertTrue(s.state.connected)
    }

    func testCloudNextGoesToCheckPass() {
        var s = TeleopSession()
        s.state.selectCloud()
        s.perform(.modeNext)
        XCTAssertEqual(s.route, .p2)
    }

    func testCloudFailThenUseOnSite() {
        var s = TeleopSession()
        s.state.selectCloud()
        s.perform(.modeNext)
        s.perform(.cloudSimulateFail)
        XCTAssertEqual(s.route, .p3)
        XCTAssertFalse(s.state.heartbeatOk)
        s.perform(.cloudUseOnSite)
        XCTAssertEqual(s.route, .s2)
        XCTAssertEqual(s.state.mode, .onSite)
    }

    func testTutorialRunsThenSkipsOnceDone() {
        var s = TeleopSession()
        s.perform(.modeNext)
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

    func testGripperToggleEmitsMatchingCue() {
        var s = TeleopSession(start: .s5)
        s.state.markConnected()
        s.perform(.toggleGripper)
        s.perform(.toggleGripper)
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
        s.perform(.toggleGripper)
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

    func testGripperRefusedWhenDisconnected() {
        var s = TeleopSession(start: .s5)
        s.perform(.toggleGripper)
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertTrue(s.drainHaptics().isEmpty)
    }

    func testGripperRefusedWhenCommandsBlocked() {
        var s = TeleopSession(start: .s5)
        s.state.markConnected()
        s.perform(.simulateHighLatency)
        _ = s.drainHaptics()
        s.perform(.toggleGripper)
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
        s.perform(.toggleGripper)
        XCTAssertEqual(s.state.gripper, .closed)
    }

    func testRecordingFlow() {
        var s = TeleopSession(start: .p4)
        s.perform(.openRecording)
        s.perform(.recordingAppeared)
        s.perform(.recordingTick)
        s.perform(.recordingTick)
        XCTAssertEqual(s.state.recordingElapsedSec, 2)
        s.perform(.stopRecording)
        XCTAssertEqual(s.route, .s3b)
        XCTAssertFalse(s.state.isRecording)
        s.perform(.saveRecording)
        XCTAssertEqual(s.route, .p4)
    }

    func testFallbackRecordingBackReturnsToFallback() {
        var s = TeleopSession(start: .p4)
        s.perform(.openFallback)
        s.perform(.startFallbackRecording)
        XCTAssertEqual(s.route, .s5a)
        s.perform(.back)
        XCTAssertEqual(s.route, .s5)
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
        s.perform(.simulateHighLatency)
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

        var offline = TeleopSession(start: .s5)
        offline.perform(.holdArmStart)
        XCTAssertFalse(offline.state.armMoving)
        XCTAssertTrue(offline.drainHaptics().isEmpty)
    }

    func testHoldEndStopsEvenWhenBlockedWhileHeld() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.simulateHighLatency)
        s.perform(.holdArmEnd)
        XCTAssertFalse(s.state.armMoving)
    }

    func testStopClearsArmHold() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.stop)
        XCTAssertFalse(s.state.armMoving)
    }

    func testGripperToggleWhileArmHeldIsBlockedWithCue() {
        var s = connectedFallback()
        s.perform(.holdArmStart)
        s.perform(.toggleGripper)
        XCTAssertEqual(s.state.gripper, .open)
        XCTAssertEqual(s.drainHaptics(), [.play(.commandBlocked)])
        s.perform(.holdArmEnd)
        s.perform(.toggleGripper)
        XCTAssertEqual(s.state.gripper, .closed)
    }

    func testBlockedGripperCueIsThreeShortPulses() {
        XCTAssertEqual(HapticCue.commandBlocked.pattern.pulses.count, 3)
    }

    func testReleaseStopCueIsOneShortBuzz() {
        XCTAssertEqual(HapticCue.stopReleased.pattern, HapticPattern.shortBuzz(count: 1))
        XCTAssertFalse(HapticCue.stopReleased.pattern.repeats)
    }

    func testDeadbandAndSmoothingSurviveNavigation() {
        var s = TeleopSession(start: .p4)
        s.perform(.openSettings)
        s.state.setDeadband(degrees: 5)
        s.state.setSmoothing(0.8)
        s.perform(.settingsDone)
        s.perform(.openSettings)
        XCTAssertEqual(s.route, .s6)
        XCTAssertEqual(s.state.deadbandDegrees, 5)
        XCTAssertEqual(s.state.smoothing, 0.8)
    }

    func testSettingsDefaultsMatchFigma() {
        let state = FakeTeleopState()
        XCTAssertEqual(state.sensitivity, 1.0)
        XCTAssertEqual(state.deadbandDegrees, 2)
        XCTAssertEqual(state.smoothing, 0.3)
    }

    func testSettingsValuesAreClamped() {
        var state = FakeTeleopState()
        state.setDeadband(degrees: 99)
        state.setSmoothing(-1)
        XCTAssertEqual(state.deadbandDegrees, 10)
        XCTAssertEqual(state.smoothing, 0)
    }
}
