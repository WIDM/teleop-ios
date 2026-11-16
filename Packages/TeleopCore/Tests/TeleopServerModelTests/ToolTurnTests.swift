import XCTest
@testable import TeleopServerModel

/// The pinch point the model reports: by default the reported point plus the tool offset, exactly; with the turning
/// tool chosen, a point fixed to a gripper that tilts with the arm's posture, as the simulator's does, which the tool
/// point in `state`, the grasp and the jaw tips on the table all follow. A model can also stop reporting the tool point
/// during a run.
final class ToolTurnTests: XCTestCase {
    private func turning(_ turn: ServerModelConfig.ToolTurn = .s4Simulator) -> ServerModelConfig {
        var config = ServerModelConfig.s4Simulator
        config.toolTurn = turn
        return config
    }

    private func toolPoint(_ state: JSONValue) -> SIMD3<Double>? {
        guard let values = state["tool_pos"]?.arrayValue?.compactMap(\.numberValue), values.count == 3 else {
            return nil
        }
        return SIMD3(values[0], values[1], values[2])
    }

    func testByDefaultThePinchPointIsTheReportedPointPlusTheToolOffset() {
        let bench = Bench()
        XCTAssertNil(bench.config.toolTurn)
        let phone = bench.client()
        bench.wait(0.5)
        phone.moveArm(to: bench.config.armStart + SIMD3(0.03, -0.02, -0.04))
        let arm = bench.model.world.arm
        XCTAssertNotEqual(arm, bench.config.armStart, "the arm moved")
        XCTAssertEqual(bench.model.world.pinch(bench.config), arm + bench.config.toolOffset)
        XCTAssertEqual(toolPoint(bench.model.state), arm + bench.config.toolOffset)
    }

    /// At the reset pose the turning pinch point is the tool point the simulator reports there.
    func testTheTurningPinchPointAtTheResetPoseIsTheMeasuredOne() throws {
        let bench = Bench(turning())
        let reported = try XCTUnwrap(toolPoint(bench.model.state))
        XCTAssertLessThan(length(reported - SIMD3(0.0332, -0.2024, 0.0878)), 0.0003, "\(reported)")
        XCTAssertEqual(reported, ServerModelConfig.ToolTurn.s4Simulator.pinch(bench.config.armStart))
    }

    /// For a small move of the reported point from the reset pose, the pinch point goes about a quarter as far
    /// outward from the pan axis, 1.6 times as far in height and 1.5 times as far sideways.
    func testTheTurningPinchPointsGainsAtTheResetPose() {
        let turn = ServerModelConfig.ToolTurn.s4Simulator
        let arm = ServerModelConfig.s4Simulator.armStart
        let out = SIMD2(arm.x, arm.y) - turn.panAxis
        let away2 = out / (out * out).sum().squareRoot()
        let away = SIMD3(away2.x, away2.y, 0), side = SIMD3(-away2.y, away2.x, 0), up = SIMD3<Double>(0, 0, 1)
        let h = 1e-5
        func gain(_ move: SIMD3<Double>) -> Double { ((turn.pinch(arm + move * h) - turn.pinch(arm)) * move).sum() / h }
        XCTAssertEqual(gain(away), 0.26, accuracy: 0.01, "outward")
        XCTAssertEqual(gain(up), 1.61, accuracy: 0.01, "in height")
        XCTAssertEqual(gain(side), 1.51, accuracy: 0.01, "sideways")
    }

    /// Pushed down into the table, the arm stops where the turning pinch point's jaw tips meet it, and `state` reports
    /// that pinch point.
    func testTheJawTipsStopOnTheTableWhereTheTurningPinchPointSays() throws {
        let bench = Bench(turning())
        let phone = bench.client()
        bench.wait(0.5)
        phone.moveArm(to: bench.config.armStart + SIMD3(0.02, -0.01, -0.07), seconds: 4)
        let arm = bench.model.world.arm
        let pinch = ServerModelConfig.ToolTurn.s4Simulator.pinch(arm)
        let tableTop = bench.config.tableTopWorld - bench.config.baseInWorld.z
        XCTAssertEqual(pinch.z - bench.config.jawReachBelowPinch, tableTop, accuracy: 1e-9, "on the table")
        XCTAssertGreaterThan(arm.z, bench.config.armStart.z - bench.config.workspaceHalfSize, "above the box's floor")
        XCTAssertEqual(try XCTUnwrap(toolPoint(bench.model.state)), pinch)
    }

    /// At the reset pose, where the two lie 2.5 cm apart, closing jaws take hold of the cube when the turning pinch
    /// point is at its centre, and not when the reported point plus the tool offset is.
    func testTheJawsTakeHoldWhereTheTurningPinchPointIs() {
        let config = turning()
        let arm = config.armStart
        var world = World(config)
        XCTAssertEqual(world.arm, arm)
        world.jaw = 50
        world.cube = ServerModelConfig.ToolTurn.s4Simulator.pinch(arm) + config.baseInWorld
        XCTAssertTrue(world.jawsAroundCube(config), "the cube between the turning jaws")
        world.cube = arm + config.toolOffset + config.baseInWorld
        XCTAssertFalse(world.jawsAroundCube(config), "the cube where fixed jaws would be")
    }

    /// Told to stop during a run, the model sends the next position without a tool point.
    func testAModelToldToStopReportingTheToolPointLeavesItOut() {
        let bench = Bench()
        let phone = bench.client()
        bench.wait(0.5)
        XCTAssertNotNil(toolPoint(phone.lastState), "reported at first")
        bench.model.reportsToolPoint = false
        bench.wait(0.5)
        XCTAssertNotNil(phone.lastState["ee_pos"])
        XCTAssertNil(phone.lastState["tool_pos"], "no longer reported")
        XCTAssertNil(bench.model.state["tool_pos"])
    }
}
