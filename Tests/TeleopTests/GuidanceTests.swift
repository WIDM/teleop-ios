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

    /// Measured in Isaac Sim on 2026-11-11: with the reported gripper point here, closing the jaws picked the
    /// cube up. The guidance must say the gripper is ON the cube at this pose, in all three directions.
    func testAtTheMeasuredGraspPoseTheGripperIsOnTheCube() {
        let graspPose = SIMD3<Float>(0.005, -0.134, 0.139)
        let guidance = Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .open)
        XCTAssertEqual(guidance.target, .cube)
        XCTAssertLessThan(simd_length(guidance.offset), 0.006, "offset \(guidance.offset * 100) cm")
        let map = MiniMapLayout(guidance)
        XCTAssertLessThan(simd_distance(map.point(map.arm, side: 168), map.point(map.cube, side: 168)), 6, "ring is not on the cube")
        XCTAssertEqual(map.barOffset(map.arm.z, height: 168), map.barOffset(map.cube.z, height: 168), accuracy: 8)
    }

    /// From the start pose the cube is nearly under the jaws: about 1.6 cm right, under 1 cm back, 2 cm down.
    func testFromTheStartTheCubeIsAlmostUnderTheJaws() {
        let guidance = Guidance.make(arm: arm, cube: cube, goal: goal, gripper: .open)
        XCTAssertEqual(guidance.offset.x, 0.016, accuracy: 0.002)
        XCTAssertEqual(guidance.offset.y, -0.007, accuracy: 0.003)
        XCTAssertEqual(guidance.offset.z, -0.021, accuracy: 0.003)
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
        TestPose.portrait(turned: -degrees, about: SIMD3(1, 0, 0))
    }

    private func rolled(_ degrees: Float) -> simd_float4x4 {
        TestPose.portrait(turned: degrees, about: SIMD3(0, 0, 1))
    }

    func testUprightPhoneIsFine() {
        XCTAssertEqual(PhonePosture.of(TestPose.portrait), .upright)
        XCTAssertEqual(PhonePosture.of(TestPose.portrait(turned: 115, about: SIMD3(0, 1, 0))), .upright, "facing another way is still fine")
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

    func testComingBackNeedsAMarginSoItDoesNotFlicker() {
        // 35 degrees of roll is inside the 40 degree limit, but not yet 10 degrees inside it.
        XCTAssertEqual(PhonePosture.of(rolled(35)), .upright)
        XCTAssertEqual(PhonePosture.of(rolled(35), previous: .tilted), .tilted)
        XCTAssertEqual(PhonePosture.of(rolled(25), previous: .tilted), .upright)
    }
}

final class MiniMapLayoutTests: XCTestCase {
    private let arm = SIMD3<Float>(0.021, -0.141, 0.160)
    private let cube = SIMD3<Float>(0.005, -0.200, 0.1025)
    private let goal = SIMD3<Float>(0.075, -0.200, 0.1035)
    private let side: Float = 168

    private func layout(arm: SIMD3<Float>? = nil, gripper: GripperState = .open) -> MiniMapLayout {
        MiniMapLayout(Guidance.make(arm: arm ?? self.arm, cube: cube, goal: goal, gripper: gripper))
    }

    func testCubeIsDrawnAheadAndToTheRightOfTheGripper() {
        let map = layout()
        let gripper = map.point(map.arm, side: side), red = map.point(map.cube, side: side)
        // The cube is 1.6 cm to the operator's right and 5.9 cm forward: right of and above the ring.
        XCTAssertGreaterThan(red.x, gripper.x)
        XCTAssertLessThan(red.y, gripper.y)
    }

    func testGoalIsDrawnToTheLeftOfTheCube() {
        let map = layout()
        XCTAssertLessThan(map.point(map.goal, side: side).x, map.point(map.cube, side: side).x)
        XCTAssertEqual(map.point(map.goal, side: side).y, map.point(map.cube, side: side).y, accuracy: 0.5)
    }

