import XCTest
@testable import TeleopCore

/// The guide's two spoken limits: the commanded position leaving the work area, said by its side in the operator's
/// words, and a stall against a downward command, said as "Can't go lower.". Both play END with words that may be
/// dropped, as "Blocked." does.
final class GuideCueTests: XCTestCase {
    func testEachSideHasItsOwnWords() {
        for side in OperatorDirection.allCases {
            let event = FeedbackEvent.commandOutside(side)
            XCTAssertEqual(event.key, .commandOutside(side))
            XCTAssertNil(event.number)
            let row = CueTable.row(for: event.key)
            XCTAssertEqual(row.haptic, .end, "\(side)")
            XCTAssertNil(row.sound, "\(side)")
            XCTAssertEqual(row.speech.map(\.rawValue), ["say.range.\(side.rawValue)"], "\(side)")
            XCTAssertEqual(row.level, .p4, "\(side)")
        }
    }

    func testCantGoLowerIsSpokenAsBlockedIs() {
        let lowest = CueTable.row(for: .limit(.lowest)), blocked = CueTable.row(for: .limit(.blocked))
        XCTAssertEqual(lowest.speech, [.lowest])
        XCTAssertEqual(lowest.haptic, blocked.haptic)
        XCTAssertEqual(lowest.sound, blocked.sound)
        XCTAssertEqual(lowest.level, blocked.level)
    }
}
