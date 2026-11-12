import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The pick-and-place done with each mode's own raw inputs (`ScriptedOperator`) through the app's model and link,
/// against the server model on a local socket. It runs in every default test run; `OperatorLiveTests` runs the same
/// scripts against the lab simulator.
final class LocalPickAndPlaceTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!
    private var savedTaskAid: Any?

    override func tearDown() {
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
    }

    /// - Parameter path: the network path under both of the app's sockets; none when nil.
    private func start(
        _ mode: ControlMode, recorder: ServerModelConfig.Recorder? = nil, toolPoint: Bool = true,
        path: StallingPath? = nil
    ) throws {
        // Three and a half times the lab server's pace, so the script's waits shrink by about as much.
        server = LocalTeleopServer(
            config: .s4Simulator(stepsPerSecond: 60, recorder: recorder, reportsToolPoint: toolPoint))
        try server.start()
        hand = ScriptedOperator(
            address: server.address, mode: mode, smoothing: 0.3, pace: 0.3, makeTransport: path.map { $0.transport })
        // The guide, and with it the on-target cue, shows only with the task aid on, its default.
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
        hand.model.taskAid = true
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
        // The script skips without these, which suits the live server; against the local one it is a failure.
        _ = try XCTUnwrap(hand.model.link.objectPosition, "the local server reported no task object")
        _ = try XCTUnwrap(hand.model.link.goalPosition, "the local server reported no goal")
        _ = try XCTUnwrap(hand.model.link.armPosition, "the local server reported no arm position")
    }

    private func finishedTheTask() {
        XCTAssertEqual(server.inspect { $0.episode }, 1, "the scene reset once, after the success")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false)
    }

    /// One scheme's script against a server that reports its tool point (`toolPoint`) or one that does not. Either way
    /// the guide's pinch point comes from where it should, and the guide says "On target" at the grasp before the
    /// jaws close: the script grasps where the profile's offset was measured, with the wrist untouched, where the
    /// estimate is exact. Elsewhere the estimate is approximate.
    ///
    /// ON TARGET is felt exactly once on the approach to the grasp, never while the jaws hold the object, and not when
    /// letting go on the goal leaves the open jaws on the object they carried there.
    private func pickAndPlace(_ mode: ControlMode, toolPoint: Bool) throws {
        try start(mode, toolPoint: toolPoint)
        let model = hand.model!
        var reported = false, estimated = false, approximate = false
        var onTargetBeforeTheClose = false
        var cuesSeen = 0, grasped = false
        var cuesBeforeTheGrasp: [CueLogEntry] = [], cuesWhileHolding = 0, cuesAfterTheRelease = 0
        hand.watch = {
            let cues = model.cueLog.filter { $0.event == .onTarget }
            let new = cues.dropFirst(cuesSeen)
            cuesSeen = cues.count
            if model.gripping { grasped = true }
            if !grasped {
                cuesBeforeTheGrasp += new
            } else if model.gripping {
                cuesWhileHolding += new.count
            } else {
                cuesAfterTheRelease += new.count
            }
            guard let arm = model.operating.arm else { return }
            switch arm.pinchSource {
            case .reported: reported = true
            case .estimated(let rough):
                estimated = true
                approximate = approximate || rough
            }
            if !arm.gripping, model.session.state.gripperMoving != .closed,
                GuidePicture(reading: arm, profile: model.profile).onTarget
            {
                onTargetBeforeTheClose = true
            }
        }
        try hand.pickAndPlace(warmUpHolds: 0)
        hand.watch = nil
        finishedTheTask()
        XCTAssertEqual(reported, toolPoint, "\(mode)")
        XCTAssertEqual(estimated, !toolPoint, "\(mode)")
        XCTAssertEqual(approximate, !toolPoint, "\(mode): the estimate is approximate away from the grasp")
        XCTAssertTrue(onTargetBeforeTheClose, "\(mode): the guide never said On target at the grasp")
        XCTAssertLessThan(model.cueLog.count, 200, "the cue log still holds the whole script")
        XCTAssertEqual(cuesBeforeTheGrasp.count, 1, "\(mode): ON TARGET once on the approach, \(cuesBeforeTheGrasp)")
        XCTAssertEqual(cuesBeforeTheGrasp.first?.dropped, false, "\(mode): and felt")
        XCTAssertEqual(cuesWhileHolding, 0, "\(mode)")
        XCTAssertEqual(cuesAfterTheRelease, 0, "\(mode): letting go of the carried object is no new approach")
        print(
            "ON TARGET (\(mode.rawValue), tool point \(toolPoint)): \(cuesBeforeTheGrasp.count) on the approach, "
                + "\(cuesAfterTheRelease) after letting go")
    }

    func testPickAndPlaceSchemeA() throws {
        try pickAndPlace(.screenTurns, toolPoint: true)
    }

    func testPickAndPlaceSchemeB() throws {
        try pickAndPlace(.keyTurns, toolPoint: true)
    }

    func testPickAndPlaceButtons() throws {
        try pickAndPlace(.buttons, toolPoint: true)
    }

    func testPickAndPlaceSchemeAWithNoToolPoint() throws {
        try pickAndPlace(.screenTurns, toolPoint: false)
    }

    func testPickAndPlaceSchemeBWithNoToolPoint() throws {
        try pickAndPlace(.keyTurns, toolPoint: false)
    }

    func testPickAndPlaceButtonsWithNoToolPoint() throws {
        try pickAndPlace(.buttons, toolPoint: false)
    }

    /// A link that goes down after the lift fails the run at that step. The script used to read a lost object position
    /// as the object back at its start, which it took for a scene reset after a success, and passed. The path is cut
    /// while the object is carried toward the goal, after the script has checked the lift, and never comes back.
    func testALinkCutAfterTheLiftFailsTheRun() throws {
        let path = StallingPath()
        try start(.screenTurns, path: path)
        let cubeStart = server.inspect { $0.world.cube }
        hand.watch = { [unowned self] in
            guard !path.stalled else { return }
            let cube = server.inspect { $0.world.cube }
            if cube.z > cubeStart.z + 0.015, cube.x > cubeStart.x + 0.01 { path.stall() }
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.compactDescription.contains("the link went down") }
        try XCTExpectFailure("the link is cut while the object is carried", options: options) {
            try hand.pickAndPlace(warmUpHolds: 0)
        }
        hand.watch = nil
        XCTAssertTrue(path.stalled, "the object was never carried, so the path was never cut")
        XCTAssertEqual(hand.linkLostDuring, "to the goal")
        XCTAssertEqual(server.inspect { $0.episode }, 0, "no success: the scene never reset")
    }

    /// What the operating screen draws follows the server in real use, not only in fixtures: through a whole
    /// pick-and-place with a recorder, the guide's arm reading is there with the target and the goal, its pinch point
    /// moves during a hold, the jaw opening changes, gripping turns true, and the saved and wait states come up.
    func testTheGuideFollowsTheServerThroughAPickAndPlace() throws {
        try start(.screenTurns, recorder: .init())
        let model = hand.model!
        let first = try XCTUnwrap(model.operating.arm, "no arm reading once connected")
        XCTAssertNotNil(first.target)
        XCTAssertNotNil(first.goal)
        XCTAssertFalse(first.gripping)

        var readings = 0, withoutTaskObjects = 0
        var pinchAtHoldStart: SIMD3<Float>?
        var movedDuringAHold: Float = 0
        var jaws: [Double] = []
        var gripping = false
        var saved = false, waited = false
        hand.watch = {
            if let arm = model.operating.arm {
                readings += 1
                if arm.target == nil || arm.goal == nil { withoutTaskObjects += 1 }
                if let opening = arm.jawOpening { jaws.append(opening) }
                gripping = gripping || arm.gripping
                if model.session.state.armMoving {
                    let start = pinchAtHoldStart ?? arm.pinchPoint
                    pinchAtHoldStart = start
                    movedDuringAHold = max(movedDuringAHold, simd_distance(start, arm.pinchPoint))
                } else {
                    pinchAtHoldStart = nil
                }
            }
            switch model.operating.state {
            case .saved: saved = true
            case .wait: waited = true
            default: break
            }
        }
        try hand.pickAndPlace(warmUpHolds: 0)
        hand.watch = nil
        finishedTheTask()

        XCTAssertGreaterThan(readings, 100)
        XCTAssertEqual(withoutTaskObjects, 0, "the target and the goal are always there")
        XCTAssertGreaterThan(
            movedDuringAHold, 0.01, "the pinch point moves during a hold, from the listening connection")
        XCTAssertGreaterThan((jaws.max() ?? 0) - (jaws.min() ?? 0), 0.5, "the jaw opening follows the jaws")
        XCTAssertTrue(gripping, "the guide says holding once the jaws grip")
        XCTAssertTrue(saved, "the saved take reaches the screen")
        XCTAssertTrue(waited, "the server's save and reset reach the screen as Wait")
    }
}

/// The script's own judgement of the server's report, without a server.
final class ScriptedOperatorGoalTests: XCTestCase {
    private let goal = SIMD3<Float>(0.075, -0.2, 0.1035)
    private let rest: Float = 0.1025

    private func inGoal(_ object: SIMD3<Float>) -> Bool {
        ScriptedOperator.restsInGoal(object, goal: goal, restingHeight: rest, halfWidth: 0.025)
    }

    /// Only an object resting in the goal counts: one still held above it, or beside it, does not.
    func testOnlyAnObjectRestingInTheGoalCounts() {
        XCTAssertTrue(inGoal(SIMD3(0.08, -0.21, rest)))
        XCTAssertFalse(inGoal(SIMD3(0.075, -0.2, rest + 0.03)), "held 3 cm above the goal")
        XCTAssertFalse(inGoal(SIMD3(0.105, -0.2, rest)), "3 cm beside the goal")
    }
}
