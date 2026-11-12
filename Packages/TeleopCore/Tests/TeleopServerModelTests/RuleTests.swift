import XCTest
@testable import TeleopServerModel

/// The server rules that have bitten the app before, each checked against the model on a clock the test moves.
final class RuleTests: XCTestCase {
    private var bench: Bench!
    private var phone: Bench.Client!

    override func setUp() {
        bench = Bench()
        phone = bench.client()
        bench.wait(0.5)
    }

    // MARK: One command at a time

    func testAStartWhileAnotherCommandRunsIsRefusedBusy() {
        let hold = phone.poseStart()
        bench.wait(0.2)
        phone.poseUpdate(base: .zero)
        let gripper = phone.send("gripper_jog_start", .object(["action": "open", "step": "coarse"]))
        let reset = phone.send("reset_scene")
        XCTAssertEqual(phone.reason(gripper), "rejected busy")
        XCTAssertEqual(phone.reason(reset), "rejected busy")
        XCTAssertNil(phone.ack(hold), "the running hold was disturbed")
    }

    func testAStopIsAckedAtOnceAndItsStartOnlyWhenTheHoldHasFinished() {
        let hold = phone.poseStart()
        phone.stream(for: 0.5) { phone.poseUpdate(base: SIMD3(0, 0, 0.01)) }
        let stoppedAt = bench.now
        let stop = phone.send("pose_stop")
        let tooSoon = phone.send("gripper_jog_start", .object(["action": "open", "step": "coarse"]))
        XCTAssertEqual(phone.reason(stop), "ok pose_stop_requested")
        XCTAssertEqual(phone.ack(stop)?.time, stoppedAt, "a stop is acked at once")
        XCTAssertEqual(phone.reason(tooSoon), "rejected busy", "the stopped hold has not finished yet")
        XCTAssertNil(phone.ack(hold))
        bench.wait(bench.stepTime + 0.001)
        let finished = phone.ack(hold)
        XCTAssertEqual(finished.map { "\($0.status) \($0.reason)" }, "ok pose_stopped")
        XCTAssertLessThanOrEqual((finished?.time ?? 99) - stoppedAt, bench.stepTime + 1e-9, "about one step after the stop")
        let next = phone.send("gripper_jog_start", .object(["action": "open", "step": "coarse"]))
        bench.wait(0.1)
        XCTAssertNil(phone.ack(next), "after the final ack a new start is taken")
        XCTAssertEqual(bench.model.state["ik"], "gripper_jogging")
    }

    // MARK: Quiet while the client sends

    func testNoStateAndNoAckWhileTheClientKeepsSending() {
        bench.wait(1)
        let quietFrom = bench.now
        phone.poseStart()
        phone.stream(for: 3) { phone.poseUpdate(base: SIMD3(0.02, 0, 0)) }
        XCTAssertEqual(phone.received(after: quietFrom).map(\.type), [], "the server must say nothing during a hold")
        let lastUpdate = bench.now - 1.0 / 30
        bench.wait(0.45)
        let after = phone.received(after: lastUpdate)
        XCTAssertEqual(after.map(\.type), ["state", "state"], "states every 200 ms once the client is quiet")
        XCTAssertEqual(after.first?.time ?? 0, lastUpdate + 0.2, accuracy: 1e-9)
    }

    func testKeepalivesEvery150MsAlsoKeepTheServerQuiet() {
        let from = bench.now
        let jog = phone.gripperJog("open", seconds: 3, release: false)
        XCTAssertEqual(phone.received(after: from).map(\.type), [])
        XCTAssertNil(phone.ack(jog), "keepalives keep a gripper jog alive")
    }

    func testIdleStatesComeFiveTimesASecond() {
        let from = bench.now
        bench.wait(2.0)
        XCTAssertEqual(phone.received(after: from).filter { $0.type == "state" }.count, 10)
    }

    // MARK: Watchdog

