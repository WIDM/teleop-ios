import TeleopCore
import XCTest
@testable import Teleop

final class VolumeKeyMapperTests: XCTestCase {
    func testHoldUpStartsOnceAndReleaseStops() {
        var mapper = VolumeKeyMapper()
        XCTAssertEqual(mapper.actions(for: .up, phase: .began), [.holdArmStart])
        XCTAssertEqual(mapper.actions(for: .up, phase: .began), [])
        XCTAssertEqual(mapper.actions(for: .up, phase: .ended), [.holdArmEnd])
        XCTAssertEqual(mapper.actions(for: .up, phase: .began), [.holdArmStart])
    }

    func testCancelledUpStops() {
        var mapper = VolumeKeyMapper()
        _ = mapper.actions(for: .up, phase: .began)
        XCTAssertEqual(mapper.actions(for: .up, phase: .cancelled), [.holdArmEnd])
        XCTAssertFalse(mapper.upHeld)
    }

    func testDownTogglesOnPressOnly() {
        var mapper = VolumeKeyMapper()
        XCTAssertEqual(mapper.actions(for: .down, phase: .began), [.toggleGripper])
        XCTAssertEqual(mapper.actions(for: .down, phase: .ended), [])
        XCTAssertEqual(mapper.actions(for: .down, phase: .cancelled), [])
    }

    /// Through the real session: vol+ moves the arm, vol− while held is refused with three short pulses.
    func testKeysThroughSession() {
        let model = AppModel(start: .p4, haptics: NoHaptics())
        model.session.state.markConnected()
        var mapper = VolumeKeyMapper()
        let press = { (key: VolumeKey, phase: VolumeKeyPhase) in
            for action in mapper.actions(for: key, phase: phase) { model.send(action) }
        }
        press(.up, .began)
        XCTAssertTrue(model.session.state.armMoving)
        press(.down, .began)
        XCTAssertEqual(model.session.state.gripper, .open)
        press(.up, .ended)
        XCTAssertFalse(model.session.state.armMoving)
        press(.down, .began)
        XCTAssertEqual(model.session.state.gripper, .closed)
    }
}
