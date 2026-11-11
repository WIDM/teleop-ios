import simd
import TeleopServerModel
import XCTest
@testable import Teleop

/// The server model and the app's robot profile describe the same simulator. If one is re-measured, the other must
/// follow, or the guide and the model's grasp disagree.
final class ServerModelProfileTests: XCTestCase {
    func testTheModelGraspsWhereTheAppsGuideSaysTheJawsPinch() {
        let model = ServerModelConfig.s4Simulator
        let profile = RobotProfile.so101Simulator
        XCTAssertEqual(SIMD3<Float>(model.toolOffset), profile.toolOffset)
        XCTAssertEqual(SIMD3<Float>(model.baseInWorld), profile.baseInWorld)
        XCTAssertEqual(Float(model.graspToleranceAcross), profile.graspTolerance.x)
        XCTAssertEqual(Float(model.graspToleranceHeight), profile.graspTolerance.y)
        XCTAssertEqual(Float(model.cubeSize), profile.cubeSize)
        XCTAssertEqual(model.wristRollStart == model.sidewaysRoll, profile.jawsStartSideways)
    }
}