    func testAHoldEnds750MsAfterItsLastUpdateWithoutAnEmergencyStop() {
        let hold = phone.poseStart()
        phone.stream(for: 0.5) { phone.poseUpdate(base: .zero) }
        let lastUpdate = bench.now - 1.0 / 30
        bench.wait(0.7)
        XCTAssertNil(phone.ack(hold), "too early for the watchdog")
        bench.wait(0.2)
        let ack = phone.ack(hold)
        XCTAssertEqual(ack.map { "\($0.status) \($0.reason)" }, "rejected pose_watchdog_timeout")
        XCTAssertGreaterThan(ack?.time ?? 0, lastUpdate + 0.75)
        XCTAssertLessThanOrEqual(ack?.time ?? 99, lastUpdate + 0.75 + bench.stepTime)
        XCTAssertEqual(phone.lastState["estop"], false)
        XCTAssertEqual(phone.lastState["ik"], "stopped")
    }

    func testAKeepaliveDoesNotKeepAPoseHoldAlive() {
        let hold = phone.poseStart()
        phone.stream(for: 1.5, every: 0.15) { phone.send("jog_keepalive") }
        XCTAssertEqual(phone.reason(hold), "rejected pose_watchdog_timeout")
    }

    func testAGripperJogWithoutKeepalivesEndsByWatchdog() {
        let jog = phone.send("gripper_jog_start", .object(["action": "open", "step": "coarse"]))
        bench.wait(1.0)
        XCTAssertEqual(phone.reason(jog), "rejected gripper_jog_watchdog_timeout")
    }

    // MARK: Emergency stop

    func testAnEmergencyStopEndsTheHoldAndRefusesEverythingUntilReset() {
        let hold = phone.poseStart()
        phone.stream(for: 0.5) { phone.poseUpdate(base: .zero) }
        let estopAt = bench.now
        let estop = phone.send("estop")
        XCTAssertEqual(phone.reason(estop), "ok estop_engaged")
        XCTAssertEqual(phone.ack(estop)?.time, estopAt)
        let tooSoon = phone.send("estop_reset")
        XCTAssertEqual(phone.reason(tooSoon), "rejected estop_not_frozen", "the loop has not held the arm yet")
        bench.wait(bench.stepTime + 0.001)
        XCTAssertEqual(phone.reason(hold), "rejected estop")
        let start = phone.poseStart()
        let keepalive = phone.send("jog_keepalive")
        let stop = phone.send("pose_stop")
        let mode = phone.send("mode", .object(["step": "fine"]))
        XCTAssertEqual(phone.reason(start), "rejected estop_active")
        XCTAssertEqual(phone.reason(keepalive), "rejected estop_active")
        XCTAssertEqual(phone.reason(stop), "rejected estop_active")
        XCTAssertEqual(phone.reason(mode), "ok mode_updated", "mode is still accepted")
        let reset = phone.send("estop_reset")
        XCTAssertEqual(phone.reason(reset), "ok estop_reset")
        let again = phone.poseStart()
        bench.wait(0.2)
        XCTAssertNil(phone.ack(again), "accepted after estop_reset")
    }

    func testAnEmergencyStopThatCatchesAStartStillQueuedIsAnsweredFirst() {
        let before = phone.received.count
        // Both in the same instant, before the loop has taken the start off the queue.
        let start = phone.poseStart()
        let estop = phone.send("estop")
        let answers = phone.received.dropFirst(before).map { "\($0.type) \($0.message["seq"]?.intValue ?? -1)" }
        XCTAssertEqual(answers, ["ack \(estop)", "state \(estop)", "ack \(start)", "state \(start)"])
        XCTAssertEqual(phone.reason(estop), "ok estop_engaged")
        XCTAssertEqual(phone.reason(start), "rejected estop")
        XCTAssertEqual(phone.stateWithAck(start)?["estop"], true)
    }

