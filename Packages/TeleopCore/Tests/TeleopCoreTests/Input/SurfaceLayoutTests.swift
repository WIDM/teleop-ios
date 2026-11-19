import XCTest
@testable import TeleopCore

final class SurfaceLayoutTests: XCTestCase {
    /// The reference device, 402 × 874 pt, with its safe-area insets.
    let layout = SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34)

    func testZonesOnTheReferenceDevice() {
        XCTAssertEqual(layout.topBand, .init(x: 0, y: 0, width: 402, height: 126))
        XCTAssertEqual(layout.bottomSafeArea, .init(x: 0, y: 840, width: 402, height: 34))
        XCTAssertEqual(layout.bottomBand, .init(x: 0, y: 768, width: 402, height: 72))
        XCTAssertEqual(layout.gap, .init(x: 0, y: 752, width: 402, height: 16))
        XCTAssertEqual(layout.controlSurface, .init(x: 0, y: 126, width: 402, height: 626))
        XCTAssertEqual(layout.gear, .init(x: 0, y: 66, width: 56, height: 56))
    }

    func testJudgingOrder() {
        XCTAssertEqual(layout.zone(x: 200, y: 874), .bottomSafeArea)
        XCTAssertEqual(layout.zone(x: 200, y: 873.9), .bottomSafeArea)
        XCTAssertEqual(layout.zone(x: 0, y: 840), .bottomSafeArea)
        XCTAssertEqual(layout.zone(x: 401.9, y: 840), .bottomSafeArea)
        XCTAssertEqual(layout.zone(x: 200, y: 839.9), .bottomBand)
        XCTAssertEqual(layout.zone(x: 0, y: 839.9), .bottomBand)
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
        XCTAssertEqual(small.gear.width, 44, accuracy: 1e-9, "56 pt scaled would be 42.7 pt, under the minimum")
        XCTAssertEqual(small.controlSurface.maxY, small.gap.y, accuracy: 1e-9)
    }

    /// The short screen the UI tests draw (an iPhone SE, 375 × 667 pt) has no bottom safe area: the band runs to the
    /// bottom of the glass, as before.
    func testZonesOnTheShortScreen() {
        let small = SurfaceLayout(width: 375, height: 667, safeTop: 20, safeBottom: 0)
        XCTAssertEqual(small.bottomSafeArea, .init(x: 0, y: 667, width: 375, height: 0))
        XCTAssertEqual(small.bottomBand.y, 667 - 72 * 667.0 / 874, accuracy: 1e-9)
        XCTAssertEqual(small.bottomBand.maxY, 667, accuracy: 1e-9)
        XCTAssertEqual(small.gap.y, small.bottomBand.y - 16 * 667.0 / 874, accuracy: 1e-9)
        XCTAssertEqual(small.zone(x: 200, y: 666.9), .bottomBand)
        XCTAssertEqual(small.zone(x: 200, y: 667), .bottomBand, "the very edge, where nothing is under the band")
    }

    /// A short screen with a home indicator (an iPhone mini, 375 × 812 pt): the band scales with the height, the
    /// safe area under it does not.
    func testZonesOnAShortScreenWithAHomeIndicator() {
        let mini = SurfaceLayout(width: 375, height: 812, safeTop: 50, safeBottom: 34)
        let band = 72 * 812.0 / 874
        XCTAssertEqual(mini.bottomSafeArea, .init(x: 0, y: 778, width: 375, height: 34))
        XCTAssertEqual(mini.bottomBand.y, 778 - band, accuracy: 1e-9)
        XCTAssertEqual(mini.bottomBand.height, band, accuracy: 1e-9)
        XCTAssertEqual(mini.zone(x: 200, y: 777.9), .bottomBand)
        XCTAssertEqual(mini.zone(x: 200, y: 778), .bottomSafeArea)
    }

    /// Only the safe area under the band changed: on every screen the band's top edge, the gap, the control surface
    /// and the top band are where they were when the band reached the bottom of the glass, and with no bottom safe
    /// area nothing moved at all.
    func testTheBandsTopEdgeAndEverythingAboveStayPut() {
        for (width, height, safeTop) in [(402.0, 874.0, 62.0), (375, 667, 20), (375, 812, 50), (440, 956, 62)] {
            for safeBottom in [0.0, 21, 34] {
                let layout = SurfaceLayout(width: width, height: height, safeTop: safeTop, safeBottom: safeBottom)
                let scale = height / 874
                let what = "\(width) × \(height), safe bottom \(safeBottom)"
                // Where the band began when it was `bottomBandPt` scaled plus the safe area.
                XCTAssertEqual(layout.bottomBand.y, height - (72 * scale + safeBottom), accuracy: 1e-9, what)
                XCTAssertEqual(layout.bottomBand.maxY, layout.bottomSafeArea.y, accuracy: 1e-9, what)
                XCTAssertEqual(layout.bottomSafeArea.maxY, height, accuracy: 1e-9, what)
                XCTAssertEqual(layout.gap.maxY, layout.bottomBand.y, accuracy: 1e-9, what)
                XCTAssertEqual(layout.controlSurface.maxY, layout.gap.y, accuracy: 1e-9, what)
                if safeBottom == 0 {
                    XCTAssertEqual(layout.zone(x: width / 2, y: height - 0.1), .bottomBand, what)
                } else {
                    XCTAssertEqual(layout.zone(x: width / 2, y: height - 0.1), .bottomSafeArea, what)
                    XCTAssertEqual(layout.zone(x: width / 2, y: height - safeBottom - 0.1), .bottomBand, what)
                }
            }
        }
    }

    /// The gear is a touch target: at least 44 pt on a side at every screen height, inside the top band and below
    /// the status bar.
    func testTheGearIsAtLeast44PointsAtEveryHeight() {
        for height in stride(from: 480.0, through: 1000, by: 1) {
            for safeTop in [0.0, 20, 47, 62] {
                let layout = SurfaceLayout(width: 375, height: height, safeTop: safeTop, safeBottom: 34)
                XCTAssertGreaterThanOrEqual(layout.gear.width, 44, "height \(height)")
                XCTAssertGreaterThanOrEqual(layout.gear.height, 44, "height \(height)")
                XCTAssertGreaterThanOrEqual(layout.gear.y, safeTop, "height \(height): under the status bar")
                XCTAssertLessThanOrEqual(
                    layout.gear.maxY, layout.topBand.maxY + 1e-9, "height \(height): outside the band")
                XCTAssertEqual(layout.zone(x: layout.gear.x + 22, y: layout.gear.y + 22), .gear)
            }
        }
        XCTAssertEqual(
            SurfaceLayout(width: 375, height: 667, safeTop: 20, safeBottom: 0).gear.width, 44, accuracy: 1e-9)
        XCTAssertEqual(layout.gear.width, 56, "the reference device keeps the specified size")
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
        XCTAssertEqual(
            SurfaceLayout(width: 402, height: 874, safeTop: 0, safeBottom: 0, pointsPerMm: 6).millimetres(60), 10)
    }
}