    func testEverythingStaysInsideTheMapWithRoomToSpare() {
        for arm in [self.arm, SIMD3<Float>(-0.06, -0.06, 0.24), SIMD3<Float>(0.10, -0.22, 0.08)] {
            let map = layout(arm: arm)
            for place in [map.arm, map.cube, map.goal] {
                let point = map.point(place, side: side)
                let room = map.length(MiniMapLayout.margin, side: side) - 0.5
                XCTAssertGreaterThanOrEqual(point.x, room)
                XCTAssertLessThanOrEqual(point.x, side - room)
                XCTAssertGreaterThanOrEqual(point.y, room)
                XCTAssertLessThanOrEqual(point.y, side - room)
            }
        }
    }

    func testMovingTheGripperForwardMovesTheRingUpTheMap() {
        let before = layout(), after = layout(arm: arm + SIMD3(0, -0.02, 0))
        // Same zoom, because the cube and goal still bound the picture.
        XCTAssertEqual(before.span, after.span, accuracy: 0.0001)
        XCTAssertLessThan(after.point(after.arm, side: side).y, before.point(before.arm, side: side).y)
    }

    func testHeldCubeTravelsWithTheGripper() {
        // Closed, and within the holding radius of where the server last saw the cube.
        let map = layout(arm: SIMD3(cube.x + 0.02, cube.y, 0.15), gripper: .closed)
        XCTAssertEqual(map.cube.x, map.arm.x)
        XCTAssertEqual(map.cube.y, map.arm.y)
    }

    func testHeightBarPutsTheGripperAboveTheCubeAndClampsAtTheEnds() {
        let map = layout()
        XCTAssertLessThan(map.barOffset(map.arm.z, height: 168), map.barOffset(map.cube.z, height: 168))
        XCTAssertEqual(map.barOffset(10, height: 168), 0)
        XCTAssertEqual(map.barOffset(-10, height: 168), 168)
    }

    func testSmallSceneIsNotBlownUp() {
        let near = MiniMapLayout(Guidance.make(arm: cube + SIMD3(0.01, 0, 0.05), cube: cube, goal: cube + SIMD3(0.03, 0, 0), gripper: .open))
        XCTAssertEqual(near.span, MiniMapLayout.minimumSpan, accuracy: 0.0001)
    }
}

final class PostureHapticsTests: XCTestCase {
    private var camera: simd_float4x4? = TestPose.portrait
    private var spy: SpyHaptics!
    private var model: AppModel!

    override func setUp() {
        camera = TestPose.portrait
        spy = SpyHaptics()
        model = AppModel(start: .p4, haptics: spy, pose: { [unowned self] in camera }, liveLink: false)
    }

    private var sideways: simd_float4x4 { TestPose.portrait(turned: 90, about: SIMD3(0, 0, 1)) }

    func testFirstReadingIsSilent() {
        model.refreshPosture()
        XCTAssertEqual(model.posture, .upright)
        XCTAssertEqual(spy.commands, [])
    }

    func testTwoBuzzesWhenItGoesWrongOneWhenItComesBack() {
        model.refreshPosture()
        camera = sideways
        model.refreshPosture()
        model.refreshPosture()
        XCTAssertEqual(model.posture, .tilted)
        XCTAssertEqual(spy.commands, [.play(.postureOff)], "once per change, not once per reading")
        camera = TestPose.portrait
        model.refreshPosture()
        XCTAssertEqual(spy.commands, [.play(.postureOff), .play(.postureOk)])
    }

    func testLosingAndRegainingTrackingIsSilent() {
        model.refreshPosture()
        camera = nil
        model.refreshPosture()
        camera = TestPose.portrait
        model.refreshPosture()
        XCTAssertEqual(spy.commands, [])
    }

    func testNoPostureBuzzOverTheEStopBuzz() {
        model.refreshPosture()
        model.session.state.markConnected()
        model.send(.stop)
        camera = sideways
        model.refreshPosture()
        XCTAssertEqual(model.posture, .tilted)
        XCTAssertEqual(spy.commands, [.play(.emergencyLoop)])
    }
}
