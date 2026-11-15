import XCTest
@testable import TeleopCore

/// A-4's slide, judged once for scheme A's open rule and the lock's slide up.
final class ThumbSlideTests: XCTestCase {
    private let layout = SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34)
    private let down = SIMD2<Double>(200, 500)

    /// A thumb that moved this many millimetres right and up the glass (screen y grows down).
    private func moved(right: Double, up: Double, on layout: SurfaceLayout? = nil) -> SIMD2<Double> {
        let perMm = (layout ?? self.layout).pointsPerMm
        return down + SIMD2(right * perMm, -up * perMm)
    }

    private func judge(_ at: SIMD2<Double>, on layout: SurfaceLayout? = nil) -> ThumbSlide {
        ThumbSlide.judge(from: down, to: at, layout: layout ?? self.layout, constants: .appendixA)
    }

    func testTheSlideIsSchemeAsOpenRule() {
        XCTAssertEqual(judge(moved(right: 0, up: 9.99)), .short)
        XCTAssertEqual(judge(moved(right: 9.99, up: 9.99)), .short, "the larger component, not the straight distance")
        XCTAssertEqual(judge(moved(right: 0, up: 10)), .up)
        XCTAssertEqual(judge(moved(right: 9.99, up: 10)), .up, "more up than sideways")
        XCTAssertEqual(judge(moved(right: -9.99, up: 10)), .up)
        XCTAssertEqual(judge(moved(right: 10, up: 10)), .sideways, "45 degrees is not more up than sideways")
        XCTAssertEqual(judge(moved(right: -10, up: 10)), .sideways)
        XCTAssertEqual(judge(moved(right: 10, up: 0)), .sideways)
        XCTAssertEqual(judge(moved(right: 0, up: -10)), .sideways, "down the glass")
        XCTAssertEqual(judge(moved(right: 2, up: -12)), .sideways, "down, and more down than sideways")
        // Millimetres come from the layout's density: 30 pt is 10 mm at 3 pt/mm and under 5 mm at 6.4.
        let coarse = SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34, pointsPerMm: 3)
        XCTAssertEqual(judge(down + SIMD2(0, -30), on: coarse), .up)
        XCTAssertEqual(judge(down + SIMD2(0, -30)), .short)
    }

    func testMostlyUpAndUpMillimetres() {
        XCTAssertTrue(ThumbSlide.mostlyUp(from: down, to: moved(right: 0, up: 1)))
        XCTAssertTrue(ThumbSlide.mostlyUp(from: down, to: moved(right: -0.9, up: 1)))
        XCTAssertFalse(ThumbSlide.mostlyUp(from: down, to: moved(right: 1, up: 1)))
        XCTAssertFalse(ThumbSlide.mostlyUp(from: down, to: moved(right: 0, up: -1)))
        XCTAssertFalse(ThumbSlide.mostlyUp(from: down, to: down), "not moved is not up")
        XCTAssertEqual(
            ThumbSlide.upMillimetres(from: down, to: moved(right: 4, up: 3), layout: layout), 3, accuracy: 1e-9)
        XCTAssertEqual(
            ThumbSlide.upMillimetres(from: down, to: moved(right: 0, up: -2), layout: layout), -2, accuracy: 1e-9)
    }
}
