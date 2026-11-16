import XCTest
@testable import TeleopCore

final class ButtonRampTests: XCTestCase {
    func testSpeedsAreOneAndFourCentimetresASecond() {
        XCTAssertEqual(ButtonSpeed.fine.metresPerSecond, 0.01)
        XCTAssertEqual(ButtonSpeed.coarse.metresPerSecond, 0.04)
    }

    func testTheTargetGrowsAtTheChosenSpeedOfWallTime() {
        let fine = ButtonRamp(direction: .forward, speed: .fine, startMs: 10_000)
        XCTAssertEqual(fine.distance(atMs: 10_000), 0, "zero at the press")
        XCTAssertEqual(fine.distance(atMs: 10_500), 0.005, accuracy: 1e-12)
        XCTAssertEqual(fine.distance(atMs: 12_000), 0.02, accuracy: 1e-12)

        let coarse = ButtonRamp(direction: .forward, speed: .coarse, startMs: 10_000)
        XCTAssertEqual(coarse.distance(atMs: 10_500), 0.02, accuracy: 1e-12)
        XCTAssertEqual(coarse.distance(atMs: 12_000), 0.08, accuracy: 1e-12)
    }

    /// §3.3: a 200 ms Fine tap asks for 2 mm; the arm, trailing by about 0.5 s, moves well under that.
    func testAFineTapAsksForTwoMillimetres() {
        var ramp = ButtonRamp(direction: .down, speed: .fine, startMs: 0)
        ramp.freeze(atMs: 200)
        XCTAssertEqual(ramp.distance(atMs: 5_000), 0.002, accuracy: 1e-12)
    }

    func testTheOffsetPointsAlongTheButtonsDirectionInTheLinkFrame() {
        for direction in OperatorDirection.allCases {
            let ramp = ButtonRamp(direction: direction, speed: .coarse, startMs: 0)
            let offset = ramp.offset(atMs: 1_000)
            XCTAssertEqual(offset, direction.linkVector * 0.04, "\(direction)")
            XCTAssertEqual(OperatorFrame.base(fromLink: offset), direction.baseVector * 0.04, "\(direction)")
        }
    }

    func testReleaseFreezesTheTarget() {
        var ramp = ButtonRamp(direction: .up, speed: .coarse, startMs: 1_000)
        ramp.freeze(atMs: 1_750)
        let frozen = ramp.offset(atMs: 1_750)
        XCTAssertEqual(ramp.distance(atMs: 1_750), 0.03, accuracy: 1e-12)
        XCTAssertEqual(ramp.offset(atMs: 2_000), frozen)
        XCTAssertEqual(ramp.offset(atMs: 60_000), frozen)
    }

    func testASecondFreezeKeepsTheFirst() {
        var ramp = ButtonRamp(direction: .left, speed: .fine, startMs: 0)
        ramp.freeze(atMs: 1_000)
        ramp.freeze(atMs: 3_000)
        XCTAssertEqual(ramp.frozenAtMs, 1_000)
        XCTAssertEqual(ramp.distance(atMs: 4_000), 0.01, accuracy: 1e-12)
    }

    func testANewPressStartsAgainFromZero() {
        var first = ButtonRamp(direction: .right, speed: .coarse, startMs: 0)
        first.freeze(atMs: 2_000)
        XCTAssertEqual(first.distance(atMs: 2_500), 0.08, accuracy: 1e-12)

        let second = ButtonRamp(direction: .right, speed: .coarse, startMs: 2_500)
        XCTAssertEqual(second.offset(atMs: 2_500), .zero)
        XCTAssertEqual(second.distance(atMs: 2_750), 0.01, accuracy: 1e-12)
    }

    func testAClockBeforeThePressGivesZero() {
        var ramp = ButtonRamp(direction: .back, speed: .coarse, startMs: 5_000)
        XCTAssertEqual(ramp.distance(atMs: 4_000), 0)
        ramp.freeze(atMs: 4_000)
        XCTAssertEqual(ramp.frozenAtMs, 5_000)
        XCTAssertEqual(ramp.distance(atMs: 9_000), 0)
    }
}
