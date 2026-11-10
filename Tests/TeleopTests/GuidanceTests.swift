import simd
import TeleopCore
import XCTest
@testable import Teleop

final class GuidanceTests: XCTestCase {
    // The simulator's own numbers after a scene reset, in metres in the robot base frame.
    private let arm = SIMD3<Float>(0.021, -0.141, 0.160)
    private let cube = SIMD3<Float>(0.005, -0.200, 0.1025)
    private let goal = SIMD3<Float>(0.075, -0.200, 0.1035)

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), 0.0006, "\(a) vs \(b)", file: file, line: line)
    }

    func testFromTheStartTheCubeIsRightForwardAndDown() {
        let guidance = Guidance.make(arm: arm, cube: cube, goal: goal, gripper: .open)
        XCTAssertEqual(guidance.target, .cube)
        // 1.6 cm right (−X), 5.9 cm forward (−Y), 5.75 cm down.
        assertClose(guidance.offset, SIMD3(0.016, 0.059, -0.0575))
    }

    func testClosedGripperFarFromTheCubeStillPointsAtTheCube() {
        XCTAssertEqual(Guidance.make(arm: arm, cube: cube, goal: goal, gripper: .closed).target, .cube)
    }

    func testHoldingTheCubePointsAtTheGoalFromTheCube() {
        let above = SIMD3<Float>(cube.x + 0.01, cube.y, 0.15)
        let guidance = Guidance.make(arm: above, cube: cube, goal: goal, gripper: .closed)
        XCTAssertEqual(guidance.target, .goal)
        // The goal is 7 cm toward +X, which is to the operator's left.
        assertClose(guidance.offset, SIMD3(-0.07, 0, 0.001))
    }

    func testOpenGripperOverTheCubeIsNotHoldingIt() {
        let above = SIMD3<Float>(cube.x, cube.y, 0.15)
        XCTAssertEqual(Guidance.make(arm: above, cube: cube, goal: goal, gripper: .open).target, .cube)
    }

    func testCubeInsideTheGoalAreaIsDone() {
        let placed = SIMD3<Float>(goal.x - 0.02, goal.y + 0.02, cube.z)
        XCTAssertEqual(Guidance.make(arm: arm, cube: placed, goal: goal, gripper: .open).target, .done)
        let justOutside = SIMD3<Float>(goal.x - 0.03, goal.y, cube.z)
        XCTAssertEqual(Guidance.make(arm: arm, cube: justOutside, goal: goal, gripper: .open).target, .cube)
    }

    private func pitchedBack(_ degrees: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: -degrees * .pi / 180, axis: SIMD3(1, 0, 0)))
    }

    private func rolled(_ degrees: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 0, 1)))
    }

    func testUprightPhoneIsFine() {
        XCTAssertEqual(PhonePosture.of(matrix_identity_float4x4), .upright)
        let turned = simd_float4x4(simd_quatf(angle: 2, axis: SIMD3(0, 1, 0)))
        XCTAssertEqual(PhonePosture.of(turned), .upright, "facing another way is still fine")
    }

    func testLeaningBackIsFineAllTheWayToFlat() {
        for degrees: Float in [30, 45, 60, 75, 90] {
            XCTAssertEqual(PhonePosture.of(pitchedBack(degrees)), .upright, "\(degrees) degrees back")
        }
    }

    func testSmallRollIsFineButSidewaysIsNot() {
        XCTAssertEqual(PhonePosture.of(rolled(25)), .upright)
        XCTAssertEqual(PhonePosture.of(rolled(-25)), .upright)
        XCTAssertEqual(PhonePosture.of(rolled(60)), .tilted)
        XCTAssertEqual(PhonePosture.of(rolled(90)), .tilted)
        XCTAssertEqual(PhonePosture.of(rolled(-90)), .tilted)
    }

    func testScreenTowardTheFloorIsNotFine() {
        XCTAssertEqual(PhonePosture.of(pitchedBack(-20)), .upright, "a slight forward lean is fine")
        XCTAssertEqual(PhonePosture.of(pitchedBack(-50)), .tilted)
        XCTAssertEqual(PhonePosture.of(pitchedBack(-90)), .tilted)
    }

    func testUpsideDownOrNoPoseIsNotFine() {
        XCTAssertEqual(PhonePosture.of(rolled(180)), .tilted)
        XCTAssertEqual(PhonePosture.of(nil), .unknown)
    }
}
