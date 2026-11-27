import simd
import XCTest
@testable import TeleopCore

final class GoPanelBehindTests: XCTestCase {
    func testHeightOnlyColumnKeepsBothTableCoordinates() {
        let panel = makePanel()
        let current = TestFrames.so101.base(fromOperator: SIMD3(0, 0.03, 0.06))
        let limits = ArbiterRig.goTo().goTo!
        let views = ViewAim(behindTopAboveTableM: 0.09)
        guard
            case .target(let result) = panel.aimBehind(
                at: SIMD2(121.9, 154 + 10), measured: current, limits: limits, views: views)
        else { return XCTFail("the rear panel should give a target") }
        let mapped = TestFrames.so101.operatorPoint(result)
        XCTAssertEqual(mapped.x, 0, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, 0.03, accuracy: 1e-9)
        XCTAssertGreaterThan(mapped.z, 0.06)
        XCTAssertEqual(panel.view(at: SIMD2(100, 149)), nil, "the gap between the views is not a tap target")
    }

    func testALowerTapConflictsWithTheFloorOnlyWhenTheJawsAreAlreadyLow() {
        let panel = makePanel()
        let limits = ArbiterRig.goTo().goTo!
        let views = ViewAim(behindTopAboveTableM: 0.09)
        let low = TestFrames.so101.base(fromOperator: SIMD3(0, 0.03, 0.01))
        let normal = TestFrames.so101.base(fromOperator: SIMD3(0, 0.03, 0.08))
        XCTAssertEqual(panel.aimBehind(at: SIMD2(100, 239), measured: low, limits: limits, views: views), .useUpperKey)
        guard
            case .target(let target) = panel.aimBehind(
                at: SIMD2(100, 239), measured: normal, limits: limits, views: views)
        else { return XCTFail("the height should be clamped to the travel floor") }
        XCTAssertEqual(TestFrames.so101.operatorPoint(target).z, limits.travelHeightM, accuracy: 1e-9)
    }

    func testALowerTapAtTheFloorExplainsManualDescentInsteadOfArriving() {
        let panel = makePanel()
        let limits = ArbiterRig.goTo().goTo!
        let current = TestFrames.so101.base(fromOperator: SIMD3(0, 0.03, limits.travelHeightM))
        XCTAssertEqual(
            panel.aimBehind(
                at: SIMD2(100, 239), measured: current, limits: limits,
                views: ViewAim(behindTopAboveTableM: 0.09)), .useUpperKey)
    }

    private func makePanel() -> GoPanel {
        let low = SIMD3(-0.2, -0.2, 0.0)
        let high = SIMD3(0.2, 0.2, 0.2)
        return GoPanel(
            rect: .init(x: 20, y: 40, width: 160, height: 104),
            projection: GuideProjection(
                frames: TestFrames.so101, boxLow: low, boxHigh: high, table: 0, behindTop: 0.09),
            boxLow: low, boxHigh: high, tableHeight: 0, behind: .init(x: 20, y: 154, width: 160, height: 90))
    }
}