    func testResetSceneClearsAnEmergencyStop() {
        phone.send("estop")
        bench.wait(0.5)
        let episode = phone.lastState["episode"]?.intValue ?? -1
        let reset = phone.send("reset_scene")
        bench.wait(3)
        XCTAssertEqual(phone.reason(reset), "ok scene_reset")
        XCTAssertEqual(phone.lastState["estop"], false)
        XCTAssertEqual(phone.lastState["episode"]?.intValue, episode + 1)
    }

    func testASocketThatClosesDuringAHoldEngagesTheEmergencyStop() {
        phone.poseStart()
        phone.stream(for: 0.3) { phone.poseUpdate(base: .zero) }
        phone.close()
        bench.wait(0.5)
        let next = bench.client()
        XCTAssertEqual(next.lastState["estop"], true)
    }

    func testAnIdleSocketClosingIsHarmless() {
        phone.close()
        bench.wait(0.5)
        XCTAssertEqual(bench.client().lastState["estop"], false)
    }

    func testAHoldBelongsToTheSocketThatStartedIt() {
        let other = bench.client()
        let hold = phone.poseStart()
        phone.stream(for: 0.3) { phone.poseUpdate(base: .zero) }
        let stop = other.send("pose_stop")
        XCTAssertEqual(other.reason(stop), "rejected pose_not_active")
        // The other socket's updates do not keep the hold alive.
        other.stream(for: 1.0) { other.poseUpdate(base: .zero) }
        XCTAssertEqual(phone.reason(hold), "rejected pose_watchdog_timeout")
        XCTAssertFalse(other.received.contains { $0.payload["reason"] == "pose_watchdog_timeout" },
                       "acks go only to the socket that sent the command")
    }

    // MARK: Reset behind a stop

    func testAResetWhileAStoppedHoldFinishesIsBusyAndTheStopStillLands() {
        let hold = phone.poseStart()
        phone.stream(for: 0.5) { phone.poseUpdate(base: SIMD3(0, 0, 0.01)) }
        phone.send("pose_stop")
        let reset = phone.send("reset_scene")
        XCTAssertEqual(phone.reason(reset), "rejected busy")
        bench.wait(bench.stepTime + 0.001)
        XCTAssertEqual(phone.reason(hold), "ok pose_stopped", "the reset must not swallow the stop")
    }

    // MARK: Workspace

    func testAPointOutsideTheWorkspaceIsClampedAndReported() {
        let start = bench.config.armStart
        let hold = phone.poseStart()
        phone.stream(for: 4) { phone.poseUpdate(base: SIMD3(0, 0, 0.30)) }
        phone.send("pose_stop")
        bench.wait(0.2)
        XCTAssertEqual(phone.reason(hold), "ok pose_stopped")
        XCTAssertEqual(phone.lastState["ik"], "pose_clamped")
        XCTAssertEqual(bench.model.world.arm.z, start.z + bench.config.workspaceHalfSize, accuracy: 1e-9)
    }

    func testACommandMoreThan10CmAheadOfTheArmEngagesTheEmergencyStop() {
        let half = bench.config.workspaceHalfSize
        // Into one corner of the workspace, then a hold that asks for the opposite corner at once. The commanded
        // point runs at 0.4 m/s and the arm follows at 2.5 mm a step, so the gap passes 10 cm.
        phone.moveArm(to: bench.config.armStart - SIMD3(repeating: half), seconds: 6)
        let hold = phone.poseStart()
        phone.stream(for: 3) { phone.poseUpdate(base: SIMD3(repeating: 2 * half)) }
        XCTAssertEqual(phone.reason(hold), "rejected pose_tracking_safety_stop")
        XCTAssertEqual(bench.model.state["estop"], true)
        // The link learns of an E-stop from state only, so the state that comes with the failure must show it.
        XCTAssertEqual(phone.stateWithAck(hold)?["estop"], true)
        XCTAssertEqual(phone.stateWithAck(hold)?["ik"], "stopped")
    }

