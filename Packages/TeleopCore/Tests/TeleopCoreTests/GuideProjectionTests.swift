import XCTest
import simd
@testable import TeleopCore

/// The guide's projection: the ranges are the guide's own arithmetic, and the conversions it offers are inverses of
/// each other, so a tap read back through it lands where the mark under the finger was drawn.
final class GuideProjectionTests: XCTestCase {
    /// The SO-101 simulator's work box, robot base frame, pinch point, and its table height.
    private let boxMin = SIMD3(-0.052383, -0.257418, -0.008015)
    private let boxMax = SIMD3(0.107617, -0.097418, 0.151985)
    private let table = 0.04

    /// As the guide builds it: the box's corners in the operator's frame, sorted.
    private func projection(low: SIMD3<Double>, high: SIMD3<Double>, table: Double) -> GuideProjection {
        let a = TestFrames.so101.operatorPoint(low), b = TestFrames.so101.operatorPoint(high)
        return GuideProjection(frames: TestFrames.so101, boxLow: simd_min(a, b), boxHigh: simd_max(a, b), table: table)
    }

    func testTheRangesAreTheGuidesArithmetic() {
        let p = projection(low: boxMin, high: boxMax, table: table)
        // A 16 cm cube with a margin of 15 % of its larger side, half that below the table.
        XCTAssertEqual(p.across.lowerBound, -0.131617, accuracy: 1e-9)
        XCTAssertEqual(p.across.upperBound, 0.076383, accuracy: 1e-9)
        XCTAssertEqual(p.depth.lowerBound, 0.073418, accuracy: 1e-9)
        XCTAssertEqual(p.depth.upperBound, 0.281418, accuracy: 1e-9)
        XCTAssertEqual(p.height.lowerBound, 0.028, accuracy: 1e-9)
        XCTAssertEqual(p.height.upperBound, 0.175985, accuracy: 1e-9)
        XCTAssertEqual(p.aboveAspect, 1, accuracy: 1e-9)
        XCTAssertEqual(p.behindAspect, 0.208 / 0.147985, accuracy: 1e-9)
        XCTAssertEqual(p.behindAspect, 1.406, accuracy: 0.001)
        // Read back from the view from above: base x = 0.131617 − 0.208·sx, base y = −0.281418 + 0.208·sy.
        for sx in stride(from: -0.25, through: 1.25, by: 0.125) {
            for sy in stride(from: -0.25, through: 1.25, by: 0.125) {
                let base = TestFrames.so101.base(fromOperator: p.point(aboveShare: SIMD2(sx, sy), up: 0.09))
                XCTAssertEqual(base.x, 0.131617 - 0.208 * sx, accuracy: 1e-9, "\(sx), \(sy)")
                XCTAssertEqual(base.y, -0.281418 + 0.208 * sy, accuracy: 1e-9, "\(sx), \(sy)")
                XCTAssertEqual(base.z, 0.09, "the height asked for, exactly")
            }
        }
        // From behind: the table and the box's top, and one left-right axis for both views.
        let onTable = TestFrames.so101.operatorPoint(SIMD3(0.03, -0.18, table))
        XCTAssertEqual(p.behind(onTable).y, 1 - (0.04 - 0.028) / 0.147985, accuracy: 1e-9)
        let top = p.behind(TestFrames.so101.operatorPoint(boxMax))
        XCTAssertEqual(top.y, 1 - (0.151985 - 0.028) / 0.147985, accuracy: 1e-9)
        XCTAssertEqual(p.behind(onTable).x, p.above(onTable).x)
        // The box's centre is the centre of the view from above.
        let centre = p.above(TestFrames.so101.operatorPoint((boxMin + boxMax) / 2))
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-9)
    }

    /// The ranges on boxes that are not the SO-101's cube with the table under its top: the margin comes from the box's
    /// width and depth only, however tall it is, and a table above the box's top still has the margin above it.
    func testTheRangesHoldForATallBoxAndATableAboveTheBox() {
        // 10 cm across, 8 cm deep, 30 cm tall: the margin is 15 % of 10 cm, not of 30 cm.
        let tall = GuideProjection(
            frames: TestFrames.so101, boxLow: SIMD3(0, 0, 0), boxHigh: SIMD3(0.1, 0.08, 0.3), table: 0.02)
        XCTAssertEqual(tall.across.lowerBound, -0.015, accuracy: 1e-12)
        XCTAssertEqual(tall.across.upperBound, 0.115, accuracy: 1e-12)
        XCTAssertEqual(tall.depth.lowerBound, -0.015, accuracy: 1e-12)
        XCTAssertEqual(tall.depth.upperBound, 0.095, accuracy: 1e-12)
        XCTAssertEqual(tall.height.lowerBound, 0.02 - 0.0075, accuracy: 1e-12)
        XCTAssertEqual(tall.height.upperBound, 0.3 + 0.015, accuracy: 1e-12)
        XCTAssertEqual(tall.aboveAspect, 0.13 / 0.11, accuracy: 1e-12)
        XCTAssertEqual(tall.behindAspect, 0.13 / (0.315 - 0.0125), accuracy: 1e-12)

        // A table 3 cm above a 5 cm box's top: the view from behind runs from just under the table to the margin
        // over it.
        let low = GuideProjection(
            frames: TestFrames.so101, boxLow: SIMD3(0, 0, 0), boxHigh: SIMD3(0.1, 0.1, 0.05), table: 0.08)
        XCTAssertEqual(low.height.lowerBound, 0.08 - 0.0075, accuracy: 1e-12)
        XCTAssertEqual(low.height.upperBound, 0.08 + 0.015, accuracy: 1e-12)
        XCTAssertEqual(low.behindAspect, 0.13 / 0.0225, accuracy: 1e-9)
        XCTAssertEqual(low.behind(SIMD3(0.05, 0.05, 0.08)).y, 1 - 0.0075 / 0.0225, accuracy: 1e-12, "the table's line")
    }

    func testAboveAndItsInverseRoundTrip() {
        let p = projection(low: boxMin, high: boxMax, table: table)
        var random = SplitMix64(seed: 0x6E1D_E0B5)
        let low = TestFrames.so101.operatorPoint(boxMax) - 0.05, high = TestFrames.so101.operatorPoint(boxMin) + 0.05
        for i in 0..<1000 {
            // In the box and around it, past the margin on every side.
            let point = SIMD3(
                random.uniform(min(low.x, high.x), max(low.x, high.x)),
                random.uniform(min(low.y, high.y), max(low.y, high.y)),
                random.uniform(-0.05, 0.25))
            let share = p.above(point)
            let back = p.point(aboveShare: share, up: point.z)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-12, "\(i)")
            XCTAssertEqual(back.y, point.y, accuracy: 1e-12, "\(i)")
            XCTAssertEqual(back.z, point.z, "\(i)")
            let again = p.above(back)
            XCTAssertEqual(again.x, share.x, accuracy: 1e-12, "\(i)")
            XCTAssertEqual(again.y, share.y, accuracy: 1e-12, "\(i)")
        }
    }

    func testOperatorPointAndBaseAreInverses() {
        // The axis table, the one source: base −x is the operator's right, base −y forward, base +z up.
        for direction in OperatorDirection.allCases {
            let o = TestFrames.so101.operatorPoint(TestFrames.so101.baseVector(direction))
            let expected: SIMD3<Double>
            switch direction {
            case .right: expected = SIMD3(1, 0, 0)
            case .left: expected = SIMD3(-1, 0, 0)
            case .forward: expected = SIMD3(0, 1, 0)
            case .back: expected = SIMD3(0, -1, 0)
            case .up: expected = SIMD3(0, 0, 1)
            case .down: expected = SIMD3(0, 0, -1)
            }
            XCTAssertEqual(o, expected, "\(direction)")
            XCTAssertEqual(
                TestFrames.so101.base(fromOperator: expected), TestFrames.so101.baseVector(direction), "\(direction)")
        }
        var random = SplitMix64(seed: 0xBA5E)
        for i in 0..<1000 {
            let base = SIMD3(random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1))
            XCTAssertEqual(TestFrames.so101.base(fromOperator: TestFrames.so101.operatorPoint(base)), base, "\(i)")
            XCTAssertEqual(TestFrames.so101.operatorPoint(TestFrames.so101.base(fromOperator: base)), base, "\(i)")
        }
    }
}
