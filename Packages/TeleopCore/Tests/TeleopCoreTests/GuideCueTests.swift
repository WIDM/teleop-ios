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

    /// The sideways sides as they are said in Traditional Chinese.
    func testTheSidesReadNaturallyInChinese() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Speech.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        func text(_ key: SpeechKey, _ language: String) -> String? {
            let localizations = strings[key.rawValue]?["localizations"] as? [String: [String: [String: String]]]
            return localizations?[language]?["stringUnit"]?["value"]
        }
        XCTAssertEqual(text(.rangeLeft, "en"), "Too far left.")
        XCTAssertEqual(text(.rangeLeft, "zh-Hant"), "太靠左了。")
        XCTAssertEqual(text(.rangeRight, "en"), "Too far right.")
        XCTAssertEqual(text(.rangeRight, "zh-Hant"), "太靠右了。")
    }

    func testCantGoLowerIsSpokenAsBlockedIs() {
        let lowest = CueTable.row(for: .limit(.lowest)), blocked = CueTable.row(for: .limit(.blocked))
        XCTAssertEqual(lowest.speech, [.lowest])
        XCTAssertEqual(lowest.haptic, blocked.haptic)
        XCTAssertEqual(lowest.sound, blocked.sound)
        XCTAssertEqual(lowest.level, blocked.level)
    }
}