    func testAMoveThatCannotReachItsTargetFailsAndEngagesTheEmergencyStop() {
        // Something under the jaws, as in recording s11, stops the arm 8 mm into a 2 cm move down.
        bench.model.world.obstacleUnderArm = bench.config.armStart.z - 0.008
        let move = phone.send("move_delta", .object(["axis": "z", "dir": -1, "step": "coarse", "frame": "base"]))
        bench.wait(12)
        XCTAssertEqual(phone.reason(move), "rejected position_tolerance_not_met")
        XCTAssertEqual(phone.stateWithAck(move)?["estop"], true)
        XCTAssertEqual(phone.stateWithAck(move)?["ik"], "stopped")
        XCTAssertEqual(phone.reason(phone.poseStart()), "rejected estop_active")
    }

    // MARK: The arm is slow

    func testTheArmMovesABoundedDistancePerStepAndStepsComeAtTheConfiguredPace() {
        let start = bench.model.world.arm
        let hold = phone.poseStart()
        phone.stream(for: 1.0) { phone.poseUpdate(base: SIMD3(0, -0.07, 0)) }
        let moved = length(bench.model.world.arm - start)
        let steps = 1.0 * bench.config.stepsPerSecond
        XCTAssertLessThanOrEqual(moved, (steps + 1) * bench.config.armStepInPose + 1e-9)
        XCTAssertGreaterThan(moved, (steps - 2) * bench.config.armStepInPose)
        XCTAssertNil(phone.ack(hold))
    }

    func testCarryingTheCubeIsSlower() {
        phone.carryCubeOntoGoal()
        XCTAssertEqual(phone.lastState["gripper"], "close")
        let start = bench.model.world.arm
        phone.poseStart()
        phone.stream(for: 0.5) { phone.poseUpdate(base: SIMD3(0, 0, 0.05)) }
        let steps = 0.5 * bench.config.stepsPerSecond + 1
        XCTAssertLessThanOrEqual(length(bench.model.world.arm - start), steps * bench.config.poseCarrySpeed * bench.config.simStep + 1e-9)
    }

    // MARK: Grasp
    // The app's guide (RobotProfile.so101Simulator) counts the jaws as around the cube when the pinch point is
    // within 6 mm of its centre across the table and 8 mm in height, with the jaws side by side.

    func testClosingTheJawsWithinTheToleranceTakesHold() {
        XCTAssertTrue(phone.closeJaws(offFromCube: SIMD3(0.004, -0.003, 0.006)))
    }

    func testClosingTheJawsBesideTheCubeTakesNoHold() {
        XCTAssertFalse(phone.closeJaws(offFromCube: SIMD3(0.010, 0, 0)), "1 cm to the side")
        XCTAssertFalse(phone.closeJaws(offFromCube: SIMD3(0, 0.025, 0)), "2.5 cm behind")
    }

    func testClosingTheJawsAboveTheCubeTakesNoHold() {
        XCTAssertFalse(phone.closeJaws(offFromCube: SIMD3(0, 0, 0.012)))
    }

    func testClosingTheJawsFrontToBackTakesNoHold() {
        bench.model.world.wristRoll = 0
        XCTAssertFalse(phone.closeJaws(offFromCube: .zero))
    }

    func testClosingTheJawsWithTheWristPitchedTakesNoHold() {
        bench.model.world.wristFlex = bench.config.wristFlexStart + 6
        XCTAssertFalse(phone.closeJaws(offFromCube: .zero))
    }

    // MARK: Success

