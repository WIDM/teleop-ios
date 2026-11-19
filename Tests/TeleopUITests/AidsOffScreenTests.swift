import UIKit
import XCTest

/// With the hands-free aids' master switch off on the real server, the operating screen says so on a line under the
/// state word, in English and in Traditional Chinese, at the test device's 874 pt and at 667 pt: the line is drawn
/// whole on one line, inside the screen, under the word and clear of the guide, with a screenshot attached. Each launch
/// pins both of the aids' settings and changes neither.
final class AidsOffScreenTests: XCTestCase {
    private static func aidsPinned(_ on: Bool) -> [String] { ["-assist", on ? "YES" : "NO", "-lockVariant", "off"] }

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

    private static let words = [
        "en": (state: "Available", note: "Hands-free aids off: taps do nothing"),
        "zh-Hant": (state: "可操作", note: "免持輔助已關閉：點圖不會動"),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheLineSaysTheAidsAreOffOnOneLine() {
        for size in Self.sizes {
            for (language, expected) in Self.words {
                let what = "\(language) \(size.name)"
                let app = XCUIApplication.teleop(
                    Self.aidsPinned(false) + ["-operatingFixture", "ready_aids_off", "-startRoute", "p4_standby"]
                        + size.arguments,
                    language: language)
                app.launch()
                let state = app.element("operating.state")
                XCTAssertTrue(state.waitForExistence(timeout: 8), what)
                XCTAssertEqual(state.label, expected.state, what)
                let note = app.element("operating.note")
                XCTAssertTrue(note.exists, "\(what): the line")
                XCTAssertEqual(note.label, expected.note, what)
                attachScreenshot("ready_aids_off-\(language)-\(size.name)")
                let screen = size.frame ?? app.windows.firstMatch.frame
                // The line is drawn in the detail lines' font, whose size follows the screen's height.
                let font = UIFont.systemFont(ofSize: max(15, 20 * screen.height / 874), weight: .medium)
                let width = (expected.note as NSString).size(withAttributes: [.font: font]).width
                let line = note.frame
                XCTAssertLessThan(line.height, font.lineHeight * 1.5, "\(what): \(line) is more than one line")
                XCTAssertGreaterThanOrEqual(line.width, width - 2, "\(what): \(line) is narrower than \(width): cut")
                XCTAssertTrue(screen.insetBy(dx: -0.5, dy: -0.5).contains(line), "\(what): \(line) leaves the screen")
                XCTAssertGreaterThanOrEqual(line.minY, state.frame.maxY - 0.5, "\(what): under the state word")
                let above = app.element("guide.above").frame
                XCTAssertFalse(above.isEmpty, "\(what): the guide is drawn")
                XCTAssertLessThanOrEqual(line.maxY, above.minY + 0.5, "\(what): \(line) runs into the guide \(above)")
            }
        }
    }

    /// The same reading with the switch on, as every other fixture shows it: no such line.
    func testWithTheSwitchOnThereIsNoLine() {
        let app = XCUIApplication.teleop(
            Self.aidsPinned(true) + ["-operatingFixture", "ready", "-startRoute", "p4_standby"], language: "en")
        app.launch()
        XCTAssertTrue(app.element("operating.state").waitForExistence(timeout: 8))
        XCTAssertFalse(app.element("operating.note").exists)
    }
}
