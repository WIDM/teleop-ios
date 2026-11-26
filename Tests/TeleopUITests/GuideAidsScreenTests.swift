import XCTest

/// The guide's aids on the operating screen, from the fixture that draws them: the two views say which way is forward
/// and which way is up, in English and in Traditional Chinese, at the test device's 874 pt and at 667 pt, with a
/// screenshot attached for the drawing (the shadow, the arrows, the lowest line), which no test reads. Without the aids
/// the views keep their version 1.0.1 names. Each launch pins both of the aids' settings and changes neither.
final class GuideAidsScreenTests: XCTestCase {
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

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ fixture: String, language: String, size: Size) -> XCUIApplication {
        let app = XCUIApplication.teleop(
            Self.aidsPinned + ["-operatingFixture", fixture, "-startRoute", "p4_standby"] + size.arguments,
            language: language)
        app.launch()
        let what = "\(fixture) \(language) \(size.name)"
        XCTAssertTrue(app.element("operating.state").waitForExistence(timeout: 8), what)
        return app
    }

    func testTheViewsSayWhichWayIsForwardAndWhichWayIsUp() {
        let labels = [
            "en": (
                "From above. Up the screen is forward.", "From behind. Up the screen is up.", "Available",
                "Height 6.2 cm"
            ),
            "zh-Hant": ("從上面看。螢幕往上是前方。", "從後面看。螢幕往上是上方。", "可操作", "離桌面 6.2 公分"),
        ]
        for size in Self.sizes {
            for (language, expected) in labels {
                let app = launch("ready_aids", language: language, size: size)
                let what = "\(language) \(size.name)"
                XCTAssertEqual(app.element("operating.state").label, expected.2, what)
                XCTAssertEqual(app.element("guide.above").label, expected.0, what)
                XCTAssertEqual(app.element("guide.behind").label, expected.1, what)
                attachScreenshot("ready_aids-\(language)-\(size.name)")
                let screen = size.frame ?? app.windows.firstMatch.frame
                for id in ["guide.above", "guide.behind"] {
                    let panel = app.element(id).frame
                    XCTAssertGreaterThanOrEqual(min(panel.width, panel.height), 40, "\(what): \(id) \(panel)")
                    XCTAssertTrue(screen.contains(panel), "\(what): \(id) \(panel) leaves the screen")
                }
                // The lowest height is just above the table and the jaws 6 cm up: the height is the plain one.
                XCTAssertEqual(app.element("readout.height").label, expected.3, what)
            }
        }
    }

    /// The same reading without the aids, as every version 1.0.1 fixture draws it: the views keep their names.
    func testWithoutTheAidsTheViewsKeepTheirNames() {
        let app = launch("ready", language: "en", size: Self.sizes[0])
        XCTAssertEqual(app.element("guide.above").label, "From above")
        XCTAssertEqual(app.element("guide.behind").label, "From behind")
    }
}
