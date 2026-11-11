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

    /// Measured in Isaac Sim on 2026-11-11 with the jaws turned sideways: with the reported gripper point here,
    /// closing the jaws held the cube. The guidance must say the gripper is ON the cube at this pose, in all three directions.
    func testAtTheMeasuredGraspPoseTheGripperIsOnTheCube() {
        let graspPose = SIMD3<Float>(-0.002, -0.164, 0.1405)
        let guidance = Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .open)
        XCTAssertEqual(guidance.target, .cube)
        XCTAssertLessThan(simd_length(guidance.offset), 0.006, "offset \(guidance.offset * 100) cm")
        let map = MiniMapLayout(guidance)
        XCTAssertLessThan(simd_distance(map.top(map.arm), map.top(map.cube)), 6, "ring is not on the cube")
        XCTAssertEqual(map.ring.y, map.sideCube.centre.y, accuracy: 8, "ring is not at the cube's height")
        XCTAssertEqual(map.heightGap?.kind, .level)
    }

    /// From the start pose the cube is a little right of and ahead of the jaws: about 2.3 cm right, 2.3 cm ahead, 2 cm down.
    func testFromTheStartTheCubeIsRightOfAndAheadOfTheJaws() {
        let guidance = Guidance.make(arm: arm, cube: cube, goal: goal, gripper: .open)
        XCTAssertEqual(guidance.offset.x, 0.023, accuracy: 0.002)
        XCTAssertEqual(guidance.offset.y, 0.023, accuracy: 0.003)
        XCTAssertEqual(guidance.offset.z, -0.0195, accuracy: 0.003)
    }

    /// The reported point that puts the jaws on the cube.
    private let graspPose = SIMD3<Float>(-0.002, -0.164, 0.1405)

    func testClosedGripperAwayFromTheCubeStillPointsAtTheCube() {
        let away = graspPose + SIMD3(0.05, 0, 0.02)
        XCTAssertEqual(Guidance.make(arm: away, cube: cube, goal: goal, gripper: .closed).target, .cube)
    }

    func testHoldingTheCubePointsAtTheGoalFromTheCube() {
        let guidance = Guidance.make(arm: graspPose + SIMD3(0, 0, 0.03), cube: cube, goal: goal, gripper: .closed)
        XCTAssertEqual(guidance.target, .goal)
        // The goal is 7 cm toward +X, which is to the operator's left.
        assertClose(guidance.offset, SIMD3(-0.07, 0, 0.001))
    }

    func testOpenGripperOnTheCubeIsNotHoldingIt() {
        XCTAssertEqual(Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .open).target, .cube)
    }

    func testReadyToGraspOnlyWhenTheJawsAreAroundTheCubeAndOpen() {
        XCTAssertTrue(Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .open).readyToGrasp)
        XCTAssertTrue(Guidance.make(arm: graspPose + SIMD3(0.004, 0, 0.005), cube: cube, goal: goal, gripper: .open).readyToGrasp)
        XCTAssertFalse(Guidance.make(arm: graspPose + SIMD3(0.012, 0, 0), cube: cube, goal: goal, gripper: .open).readyToGrasp, "1.2 cm to the side")
        XCTAssertFalse(Guidance.make(arm: graspPose + SIMD3(0, 0, 0.02), cube: cube, goal: goal, gripper: .open).readyToGrasp, "2 cm too high")
        XCTAssertFalse(Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .closed).readyToGrasp, "already closed")
        XCTAssertFalse(Guidance.make(arm: arm, cube: cube, goal: goal, gripper: .open).readyToGrasp, "the start pose")
    }

    func testAfterATiltTheGuideNeverSaysReadyToGrasp() {
        XCTAssertTrue(Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .open).readyToGrasp)
        let tilted = Guidance.make(arm: graspPose, cube: cube, goal: goal, gripper: .open, wristTilted: true)
        XCTAssertFalse(tilted.readyToGrasp)
        XCTAssertTrue(tilted.wristTilted)
        XCTAssertEqual(tilted.target, .cube)
    }

    func testAnotherRobotProfileMovesTheToolPoint() {
        // A gripper that pinches straight below the reported point, on a robot sitting on the world origin.
        let straightDown = RobotProfile(name: "test", toolOffset: SIMD3(0, 0, -0.10), baseInWorld: .zero)
        let above = SIMD3<Float>(cube.x, cube.y, cube.z + 0.10)
        let guidance = Guidance.make(arm: above, cube: cube, goal: goal, gripper: .open, profile: straightDown)
        XCTAssertLessThan(simd_length(guidance.offset), 0.001)
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
    /// The reported point that puts the jaws on the cube.
    private let graspPose = SIMD3<Float>(-0.002, -0.164, 0.1405)

    private func guidance(arm: SIMD3<Float>? = nil, gripper: GripperState = .open) -> Guidance {
        Guidance.make(arm: arm ?? self.arm, cube: cube, goal: goal, gripper: gripper)
    }

    private func layout(arm: SIMD3<Float>? = nil, gripper: GripperState = .open) -> MiniMapLayout {
        MiniMapLayout(guidance(arm: arm, gripper: gripper))
    }

    func testFromTheStartTheCubeIsDrawnRightOfAndAheadOfTheJaws() {
        let map = layout()
        let jaws = map.top(map.arm), red = map.top(map.cube)
        // The cube is 2.3 cm to the operator's right and 2.3 cm ahead: right of and above the ring.
        XCTAssertGreaterThan(red.x, jaws.x)
        XCTAssertLessThan(red.y, jaws.y)
        XCTAssertLessThan(simd_distance(red, jaws), 0.27 * map.width, "they are close together from the start")
    }

    func testGoalIsDrawnToTheLeftOfTheCube() {
        let map = layout()
        XCTAssertLessThan(map.top(map.goal).x, map.top(map.cube).x)
        XCTAssertEqual(map.top(map.goal).y, map.top(map.cube).y, accuracy: 0.5)
    }

    func testEverythingStaysInsideTheTopViewWithRoomToSpare() {
        for arm in [self.arm, SIMD3<Float>(-0.06, -0.06, 0.24), SIMD3<Float>(0.10, -0.22, 0.08)] {
            let map = layout(arm: arm)
            let room = map.length(MiniMapLayout.margin) - 0.5
            for place in [map.arm, map.cube, map.goal] {
                let point = map.top(place)
                XCTAssertGreaterThanOrEqual(point.x, room)
                XCTAssertLessThanOrEqual(point.x, map.width - room)
                XCTAssertGreaterThanOrEqual(point.y, room)
                XCTAssertLessThanOrEqual(point.y, map.topHeight - room)
            }
        }
    }

    func testMovingTheGripperForwardMovesTheRingUpTheMap() {
        let before = layout(), after = layout(arm: arm + SIMD3(0, -0.02, 0))
        // Same zoom, because the cube and goal still bound the picture.
        XCTAssertEqual(before.scale, after.scale, accuracy: 0.0001)
        XCTAssertLessThan(after.top(after.arm).y, before.top(before.arm).y)
    }

    func testHeldCubeTravelsWithTheGripperInBothViews() {
        // Closed, with the jaws within the holding radius of where the server last saw the cube.
        let map = layout(arm: SIMD3(cube.x + 0.013, -0.164, 0.17), gripper: .closed)
        XCTAssertEqual(map.cube.x, map.arm.x)
        XCTAssertEqual(map.cube.y, map.arm.y)
        XCTAssertEqual(map.sideCube.centre.y, map.ring.y, "the cube is in the jaws, not on the table")
    }

    func testSmallSceneIsNotBlownUp() {
        let near = MiniMapLayout(Guidance.make(arm: cube + SIMD3(0.01, 0.036, 0.05), cube: cube, goal: cube + SIMD3(0.03, 0, 0), gripper: .open))
        XCTAssertEqual(near.scale, near.width / MiniMapLayout.minimumSpan, accuracy: 0.01)
    }

    // MARK: The two views line up

    func testAThingIsAtTheSameLeftRightPositionInBothViews() {
        for arm in [self.arm, graspPose, SIMD3<Float>(-0.06, -0.06, 0.24), SIMD3<Float>(0.10, -0.22, 0.08)] {
            for gripper in [GripperState.open, .closed] {
                let map = layout(arm: arm, gripper: gripper)
                XCTAssertEqual(map.ring.x, map.top(map.arm).x, accuracy: 0.001)
                XCTAssertEqual(map.sideCube.centre.x, map.top(map.cube).x, accuracy: 0.001)
                let goal = map.sideGoal
                XCTAssertEqual((goal.minX + goal.maxX) / 2, map.top(map.goal).x, accuracy: 0.001)
            }
        }
    }

    func testBothViewsDrawTheSameThingAtTheSameSize() {
        let map = layout()
        // The goal is 5 cm wide in both, the cube 2.5 cm.
        let goal = map.sideGoal
        XCTAssertEqual(goal.maxX - goal.minX, map.length(MiniMapLayout.goalSize), accuracy: 0.001)
        XCTAssertEqual(map.sideCube.edge, map.length(0.025), accuracy: 0.001)
        XCTAssertEqual(map.top(SIMD3(map.cube.x + 0.01, map.cube.y, 0)).x - map.top(map.cube).x, 0.01 * map.scale, accuracy: 0.001)
        // One centimetre up is the same number of points as one centimetre across.
        XCTAssertEqual(map.sideY(0) - map.sideY(0.01), map.x(0.01) - map.x(0), accuracy: 0.001)
    }

    // MARK: Height

    func testTheCubeSitsOnTheTableAndTheGoalLiesOnIt() {
        let map = layout()
        let cube = map.sideCube
        XCTAssertEqual(cube.centre.y + cube.edge / 2, map.tableY, accuracy: 0.001)
        XCTAssertEqual(map.sideGoal.y, map.tableY)
        XCTAssertLessThan(map.tableY, map.sideHeight)
    }

    func testTheRingIsDrawnAboveTheCubeWhenTheJawsAreHigh() {
        let map = layout()
        XCTAssertLessThan(map.ring.y, map.sideCube.centre.y)
        // 1.95 cm above the cube's centre, to scale.
        XCTAssertEqual(map.sideCube.centre.y - map.ring.y, 0.0195 * map.scale, accuracy: 0.3)
    }

    func testTheRingIsPinnedWhereTheJawsStillFitWhenFarAboveOrBelow() {
        let high = layout(arm: SIMD3(arm.x, arm.y, 0.5)), low = layout(arm: SIMD3(arm.x, arm.y, -0.2))
        XCTAssertEqual(high.ring.y, MiniMapLayout.jawRise + MiniMapLayout.pinInset)
        XCTAssertEqual(low.ring.y, low.sideHeight - MiniMapLayout.pinInset)
        for map in [high, low] {
            XCTAssertNotNil(map.heightGap)
            let line = map.gapLine!
            for y in [line.ringY, line.targetY] {
                XCTAssertGreaterThanOrEqual(y, 0)
                XCTAssertLessThanOrEqual(y, map.sideHeight)
            }
        }
        // The number stays the true one even though the ring cannot be drawn that high.
        XCTAssertEqual(high.heightGap!.centimetres, (0.5 - 0.088 - (0.1025 - 0.05)) * 100, accuracy: 0.01)
    }

    func testTheGapLabelSaysAboveBelowOrLevel() {
        let level = layout(arm: graspPose).heightGap!
        XCTAssertEqual(level.kind, .level)
        XCTAssertEqual(layout(arm: graspPose + SIMD3(0, 0, 0.007)).heightGap!.kind, .level, "inside the 8 mm tolerance")
        XCTAssertEqual(layout(arm: graspPose + SIMD3(0, 0, -0.007)).heightGap!.kind, .level)
        let above = layout(arm: graspPose + SIMD3(0, 0, 0.021)).heightGap!
        XCTAssertEqual(above.kind, .above)
        XCTAssertEqual(above.centimetres, 2.1, accuracy: 0.01)
        let below = layout(arm: graspPose + SIMD3(0, 0, -0.006 - 0.004)).heightGap!
        XCTAssertEqual(below.kind, .below)
        XCTAssertEqual(below.centimetres, 1.0, accuracy: 0.01)
        XCTAssertEqual(layout(arm: graspPose + SIMD3(0, 0, 0.009)).heightGap!.kind, .above)
    }

    func testTheGapLabelReadsInPlainWords() {
        let language = L10n.language
        defer { L10n.language = language }
        L10n.language = .en
        XCTAssertEqual(MiniMap.gapText(.init(kind: .above, centimetres: 2.1)), "2.1 cm above")
        XCTAssertEqual(MiniMap.gapText(.init(kind: .below, centimetres: 0.6)), "0.6 cm below")
        XCTAssertEqual(MiniMap.gapText(.init(kind: .level, centimetres: 0.2)), "level")
        L10n.language = .zhHant
        XCTAssertEqual(MiniMap.gapText(.init(kind: .above, centimetres: 2.1)), "高 2.1 公分")
        XCTAssertEqual(MiniMap.gapText(.init(kind: .below, centimetres: 0.6)), "低 0.6 公分")
        XCTAssertEqual(MiniMap.gapText(.init(kind: .level, centimetres: 0.2)), "等高")
    }

    func testWhileCarryingTheGapIsToTheGoalsRestingHeight() {
        // Holding the cube 3 cm higher than it rests, at a goal whose resting height is 0.1 mm above the cube's.
        let carrying = layout(arm: graspPose + SIMD3(0, 0, 0.03), gripper: .closed)
        XCTAssertTrue(carrying.carrying)
        XCTAssertEqual(carrying.targetZ, carrying.goal.z)
        let gap = carrying.heightGap!
        XCTAssertEqual(gap.kind, .above)
        XCTAssertEqual(gap.centimetres, (carrying.arm.z - carrying.goal.z) * 100, accuracy: 0.001)
        XCTAssertEqual(gap.centimetres, 2.9, accuracy: 0.05)
    }

    func testThereIsNoGapOnceTheCubeIsInTheGoal() {
        let placed = Guidance.make(arm: arm, cube: SIMD3(goal.x, goal.y, cube.z), goal: goal, gripper: .open)
        let map = MiniMapLayout(placed)
        XCTAssertEqual(placed.target, .done)
        XCTAssertNil(map.heightGap)
        XCTAssertNil(map.gapLine)
    }

    func testTheGapLineRunsBetweenTheRingAndTheCubeCentreAndItsLabelStaysInView() {
        for arm in [self.arm, graspPose + SIMD3(0.04, 0, 0.01), graspPose + SIMD3(-0.04, 0, -0.01), SIMD3<Float>(0.10, -0.22, 0.30)] {
            let map = layout(arm: arm)
            let line = map.gapLine!
            XCTAssertEqual(line.ringY, map.ring.y)
            XCTAssertEqual(line.targetY, map.sideCube.centre.y, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(line.label.x - MiniMapLayout.labelWidth / 2, 0)
            XCTAssertLessThanOrEqual(line.label.x + MiniMapLayout.labelWidth / 2, map.width)
            XCTAssertGreaterThanOrEqual(line.label.y - MiniMapLayout.labelHeight / 2, 0)
            XCTAssertLessThanOrEqual(line.label.y + MiniMapLayout.labelHeight / 2, map.sideHeight)
            XCTAssertGreaterThanOrEqual(line.x, 0)
            XCTAssertLessThanOrEqual(line.x, map.width)
        }
    }

    // MARK: The robot base

    func testTheBaseMarkerIsPinnedToTheNearestEdgeWhenOffTheMap() {
        // The base is at the operator's origin; the cube is 20 cm ahead of it, so it is behind the map: bottom edge.
        let map = layout()
        let base = map.base
        XCTAssertEqual(base.y, map.topHeight - MiniMapLayout.pinInset)
        XCTAssertEqual(base.x, min(max(map.top(.zero).x, MiniMapLayout.pinInset), map.width - MiniMapLayout.pinInset), accuracy: 0.001)
        XCTAssertGreaterThan(map.top(.zero).y, map.topHeight, "it is off the map before pinning")
    }

    func testTheBaseMarkerIsAtTheRealPlaceWhenItIsOnTheMap() {
        // Cube, goal and jaws all near the base.
        let near = Guidance.make(arm: SIMD3(0.0, 0.0, 0.2), cube: SIMD3(0.01, -0.02, 0.1), goal: SIMD3(0.05, -0.02, 0.1), gripper: .open)
        let map = MiniMapLayout(near)
        let real = map.top(.zero)
        XCTAssertEqual(map.base.x, real.x, accuracy: 0.001)
        XCTAssertEqual(map.base.y, real.y, accuracy: 0.001)
    }

    func testTheBaseMarkerIsPinnedOnTheSideItIsOn() {
        // Everything far to the operator's right of the base: the base is off the left edge.
        let right = Guidance.make(arm: SIMD3(-0.25, -0.02, 0.2), cube: SIMD3(-0.26, -0.04, 0.1), goal: SIMD3(-0.30, -0.03, 0.1), gripper: .open)
        let map = MiniMapLayout(right)
        XCTAssertEqual(map.base.x, MiniMapLayout.pinInset)
        // x = 0.25 in the operator's frame is to the right of the base, so the base is to the left.
        XCTAssertLessThan(map.top(.zero).x, 0)
    }
}

/// How the phone is held is read a few times a second. Changes are not buzzed: the six event patterns are the
/// only haptics. A translation pressed while the phone is held wrong is refused and says why.
final class PostureHapticsTests: XCTestCase {
    private var camera: simd_float4x4? = TestPose.portrait
    private var spy: SpyHaptics!
    private var model: AppModel!

    private var savedLanguage = L10n.language

    override func setUp() {
        camera = TestPose.portrait
        spy = SpyHaptics()
        model = AppModel(start: .p4, haptics: spy, pose: { [unowned self] in camera }, liveLink: false)
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    private var sideways: simd_float4x4 { TestPose.portrait(turned: 90, about: SIMD3(0, 0, 1)) }

    func testFirstReadingIsSilent() {
        model.refreshPosture()
        XCTAssertEqual(model.posture, .upright)
        XCTAssertEqual(spy.felt, [])
    }

    func testPostureChangesAreReadButNotBuzzed() {
        model.refreshPosture()
        camera = sideways
        model.refreshPosture()
        XCTAssertEqual(model.posture, .tilted)
        camera = TestPose.portrait
        model.refreshPosture()
        XCTAssertEqual(model.posture, .upright)
        XCTAssertEqual(spy.felt, [], "a posture buzz would read as GO or GRIP")
    }

    func testLosingAndRegainingTrackingIsSilent() {
        model.refreshPosture()
        camera = nil
        model.refreshPosture()
        XCTAssertEqual(model.posture, .unknown)
        camera = TestPose.portrait
        model.refreshPosture()
        XCTAssertEqual(spy.felt, [])
    }

    func testATranslationWithThePhoneHeldSidewaysIsRefused() {
        let speech = SpySpeech()
        let live = AppModel(
            start: .p4, haptics: spy, speech: speech, pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: { _ in SilentTransport() }
        )
        live.session.state.markConnected()
        camera = sideways
        live.send(.holdArmStart)
        XCTAssertFalse(live.session.state.armMoving)
        XCTAssertEqual(spy.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["Hold the phone upright."])
    }
}

/// A socket that is never answered.
final class SilentTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    func open() {}
    func send(_ text: String) {}
    func close() {}
}
