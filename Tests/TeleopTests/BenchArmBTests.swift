import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// Bench arm B is a deliberately different arm, given to the app only as a profile file and to the in-app server as a
/// configuration of the same model. The scripted hand that does the SO-101's pick and place does B's, with no line that
/// asks which arm it is.
final class BenchArmBTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!
    private var savedTaskAid: Any?

    override func tearDown() {
        hand?.finish()
        if hand != nil, let server {
            XCTAssertTrue(server.waitForTheAppsSocketsToClose(), "the server still holds \(server.openSockets) sockets")
        }
        hand = nil
        server?.stop()
        server = nil
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
    }

    // MARK: The file and the model

    /// B differs from the SO-101 in every group of the profile, so a rule that read the SO-101's number for any of them
    /// would give another answer.
    func testBDiffersFromTheSO101WhereTheInventoryFoundAnAssumption() {
        let so = TestProfiles.so101, b = TestProfiles.benchB
        XCTAssertNotEqual(b.frames.forward, so.frames.forward)
        XCTAssertEqual(b.frames.forward, SignedAxis(.x, 1), "forward is base +x")
        XCTAssertEqual(b.frames.up, SignedAxis(.z, -1), "base z points down")
        XCTAssertEqual(b.frames.linkSigns, SIMD3(1, 1, 1), "the link frame has no z flip")
        XCTAssertNotEqual(b.frames.worldTurn, so.frames.worldTurn, "world to base is turned")
        XCTAssertEqual(b.gripper.unit, .mm)
        XCTAssertEqual([b.gripper.closedReading, b.gripper.openReading], [0, 40], "parallel jaws read 0 to 40 mm")
        XCTAssertLessThan(b.wrist.rollWindowDeg, so.wrist.rollWindowDeg, "a narrower turn")
        XCTAssertGreaterThan(b.wrist.tiltWindowDeg, so.wrist.tiltWindowDeg, "and a wider tilt")
        XCTAssertEqual(b.motion.fineMps, so.motion.fineMps * 2, "doubled button speeds")
        XCTAssertEqual(b.motion.coarseMps, so.motion.coarseMps * 2)
        XCTAssertEqual(b.server.stopDistanceM, 0.06, "a 6 cm stop distance")
        XCTAssertEqual(b.server.stallDetection, .none)
        XCTAssertEqual(BenchArmB.stepsPerSecond, 8, "the model steps 8 times a second")
    }

    /// The numbers the package tests use for B's wrist, jaw, motion and server are the file's.
    func testTheFileCarriesTheNumbersThePackageTestsUseForB() {
        let b = TestProfiles.benchB
        XCTAssertEqual(
            b.wrist,
            WristProfile(
                rollSign: -1, tiltSign: 1, rollWindowDeg: 90, tiltWindowDeg: 45, rollClampDeg: 40, tiltClampDeg: 30,
                tiltCentre: .fixed(15), turnRateDegS: 40, tiltRateDegS: 20,
                lead: WristLeadLimits(leadDeg: 3, rateMaxDegS: 20, memoryDeg: 1, freshStateMs: 300)))
        XCTAssertEqual(
            b.gripper,
            GripperProfile(
                unit: .mm, closedReading: 0, openReading: 40, validMin: 0, validMax: 45, fullyOpenAt: 39, emptyAt: 1))
        XCTAssertEqual(
            b.motion, MotionProfile(fineMps: 0.02, coarseMps: 0.08, maxLeadM: 0.05, toolMaxLeadM: 0.004))
        XCTAssertEqual(
            b.server,
            ServerProfile(
                stopDistanceM: 0.06, resync: ResyncTimes(afterMs: 1200, toolAfterMs: 400, timeoutMs: 1000),
                heldObjectPoint: .toolPoint, stallDetection: .none))
        XCTAssertEqual(
            b.frames,
            Frames(
                forward: SignedAxis(.x, 1), left: SignedAxis(.y, -1), up: SignedAxis(.z, -1),
                linkSigns: SIMD3(1, 1, 1), baseInWorld: SIMD3(0.10, -0.20, 0.40),
                worldTurn: WorldTurn(x: SignedAxis(.y, 1), y: SignedAxis(.x, 1), z: SignedAxis(.z, -1))))
    }

    /// The model and the profile describe one arm and one scene: what the app computes from the profile (where the
    /// jaws pinch, the table, the work box) is where the model puts them.
    func testTheModelAndTheProfileDescribeTheSameArm() throws {
        let model = try BenchArmB.config()
        let profile = TestProfiles.benchB
        XCTAssertEqual(SIMD3<Float>(model.toolOffset), profile.toolOffset)
        XCTAssertEqual(model.baseInWorld, profile.frames.baseInWorld)
        XCTAssertEqual(model.linkSigns, profile.frames.linkSigns)
        XCTAssertEqual(
            [model.baseXInWorld, model.baseYInWorld, model.baseZInWorld],
            [profile.frames.worldTurn.x.vector, profile.frames.worldTurn.y.vector, profile.frames.worldTurn.z.vector])
        XCTAssertEqual(Float(model.graspToleranceAcross), profile.graspTolerance.x)
        XCTAssertEqual(Float(model.graspToleranceHeight), profile.graspTolerance.y)
        XCTAssertEqual(Float(model.cubeSize), profile.targetSize)
        XCTAssertEqual(Float(model.goalHalfExtents.x * 2), profile.goalSize)
        XCTAssertEqual(model.trackingSafetyDistance, Double(profile.server.stopDistanceM), "the stop distance")
        XCTAssertEqual(model.stepsPerSecond, 8)
        // The table: its height over the base origin along up is the profile's.
        let tableInBase = model.baseFromWorld(SIMD3(0, 0, model.tableTopWorld))
        XCTAssertEqual(Float(model.height(of: tableInBase)), profile.tableHeight, accuracy: 1e-5)
        XCTAssertEqual(model.up.index, 2)
        XCTAssertEqual(model.up.sign, -1, "up is base -z")
        // The work box the model keeps the arm in, moved by the pinch offset, is the profile's.
        let box = (
            low: model.armStart - SIMD3(repeating: model.workspaceHalfSize) + model.toolOffset,
            high: model.armStart + SIMD3(repeating: model.workspaceHalfSize) + model.toolOffset
        )
        for axis in 0..<3 {
            XCTAssertEqual(Float(box.low[axis]), profile.workspaceMin[axis], accuracy: 1e-5, "box low \(axis)")
            XCTAssertEqual(Float(box.high[axis]), profile.workspaceMax[axis], accuracy: 1e-5, "box high \(axis)")
        }
        // The jaw is a linear one: it reads the gap, shut on the object it reads the object's width.
        XCTAssertEqual(model.jawAngleOnCube, 25, accuracy: 1e-6)
        XCTAssertEqual(model.jawLimits, 0...40)
        XCTAssertEqual(model.wristFlexStart, profile.offsetMeasuredFlexDeg)
        // The object rests on the table, inside the table's extent, and the goal is a box on it.
        XCTAssertEqual(model.cubeStartWorld.z, model.tableTopWorld + model.cubeSize / 2, accuracy: 1e-9)
        XCTAssertTrue(model.goalHalfExtents.z > abs(model.goalWorld.z - model.cubeStartWorld.z))
        XCTAssertTrue(
            model.faults().isEmpty, "the model refuses its own configuration: \(model.faults().joined(separator: " "))")
    }

    /// The model cannot stand in for a profile whose jaw is not read in millimetres or whose work box is not the same
    /// distance every way from its middle.
    func testTheModelRefusesWhatItCannotStandInFor() {
        var degrees = TestProfiles.benchB
        degrees.gripper = TestProfiles.so101.gripper
        XCTAssertThrowsError(try BenchArmB.config(for: degrees))
        var uneven = TestProfiles.benchB
        uneven.workspaceMax.z += 0.01
        XCTAssertThrowsError(try BenchArmB.config(for: uneven))
    }

    // MARK: The whole task

    private func start(_ mode: ControlMode, toolPoint: Bool = true) throws {
        // B's server steps 8 times a second, a real eighth of a second each, so the script's waits for the arm and the
        // server stay at the SO-101's local pace.
        server = LocalTeleopServer(config: try BenchArmB.config(reportsToolPoint: toolPoint))
        try server.start()
        hand = ScriptedOperator(
            address: server.address, mode: mode, smoothing: 0.3, pace: 0.3, profile: TestProfiles.benchB)
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
        hand.model.taskAid = true
        XCTAssertTrue(hand.connect(within: TestWaits.linkUp), "could not connect to the local server")
        _ = try XCTUnwrap(hand.model.link.objectPosition, "the local server reported no task object")
        _ = try XCTUnwrap(hand.model.link.goalPosition, "the local server reported no goal")
        _ = try XCTUnwrap(hand.model.link.armPosition, "the local server reported no arm position")
    }

    /// The same script the SO-101 runs, on B: the whole pick and place, passing on the server model's own
    /// `task_success`.
    private func pickAndPlace(_ mode: ControlMode, toolPoint: Bool = true) throws {
        try start(mode, toolPoint: toolPoint)
        let model = hand.model!
        var reported = false, estimated = false
        var onTargetBeforeTheClose = false
        hand.watch = {
            guard let arm = model.operating.arm else { return }
            switch arm.pinchSource {
            case .reported: reported = true
            case .estimated: estimated = true
            }
            if !arm.gripping, model.session.state.gripperMoving != .closed,
                GuidePicture(reading: arm, profile: model.profile).onTarget
            {
                onTargetBeforeTheClose = true
            }
        }
        try hand.pickAndPlace(warmUpHolds: 0)
        hand.watch = nil
        XCTAssertTrue(hand.successSeen, "\(mode): the server never said task_success after the jaws let go")
        XCTAssertEqual(server.inspect { $0.episode }, 1, "\(mode): the scene reset once, after the success")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false, "\(mode)")
        XCTAssertEqual(reported, toolPoint, "\(mode)")
        XCTAssertEqual(estimated, !toolPoint, "\(mode)")
        XCTAssertTrue(onTargetBeforeTheClose, "\(mode): the guide never said On target at the grasp")
    }

    func testBenchArmBDoesThePickAndPlaceWithScreenTurns() throws {
        try pickAndPlace(.screenTurns)
    }

    func testBenchArmBDoesThePickAndPlaceWithKeyTurns() throws {
        try pickAndPlace(.keyTurns)
    }

    func testBenchArmBDoesThePickAndPlaceWithButtons() throws {
        try pickAndPlace(.buttons)
    }

    /// A server that reports no tool point: the guide's pinch point is the profile's offset from the reported one.
    func testBenchArmBDoesThePickAndPlaceWithScreenTurnsAndNoToolPoint() throws {
        try pickAndPlace(.screenTurns, toolPoint: false)
    }

    func testBenchArmBDoesThePickAndPlaceWithKeyTurnsAndNoToolPoint() throws {
        try pickAndPlace(.keyTurns, toolPoint: false)
    }

    func testBenchArmBDoesThePickAndPlaceWithButtonsAndNoToolPoint() throws {
        try pickAndPlace(.buttons, toolPoint: false)
    }
}
