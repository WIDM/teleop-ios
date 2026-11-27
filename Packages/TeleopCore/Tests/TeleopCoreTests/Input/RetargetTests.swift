import simd
import XCTest
@testable import TeleopCore

final class RetargetTests: XCTestCase {
    private typealias Rig = ArbiterRig

    func testASecondTapPausesThenChangesTheTargetWithoutReopeningTheHold() throws {
        var rig = makeRig()
        let first = Rig.inPanel(0.3, 0.4)
        let second = Rig.inPanel(0.7, 0.5)
        XCTAssertEqual(rig.tap(1, at: first, after: 0.1), [.startTranslation])
        let since = rig.time
        XCTAssertEqual(rig.touchDown(2, at: second, after: 0.1), [])
        let paused = try XCTUnwrap(rig.arbiter.goOffset(at: rig.time))
        XCTAssertEqual(rig.arbiter.goOffset(at: rig.time + 0.03), paused)
        XCTAssertEqual(rig.lift(2, after: 0.07), [])
        XCTAssertEqual(rig.arbiter.engagement, .going(target: Rig.target(of: second), since: since))
        let resumed = try XCTUnwrap(rig.arbiter.goOffset(at: rig.time))
        XCTAssertLessThan(simd_distance(resumed, paused), 1e-9)
    }

    func testStopPreemptsAPendingSecondTap() {
        var rig = makeRig()
        XCTAssertEqual(rig.tap(1, at: Rig.inPanel(0.3, 0.4), after: 0.1), [.startTranslation])
        XCTAssertEqual(rig.touchDown(2, at: Rig.inPanel(0.7, 0.5), after: 0.1), [])
        XCTAssertEqual(rig.touchDown(3, at: Rig.bottomBand, after: 0.01), [.emergencyStop, .stopTranslation])
        XCTAssertEqual(rig.lift(2, after: 0.05), [])
        XCTAssertNil(rig.arbiter.engagement)
    }

    func testLongContactStopsWithoutRetargeting() {
        var rig = makeRig()
        XCTAssertEqual(rig.tap(1, at: Rig.inPanel(0.3, 0.4), after: 0.1), [.startTranslation])
        XCTAssertEqual(rig.touchDown(2, at: Rig.inPanel(0.7, 0.5), after: 0.1), [])
        XCTAssertEqual(rig.wait(0.31), [.stopTranslation, .cue(.drive(.stoppedByYou))])
        XCTAssertEqual(rig.lift(2, after: 0.02), [])
        XCTAssertNil(rig.arbiter.engagement)
    }

    func testARetargetWaitsForAPositionMeasuredAfterTheChange() {
        let start = SIMD3(0.027617, -0.177418, Rig.travelZ)
        var move = GoMove(
            frames: TestFrames.so101,
            start: start, target: start + SIMD3(0.04, 0, 0), limits: Rig.goLimits, at: 10,
            boxLow: Rig.boxLow, boxHigh: Rig.boxHigh)
        move.pauseForRetarget(at: 10.2)
        let paused = move.linkOffset(at: 10.2)
        XCTAssertTrue(move.retarget(start + SIMD3(0, 0.04, 0.02), at: 10.3))
        XCTAssertNil(move.observe(ArmFix(pinch: start, ageS: 0.1, holdPaused: false), at: 10.3))
        XCTAssertEqual(move.linkOffset(at: 10.7), paused)
        XCTAssertNil(move.observe(ArmFix(pinch: start, ageS: 0.5, holdPaused: false), at: 10.7))
        XCTAssertEqual(move.linkOffset(at: 10.9), paused)
        XCTAssertNil(move.observe(ArmFix(pinch: start, ageS: 0, holdPaused: false), at: 10.9))
        XCTAssertGreaterThan(simd_distance(move.linkOffset(at: 11.1), paused), 0)
    }

    func testRearDescentKeepsHorizontalPositionAndStopsAtTheTravelFloor() {
        var rig = rearRig(height: 0.08)
        let point = rearPoint(height: 0.055)
        XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.startTranslation])
        guard case .going(let target, _) = rig.arbiter.engagement else { return XCTFail("expected descent") }
        XCTAssertEqual(target.x, 0.027617, accuracy: 1e-9)
        XCTAssertEqual(target.y, -0.177418, accuracy: 1e-9)
        XCTAssertEqual(target.z, Rig.table + 0.055, accuracy: 1e-9)
    }

    func testRearTapBelowTheFloorExplainsManualDescentWithoutStarting() {
        for height in [0.01, 0.05, 0.057] {
            var rig = rearRig(height: height)
            XCTAssertEqual(rig.tap(1, at: rearPoint(height: 0.02), after: 0.1), [.cue(.refused(.useUpperKey))])
            XCTAssertNil(rig.arbiter.engagement)
        }
    }

    func testRearRetargetCanLowerTheRunningTargetWithoutReopeningTheHold() {
        var rig = rearRig(height: 0.06)
        XCTAssertEqual(rig.tap(1, at: rearPoint(height: 0.085), after: 0.1), [.startTranslation])
        XCTAssertEqual(rig.tap(2, at: rearPoint(height: 0.055), after: 0.2), [])
        guard case .going(let target, _) = rig.arbiter.engagement else { return XCTFail("expected retarget") }
        XCTAssertEqual(target.x, 0.027617, accuracy: 1e-9)
        XCTAssertEqual(target.y, -0.177418, accuracy: 1e-9)
        XCTAssertEqual(target.z, Rig.table + 0.055, accuracy: 1e-9)
    }

    func testRearRetargetBelowTheFloorStopsAndExplainsManualDescent() {
        var rig = rearRig(height: 0.05)
        XCTAssertEqual(rig.tap(1, at: rearPoint(height: 0.085), after: 0.1), [.startTranslation])
        XCTAssertEqual(
            rig.tap(2, at: rearPoint(height: 0.02), after: 0.2),
            [.stopTranslation, .cue(.refused(.useUpperKey))])
        XCTAssertNil(rig.arbiter.engagement)
    }

    private func rearPanel() -> GoPanel {
        var panel = Rig.panel()
        panel.behind = .init(x: 118, y: 440, width: 166, height: 100)
        return panel
    }

    private func rearPoint(height: Double) -> SIMD2<Double> {
        let panel = rearPanel()
        let share = panel.projection.behind(
            TestFrames.so101.operatorPoint(SIMD3(0.027617, -0.177418, Rig.table + height)))
        return SIMD2(118 + share.x * 166, 440 + share.y * 100)
    }

    private func rearRig(height: Double) -> Rig {
        var rig = makeRig()
        rig.facts = Rig.goFacts(panel: rearPanel(), arm: SIMD3(0.027617, -0.177418, Rig.table + height))
        return rig
    }

    private func makeRig() -> Rig {
        let assist = Assist(goTo: Rig.goLimits, views: ViewAim(behindTopAboveTableM: 0.09, maxRetargetedMoveS: 30))
        var rig = Rig(.screenTurns, assist: assist)
        rig.facts = Rig.goFacts(arm: SIMD3(0.027617, -0.177418, Rig.travelZ))
        return rig
    }
}
