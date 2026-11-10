import TeleopCore
import XCTest
@testable import Teleop

private final class SpyHaptics: HapticsPlaying {
    var commands: [HapticCommand] = []
    func run(_ command: HapticCommand) { commands.append(command) }
}

final class AppModelTests: XCTestCase {
    func testStopPlaysEmergencyLoopAndReleaseCancels() {
        let spy = SpyHaptics()
        let model = AppModel(start: .p4, haptics: spy)
        model.send(.stop)
        model.send(.releaseStop)
        XCTAssertEqual(spy.commands, [.play(.emergencyLoop), .cancel, .play(.stopReleased)])
        XCTAssertEqual(model.session.route, .p4)
    }

    func testBlockedGripperReachesHapticsAsThreeShort() {
        let spy = SpyHaptics()
        let model = AppModel(start: .s5, haptics: spy)
        model.session.state.markConnected()
        model.send(.simulateHighLatency)
        model.send(.openFallback)
        model.send(.gripperStart(.closed))
        XCTAssertEqual(spy.commands, [.play(.commandBlocked)])
    }

    func testHoldAreaStartsAndStopsArm() {
        let model = AppModel(start: .s5, haptics: SpyHaptics())
        model.session.state.markConnected()
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        model.send(.holdArmEnd)
        XCTAssertFalse(model.session.state.armMoving)
    }

    func testSettingsSurviveLeavingS6() {
        let model = AppModel(start: .p4, haptics: SpyHaptics())
        model.send(.openSettings)
        model.session.state.setDeadband(degrees: 6)
        model.session.state.setSmoothing(0.9)
        model.send(.settingsDone)
        model.send(.openSettings)
        XCTAssertEqual(model.session.state.deadbandDegrees, 6)
        XCTAssertEqual(model.session.state.smoothing, 0.9)
    }

    func testS1ConnectReturnsToP5() {
        let model = AppModel(start: .s1, haptics: SpyHaptics())
        model.send(.connect)
        XCTAssertEqual(model.session.route, .p5)
        XCTAssertTrue(model.session.state.connected)
    }

    func testStartRouteArgument() {
        let defaults = UserDefaults(suiteName: "AppModelTests")!
        defaults.removePersistentDomain(forName: "AppModelTests")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .p1)
        defaults.set("s1_connect", forKey: "startRoute")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .s1)
        defaults.set("nope", forKey: "startRoute")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .p1)
    }
}
