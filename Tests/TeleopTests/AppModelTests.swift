import TeleopCore
import XCTest
@testable import Teleop

final class SpyHaptics: HapticsPlaying {
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
        model.session.state.commandsBlocked = true
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
        model.session.state.setSmoothing(0.9)
        model.send(.settingsDone)
        model.send(.openSettings)
        XCTAssertEqual(model.session.state.smoothing, 0.9)
    }

    func testS1ConnectReturnsToP5() {
        let model = AppModel(start: .s1, haptics: SpyHaptics())
        model.send(.connect)
        XCTAssertEqual(model.session.route, .p5)
        XCTAssertTrue(model.session.state.connected)
    }

    func testStartRoute() {
        let defaults = UserDefaults(suiteName: "AppModelTests")!
        defaults.removePersistentDomain(forName: "AppModelTests")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .s2, "a fresh install opens on permissions")
        defaults.set(true, forKey: AppModel.firstRunDoneKey)
        XCTAssertEqual(AppModel.startRoute(from: defaults), .p4, "every later launch opens on standby")
        defaults.set("s1_connect", forKey: "startRoute")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .s1)
        defaults.set("nope", forKey: "startRoute")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .p4)
    }

    func testTheUnitTestHostDoesNotOpenTheSavedServer() {
        XCTAssertFalse(AppModel.opensSavedServerAtLaunch(), "this process is the unit-test host")
        XCTAssertTrue(AppModel.opensSavedServerAtLaunch(environment: [:]))
    }

    func testReachingStandbyEndsTheFirstRun() {
        let saved = UserDefaults.standard.object(forKey: AppModel.firstRunDoneKey)
        defer { UserDefaults.standard.set(saved, forKey: AppModel.firstRunDoneKey) }
        let ways: [String: [TeleopAction]] = [
            "skip": [.tutorialSkip],
            "finish": [.tutorialNext(step: 1), .tutorialNext(step: 2), .tutorialNext(step: 3)],
            "STOP during the tutorial, then release": [.stop, .releaseStop],
        ]
        for (way, actions) in ways {
            UserDefaults.standard.removeObject(forKey: AppModel.firstRunDoneKey)
            let model = AppModel(start: .s2, haptics: SpyHaptics())
            model.send(.permissionsContinue)
            XCTAssertEqual(model.session.route, .t1)
            for action in actions.dropLast() { model.send(action) }
            XCTAssertFalse(UserDefaults.standard.bool(forKey: AppModel.firstRunDoneKey), way)
            model.send(actions.last!)
            XCTAssertEqual(model.session.route, .p4, way)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: AppModel.firstRunDoneKey), way)
        }
    }
}
