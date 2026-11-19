import simd
import TeleopCore
import XCTest
@testable import Teleop

final class PoseLogTests: XCTestCase {
    func testHoldLogsHowFarThePhoneMoved() {
        var now = matrix_identity_float4x4
        let model = AppModel(start: .p4, haptics: NoHaptics(), pose: { now }, liveLink: false)
        model.session.state.markConnected()
        model.send(.holdArmStart)
        now.columns.3 = SIMD4(0.10, 0, -0.05, 1)
        model.send(.holdArmEnd)
        XCTAssertTrue(model.debugLog.last?.hasSuffix("pose Δ x 10.0 y 0.0 z -5.0 cm, 0°") == true, "\(model.debugLog)")
    }

    func testHoldWithoutTrackingSaysSo() {
        let model = AppModel(start: .p4, haptics: NoHaptics(), pose: { nil }, liveLink: false)
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
