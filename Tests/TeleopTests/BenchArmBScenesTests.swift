import TeleopCore
import XCTest
@testable import Teleop

/// The UI tests' scenes drawn for bench arm B, whose base z points down.
final class BenchArmBScenesTests: XCTestCase {
    /// The UI tests' scenes are built along the profile's up, not base z: for B, whose base z points down, the object
    /// and the goal rest on a table below the base, every reading but "outside" sits inside the work box, and the
    /// guide says "On target" where the scene puts the jaws on the object.
    func testTheOperatingScenesFollowBsUp() throws {
        let profile = TestProfiles.benchB
        let frames = profile.frames
        let scenes = OperatingFixtures(profile: profile).displays
        XCTAssertEqual(scenes.count, OperatingFixtures.all.count, "the same scenes as the SO-101's")
        let ready = try XCTUnwrap(scenes["ready"]?.arm)
        let target = try XCTUnwrap(ready.target), goal = try XCTUnwrap(ready.goal)
        XCTAssertEqual(Float(frames.height(of: SIMD3<Double>(target))), profile.tableHeight + 0.0125, accuracy: 1e-5)
        XCTAssertEqual(Float(frames.height(of: SIMD3<Double>(goal))), profile.tableHeight + 0.0135, accuracy: 1e-5)
        XCTAssertLessThan(target.z, 0.3, "the table is below B's base, which hangs over it")
        XCTAssertGreaterThan(target.z, 0, "and below it along B's base z, which points down")
        for (name, display) in scenes {
            guard let arm = display.arm, name != "outside" else { continue }
            let pinch = arm.pinchPoint
            for axis in 0..<3 {
                XCTAssertGreaterThanOrEqual(pinch[axis], profile.workspaceMin[axis], "\(name) axis \(axis)")
                XCTAssertLessThanOrEqual(pinch[axis], profile.workspaceMax[axis], "\(name) axis \(axis)")
            }
        }
        let outside = try XCTUnwrap(scenes["outside"]?.arm?.pinchPoint)
        XCTAssertLessThan(outside.x, profile.workspaceMin.x)
        XCTAssertEqual(scenes["opening"]?.guide?.onTarget, true)
        XCTAssertEqual(scenes["approximate"]?.guide?.onTarget, false, "an estimate that may be off is no On target")
        let stalled = try XCTUnwrap(scenes["ready_aids"]?.arm)
        XCTAssertEqual(
            stalled.lowestGripperZ,
            profile.tableHeight + 0.005 - Float(frames.height(of: SIMD3<Double>(profile.toolOffset))))
    }
}