    func testPuttingTheCubeInTheGoalWithTheGripperOpenSucceedsAndTheSceneResets() {
        phone.carryCubeOntoGoal()
        let episode = phone.lastState["episode"]?.intValue ?? -1
        let releasedAt = bench.now
        let open = phone.gripperJog("open", seconds: 3, release: false)
        let success = phone.ack(open)
        XCTAssertEqual(success.map { "\($0.status) \($0.reason)" }, "ok task_success", "the hold still pressed ends with the success")
        let steps = ((success?.time ?? 0) - releasedAt) * bench.config.stepsPerSecond
        // 30 resting steps, the server's --success-stable-steps default, written out so that a wrong constant in the
        // model fails. Before them come the pass that takes the jog and lets go and the pass where the cube lands,
        // and the jog was sent up to one pass before the first of those.
        XCTAssertGreaterThanOrEqual(steps, 31 - 1e-6, "the cube must rest in the goal for 30 steps")
        XCTAssertLessThanOrEqual(steps, 32 + 1e-6, "and success comes as soon as it has")
        XCTAssertEqual(bench.model.state["task_success"], true)
        XCTAssertEqual(bench.model.state["ik"], "task_success")
        let refused = phone.poseStart()
        XCTAssertEqual(phone.reason(refused), "rejected sim_not_ready", "commands are refused while the success shows")
        bench.wait(10)
        XCTAssertEqual(phone.lastState["task_success"], false)
        XCTAssertEqual(phone.lastState["episode"]?.intValue, episode + 1)
        XCTAssertEqual(bench.model.world.cube, bench.config.cubeStartWorld)
    }

    func testTheCubeInTheGoalIsNoSuccessWhileTheGripperIsReportedClosed() {
        phone.carryCubeOntoGoal()
        // A pose hold's gripper_delta under 0.02 opens the jaws 2 degrees, enough to let go of the cube, but the
        // gripper label stays "close". Success is judged on the label.
        phone.poseStart()
        phone.stream(for: 2) { phone.poseUpdate(base: .zero, gripperDelta: 0.02) }
        phone.send("pose_stop")
        bench.wait(3)
        XCTAssertFalse(bench.model.world.holdingCube)
        XCTAssertTrue(bench.model.world.cubeInGoal(bench.config))
        XCTAssertEqual(phone.lastState["gripper"], "close")
        XCTAssertEqual(phone.lastState["task_success"], false)
    }

    // MARK: State

    func testStateCarriesEveryFieldWithItsType() {
        let fields = Comparison.signature(phone.lastState)
        XCTAssertEqual(fields, [
            "ee_pos:array3", "episode:number", "estop:bool", "goal_pos:array3", "gripper:string", "gripper_deg:number",
            "ik:string", "object_pos:array3", "rec:string", "rec_discarded:number", "rec_samples:number",
            "rec_saved:number", "step:string", "task_success:bool", "tool_pos:array3", "wrist_flex_deg:number",
            "wrist_roll_deg:number",
        ])
        XCTAssertEqual(phone.lastState["rec"], "none", "a server started without recording")
        phone.moveArm(to: bench.config.armStart)
        XCTAssertTrue(Comparison.signature(phone.lastState).contains("orient_deg:number"), "a pose hold adds orient_deg")
        XCTAssertTrue(Comparison.signature(phone.lastState).contains("gripper_delta:number"))
    }

