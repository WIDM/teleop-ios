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
        XCTAssertEqual(s.drainHaptics(), [.cancel])
    }

    func testGripperToggleEmitsMatchingCue() {
        var s = TeleopSession(start: .s5)
        s.perform(.toggleGripper)
        s.perform(.toggleGripper)
        XCTAssertEqual(s.drainHaptics(), [.play(.gripperClosed), .play(.gripperOpened)])
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
}
