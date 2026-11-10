import TeleopCore
import simd
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

final class PoseLogTests: XCTestCase {
    func testHoldLogsHowFarThePhoneMoved() {
        var now = matrix_identity_float4x4
        let model = AppModel(start: .p4, haptics: NoHaptics(), pose: { now })
        model.session.state.markConnected()
        model.send(.holdArmStart)
        now.columns.3 = SIMD4(0.10, 0, -0.05, 1)
        model.send(.holdArmEnd)
        XCTAssertTrue(model.debugLog.last?.hasSuffix("pose Δ x 10.0 y 0.0 z -5.0 cm, 0°") == true, "\(model.debugLog)")
    }

    func testHoldWithoutTrackingSaysSo() {
        let model = AppModel(start: .p4, haptics: NoHaptics(), pose: { nil })
        model.session.state.markConnected()
        model.send(.holdArmStart)
        XCTAssertTrue(model.debugLog.contains { $0.hasSuffix("pose: no tracking") })
    }

    func testRotationAngle() {
        let quarter = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        XCTAssertEqual(PoseDelta(from: matrix_identity_float4x4, to: quarter).rotationDegrees, 90, accuracy: 0.01)
    }

    func testRotationAcrossHalfTurnIsTheShortWay() {
        let axis = SIMD3<Float>(0, 1, 0)
        let start = simd_float4x4(simd_quatf(angle: 179 * .pi / 180, axis: axis))
        let end = simd_float4x4(simd_quatf(angle: -179 * .pi / 180, axis: axis))
        XCTAssertEqual(PoseDelta(from: start, to: end).rotationDegrees, 2, accuracy: 0.05)
    }
}
