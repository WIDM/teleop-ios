import UIKit
import XCTest

/// The words the operating screen shows for a second when a touch on the guide was not taken as a tap, in English and
/// in Traditional Chinese, at the test device's 874 pt and at 667 pt: each is drawn whole on one line, inside the
/// screen and clear of the guide, with a screenshot attached. Each launch pins both of the aids' settings and changes
/// neither.
final class TapWordsScreenTests: XCTestCase {
    private static let aidsPinned = ["-assist", "YES", "-lockVariant", "off"]

    private struct Size {
        var name: String
        var arguments: [String]
        var frame: CGRect?
    }

    private static let sizes = [
        Size(name: "874", arguments: [], frame: nil),
        Size(
            name: "667", arguments: ["-screenFrame", "375x667x20x0"], frame: CGRect(x: 0, y: 0, width: 375, height: 667)
        ),
    ]

    /// The fixture, and the word it shows in English and in Chinese.
    private static let words: [(fixture: String, en: String, zh: String)] = [
        ("refused_tap_still", "Keep still", "手指別動"),
        ("refused_tap_let_go", "Tap and let go", "點一下就放開"),
        ("refused_tap_view_above", "Tap the top view", "請點上面的圖"),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    func testEachWordIsOneLine() {
        for size in Self.sizes {
            for word in Self.words {
                for (language, expected) in [("en", word.en), ("zh-Hant", word.zh)] {
                    check(word.fixture, language: language, expected: expected, size: size)
                }
            }
        }
    }

    private func check(_ fixture: String, language: String, expected: String, size: Size) {
        let what = "\(fixture) \(language) \(size.name)"
        let app = XCUIApplication.teleop(
            Self.aidsPinned + ["-operatingFixture", fixture, "-startRoute", "p4_standby"] + size.arguments,
            language: language)
        app.launch()
        let state = app.element("operating.state")
        XCTAssertTrue(state.waitForExistence(timeout: 8), what)
        XCTAssertEqual(state.label, expected, what)
        attachScreenshot("\(fixture)-\(language)-\(size.name)")
        let screen = size.frame ?? app.windows.firstMatch.frame
        // The state word's font, whose size follows the screen's height.
        let font = UIFont.systemFont(ofSize: max(30, 44 * screen.height / 874), weight: .bold)
        let width = (expected as NSString).size(withAttributes: [.font: font]).width
        let word = state.frame
        XCTAssertLessThan(word.height, font.lineHeight * 1.5, "\(what): \(word) is more than one line")
        XCTAssertGreaterThanOrEqual(word.width, width - 2, "\(what): \(word) is narrower than \(width): cut")
        XCTAssertTrue(screen.insetBy(dx: -0.5, dy: -0.5).contains(word), "\(what): \(word) leaves the screen")
        let above = app.element("guide.above").frame
        XCTAssertFalse(above.isEmpty, "\(what): the guide is drawn")
        XCTAssertLessThanOrEqual(word.maxY, above.minY + 0.5, "\(what): \(word) runs into the guide \(above)")
    }
}