    /// `tool_pos` is the world's pinch point in every state that carries `ee_pos`, during a hold too; the switch
    /// leaves it out everywhere.
    func testTheToolPointGoesWithTheArmUnlessSwitchedOff() {
        let offset = bench.config.toolOffset
        func check(_ state: JSONValue, _ what: String) {
            let arm = state["ee_pos"]?.arrayValue?.compactMap(\.numberValue) ?? []
            let tool = state["tool_pos"]?.arrayValue?.compactMap(\.numberValue) ?? []
            XCTAssertEqual(arm.count, 3, what)
            XCTAssertEqual(tool.count, 3, what)
            for axis in 0..<min(arm.count, tool.count, 3) {
                XCTAssertEqual(tool[axis] - arm[axis], offset[axis], accuracy: 1e-12, "\(what), axis \(axis)")
            }
        }
        check(phone.lastState, "at the start")
        let listener = bench.client()
        phone.poseStart()
        phone.stream(for: 1) { phone.poseUpdate(base: SIMD3(0.02, 0, 0)) }
        check(listener.lastState, "heard during a hold")
        phone.send("pose_stop")
        bench.wait(0.5)
        check(phone.lastState, "after the hold")
        XCTAssertNotEqual(phone.lastState["ee_pos"], phone.states.first?.payload["ee_pos"], "the arm moved")

        var config = ServerModelConfig.s4Simulator
        config.reportsToolPoint = false
        let other = Bench(config)
        let client = other.client()
        other.wait(0.5)
        client.moveArm(to: config.armStart + SIMD3(0, 0, 0.01))
        XCTAssertFalse(client.states.isEmpty)
        for state in client.states {
            XCTAssertNotNil(state.payload["ee_pos"])
            XCTAssertNil(state.payload["tool_pos"])
        }
    }
}

/// The recorder, on a server started with recording.
final class RecorderTests: XCTestCase {
    private var bench: Bench!
    private var phone: Bench.Client!

    override func setUp() {
        bench = Bench(.s4Simulator(stepsPerSecond: 17, recorder: .init(savedAtStart: 4)))
        phone = bench.client()
        bench.wait(0.5)
    }

    private var rec: String? { bench.model.state["rec"]?.stringValue }
    private var samples: Int { bench.model.state["rec_samples"]?.intValue ?? -1 }
    private var saved: Int { bench.model.state["rec_saved"]?.intValue ?? -1 }
    private var discarded: Int { bench.model.state["rec_discarded"]?.intValue ?? -1 }

    func testATakeBeginsAtTheFirstCommandAndSamplesEverySecondStep() {
        bench.wait(2)
        XCTAssertEqual(rec, "armed")
        XCTAssertEqual(samples, 0, "idle time before the first command is not recorded")
        phone.poseStart()
        phone.stream(for: 1) { phone.poseUpdate(base: .zero) }
        XCTAssertEqual(rec, "capturing")
        XCTAssertEqual(Double(samples), bench.config.stepsPerSecond / 2, accuracy: 1.5)
        phone.send("pose_stop")
        bench.wait(1)
        XCTAssertEqual(Double(samples), bench.config.stepsPerSecond, accuracy: 2, "pauses after the first command are kept")
    }

    func testASuccessSavesTheTake() {
        phone.carryCubeOntoGoal()
        phone.gripperJog("open", seconds: 3, release: false)
        bench.wait(0.1)
        XCTAssertEqual(saved, 5)
        XCTAssertEqual(rec, "off", "nothing is recorded while the success shows")
        XCTAssertGreaterThan(samples, 0, "the saved take's length stays until the next reset")
        bench.wait(10)
        XCTAssertEqual(rec, "armed")
        XCTAssertEqual(samples, 0)
        XCTAssertEqual(discarded, 0)
    }

    func testAnEmergencyStopDiscardsTheTakeAndTheRecorderStaysOffUntilAReset() {
        phone.gripperJog("open", seconds: 1)
        XCTAssertEqual(rec, "capturing")
        phone.send("estop")
        bench.wait(0.5)
        XCTAssertEqual(rec, "off")
        XCTAssertEqual(discarded, 1)
        phone.send("estop_reset")
        phone.gripperJog("close", seconds: 1)
        XCTAssertEqual(rec, "off", "estop_reset does not arm the recorder again")
        phone.send("reset_scene")
        bench.wait(3)
        XCTAssertEqual(rec, "armed")
    }

    func testAResetDiscardsTheTake() {
        phone.gripperJog("open", seconds: 1)
        phone.send("reset_scene")
        bench.wait(3)
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(rec, "armed")
        XCTAssertEqual(saved, 4)
    }
}
