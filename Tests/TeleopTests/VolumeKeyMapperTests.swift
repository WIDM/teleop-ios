import TeleopCore
import simd
import XCTest
@testable import Teleop

final class VolumeKeyMapperTests: XCTestCase {
    private func holding(arm: Bool = false, gripper: GripperState? = nil) -> FakeTeleopState {
        var state = FakeTeleopState()
        state.armMoving = arm
        state.gripperMoving = gripper
        return state
    }

    func testHoldUpStartsOnceAndReleaseStops() {
        var mapper = VolumeKeyMapper()
        let idle = holding()
        XCTAssertEqual(mapper.actions(for: .up, phase: .began, in: idle), [.holdArmStart])
        XCTAssertEqual(mapper.actions(for: .up, phase: .began, in: idle), [])
        XCTAssertEqual(mapper.actions(for: .up, phase: .ended, in: holding(arm: true)), [.holdArmEnd])
        XCTAssertEqual(mapper.actions(for: .up, phase: .began, in: idle), [.holdArmStart])
    }

    func testCancelledUpStops() {
        var mapper = VolumeKeyMapper()
        _ = mapper.actions(for: .up, phase: .began, in: holding())
        XCTAssertEqual(mapper.actions(for: .up, phase: .cancelled, in: holding(arm: true)), [.holdArmEnd])
        XCTAssertFalse(mapper.upHeld)
    }

    func testDownClosesWhileHeldAndStopsOnRelease() {
        var mapper = VolumeKeyMapper()
        XCTAssertEqual(mapper.actions(for: .down, phase: .began, in: holding()), [.gripperStart(.closed)])
        XCTAssertEqual(mapper.actions(for: .down, phase: .began, in: holding(gripper: .closed)), [], "key repeat must not start again")
        XCTAssertEqual(mapper.actions(for: .down, phase: .ended, in: holding(gripper: .closed)), [.gripperEnd])
        XCTAssertEqual(mapper.actions(for: .down, phase: .began, in: holding()), [.gripperStart(.closed)])
        XCTAssertEqual(mapper.actions(for: .down, phase: .cancelled, in: holding(gripper: .closed)), [.gripperEnd])
        XCTAssertFalse(mapper.downHeld)
    }

    func testReleasingDownDoesNotEndAnOpenHoldThatTookOver() {
        var mapper = VolumeKeyMapper()
        _ = mapper.actions(for: .down, phase: .began, in: holding())
        XCTAssertEqual(mapper.actions(for: .down, phase: .ended, in: holding(gripper: .open)), [])
        XCTAssertFalse(mapper.downHeld)
        _ = mapper.actions(for: .down, phase: .began, in: holding())
        XCTAssertEqual(mapper.actions(for: .down, phase: .cancelled, in: holding(gripper: .open)), [])
        XCTAssertFalse(mapper.downHeld)
        XCTAssertEqual(mapper.actions(for: .down, phase: .began, in: holding()), [.gripperStart(.closed)], "the key is free again")
    }

    func testReleasingDownAfterAnythingElseEndedTheHoldSendsNothing() {
        var mapper = VolumeKeyMapper()
        _ = mapper.actions(for: .down, phase: .began, in: holding())
        XCTAssertEqual(mapper.actions(for: .down, phase: .ended, in: holding()), [])
    }

    /// Through the real session: vol+ moves the arm, vol− while held is refused with three short pulses.
    func testKeysThroughSession() {
        let model = AppModel(start: .p4, haptics: NoHaptics())
        model.session.state.markConnected()
        var mapper = VolumeKeyMapper()
        let press = { (key: VolumeKey, phase: VolumeKeyPhase) in
            for action in mapper.actions(for: key, phase: phase, in: model.session.state) { model.send(action) }
        }
        press(.up, .began)
        XCTAssertTrue(model.session.state.armMoving)
        press(.down, .began)
        XCTAssertEqual(model.session.state.gripper, .open)
        XCTAssertNil(model.session.state.gripperMoving)
        press(.down, .ended)
        press(.up, .ended)
        XCTAssertFalse(model.session.state.armMoving)
        press(.down, .began)
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        press(.down, .ended)
        XCTAssertNil(model.session.state.gripperMoving)
        XCTAssertEqual(model.session.state.gripper, .closed)
    }

    /// vol− closes, a finger on the Open handle takes over, then vol− is released: the gripper keeps opening.
    func testReleasingDownKeepsAnOpenHoldFromTheHandle() {
        let model = AppModel(start: .p4, haptics: NoHaptics())
        model.session.state.markConnected()
        var mapper = VolumeKeyMapper()
        for action in mapper.actions(for: .down, phase: .began, in: model.session.state) { model.send(action) }
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        model.send(.gripperStart(.open))
        for action in mapper.actions(for: .down, phase: .ended, in: model.session.state) { model.send(action) }
        XCTAssertEqual(model.session.state.gripperMoving, .open)
        model.send(.gripperEnd)
        XCTAssertNil(model.session.state.gripperMoving)
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
