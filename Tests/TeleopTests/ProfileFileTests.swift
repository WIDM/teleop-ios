import Foundation
import TeleopCore
import XCTest
@testable import Teleop

/// The SO-101 profile file bundled with the app holds exactly the numbers the app ran with before profiles were files.
final class ProfileFileTests: XCTestCase {
    func testTheBundledSO101FileEqualsTheConstantFieldByField() throws {
        let url = try XCTUnwrap(Bundle(for: AppModel.self).url(forResource: "so101-s4-sim", withExtension: "json"))
        let file = try RobotProfile.load(json: Data(contentsOf: url))
        let constant = RobotProfile.so101Simulator
        XCTAssertEqual(file.name, constant.name)
        XCTAssertEqual(file.toolOffset, constant.toolOffset)
        XCTAssertEqual(file.offsetMeasuredAt, constant.offsetMeasuredAt)
        XCTAssertEqual(file.offsetMeasuredFlexDeg, constant.offsetMeasuredFlexDeg)
        XCTAssertEqual(file.offsetMeasuredRollDeg, constant.offsetMeasuredRollDeg)
        XCTAssertEqual(file.estimateBound, constant.estimateBound)
        XCTAssertEqual(file.baseInWorld, constant.baseInWorld)
        XCTAssertEqual(file.graspTolerance, constant.graspTolerance)
        XCTAssertEqual(file.targetSize, constant.targetSize)
        XCTAssertEqual(file.goalSize, constant.goalSize)
        XCTAssertEqual(file.gripperOpenDeg, constant.gripperOpenDeg)
        XCTAssertEqual(file.gripperEmptyDeg, constant.gripperEmptyDeg)
        XCTAssertEqual(file.workspaceMin, constant.workspaceMin)
        XCTAssertEqual(file.workspaceMax, constant.workspaceMax)
        XCTAssertEqual(file.tableHeight, constant.tableHeight)
        XCTAssertEqual(file.rollSign, constant.rollSign)
        XCTAssertEqual(file.tiltSign, constant.tiltSign)
        XCTAssertEqual(file.recloseLoosensGrip, constant.recloseLoosensGrip)
        XCTAssertEqual(file.usesDirectionalBlockedFeedback, constant.usesDirectionalBlockedFeedback)
        XCTAssertEqual(file.assist.lock, constant.assist.lock)
        XCTAssertEqual(file.assist.goTo, constant.assist.goTo)
        XCTAssertEqual(file.assist.guide, constant.assist.guide)
        XCTAssertEqual(file.assist.explain, constant.assist.explain)
        XCTAssertEqual(file.assist.views, constant.assist.views)
        XCTAssertEqual(file.onTargetWindow, constant.onTargetWindow)
        XCTAssertEqual(file, constant, "a field the comparisons above miss")
    }
}
