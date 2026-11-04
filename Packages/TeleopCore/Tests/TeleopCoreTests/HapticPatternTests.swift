import XCTest
@testable import TeleopCore

final class HapticPatternTests: XCTestCase {
    private func starts(_ p: HapticPattern) -> [Int] { p.pulses.map(\.startMs) }

    func testOneShortGripperClosed() {
        let p = HapticCue.gripperClosed.pattern
        XCTAssertEqual(starts(p), [0])
        XCTAssertEqual(p.pulses.map(\.durationMs), [60])
        XCTAssertFalse(p.repeats)
    }

    func testTwoShortGripperOpened() {
        let p = HapticCue.gripperOpened.pattern
        XCTAssertEqual(starts(p), [0, 180])
        XCTAssertEqual(p.pulses.map(\.durationMs), [60, 60])
    }

    func testThreeShortCommandBlocked() {
        let p = HapticCue.commandBlocked.pattern
        XCTAssertEqual(starts(p), [0, 180, 360])
        XCTAssertEqual(p.pulses.map(\.durationMs), [60, 60, 60])
    }

    func testLongBuzzRepeatsFourOnTwoOff() {
        let p = HapticCue.emergencyLoop.pattern
        XCTAssertEqual(p.pulses, [HapticPulse(startMs: 0, durationMs: 400)])
        XCTAssertEqual(p.loopLengthMs, 600)
        XCTAssertTrue(p.repeats)
    }

    func testRejectsInvalidShortCount() {
        XCTAssertNil(HapticPattern.shortBuzz(count: 0))
        XCTAssertNil(HapticPattern.shortBuzz(count: 4))
    }

    func testExactlyFourDistinctPatterns() {
        let patterns = HapticCue.allCases.map(\.pattern)
        XCTAssertEqual(patterns.count, 4)
        for (i, a) in patterns.enumerated() {
            for b in patterns[(i + 1)...] { XCTAssertNotEqual(a, b) }
        }
    }
}
