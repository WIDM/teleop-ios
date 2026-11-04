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
        XCTAssertEqual(spy.commands, [.play(.emergencyLoop), .cancel])
        XCTAssertEqual(model.session.route, .p4)
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
