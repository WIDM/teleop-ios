import XCTest
@testable import TeleopCore

final class SurfaceLayoutTests: XCTestCase {
    /// The reference device, 402 × 874 pt, with its safe-area insets.
    let layout = SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34)

    func testZonesOnTheReferenceDevice() {
        XCTAssertEqual(layout.topBand, .init(x: 0, y: 0, width: 402, height: 126))
        XCTAssertEqual(layout.bottomBand, .init(x: 0, y: 768, width: 402, height: 106))
        XCTAssertEqual(layout.gap, .init(x: 0, y: 752, width: 402, height: 16))
        XCTAssertEqual(layout.controlSurface, .init(x: 0, y: 126, width: 402, height: 626))
        XCTAssertEqual(layout.gear, .init(x: 0, y: 66, width: 56, height: 56))
    }

    func testJudgingOrder() {
        XCTAssertEqual(layout.zone(x: 200, y: 873), .bottomBand)
        XCTAssertEqual(layout.zone(x: 200, y: 768), .bottomBand)
        XCTAssertEqual(layout.zone(x: 200, y: 767.9), .gap)
        XCTAssertEqual(layout.zone(x: 200, y: 752), .gap)
        XCTAssertEqual(layout.zone(x: 200, y: 751.9), .controlSurface)
        XCTAssertEqual(layout.zone(x: 200, y: 126), .controlSurface)
        XCTAssertEqual(layout.zone(x: 200, y: 125.9), .topBand)
        XCTAssertEqual(layout.zone(x: 30, y: 90), .gear)
        XCTAssertEqual(layout.zone(x: 60, y: 90), .topBand)
        // The status bar strip at the left end is top band, not gear.
        XCTAssertEqual(layout.zone(x: 30, y: 20), .topBand)
    }

    func testZonesScaleWithHeightButSafeAreasDoNot() {
        let small = SurfaceLayout(width: 375, height: 667, safeTop: 20, safeBottom: 0)
        let scale = 667.0 / 874
        XCTAssertEqual(small.topBand.height, 20 + 64 * scale, accuracy: 1e-9)
        XCTAssertEqual(small.bottomBand.height, 72 * scale, accuracy: 1e-9)
        XCTAssertEqual(small.gap.height, 16 * scale, accuracy: 1e-9)
        XCTAssertEqual(small.gear.width, 56 * scale, accuracy: 1e-9)
        XCTAssertEqual(small.controlSurface.maxY, small.gap.y, accuracy: 1e-9)
    }

    func testSideEdgesAndHalves() {
        XCTAssertTrue(layout.isAtSideEdge(x: 12))
        XCTAssertFalse(layout.isAtSideEdge(x: 12.1))
        XCTAssertTrue(layout.isAtSideEdge(x: 390))
        XCTAssertFalse(layout.isAtSideEdge(x: 389.9))

        XCTAssertEqual(layout.side(x: 201 + 24, hand: .right), .centre)
        XCTAssertEqual(layout.side(x: 201 - 24, hand: .right), .centre)
        XCTAssertEqual(layout.side(x: 201 + 24.1, hand: .right), .near)
        XCTAssertEqual(layout.side(x: 201 - 24.1, hand: .right), .far)
        XCTAssertEqual(layout.side(x: 300, hand: .left), .far)
        XCTAssertEqual(layout.side(x: 100, hand: .left), .near)
    }

    func testTenMillimetresIsSixtyFourPointsOnTheReferenceDevice() {
        XCTAssertEqual(layout.millimetres(64), 10, accuracy: 1e-12)
        XCTAssertEqual(SurfaceLayout(width: 402, height: 874, safeTop: 0, safeBottom: 0, pointsPerMm: 6).millimetres(60), 10)
    }
}
