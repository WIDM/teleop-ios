import XCTest

/// The operating screen's fixtures for the aids, in English and in Traditional Chinese, at the test device's 874 pt and
/// at 667 pt, with a screenshot attached: a follow nobody holds says "Locked on" and how it stops, and the guide drawn
/// with its aids. No text leaves the screen, runs into another, covers the guide or reaches the gap above STOP. Each
/// launch pins both of the aids' settings and changes neither.
final class AssistOperatingScreenTests: XCTestCase {
    private static let aidsPinned = ["-assist", "YES", "-lockVariant", "off"]

    /// The fixture, and the state word it shows in English and in Chinese.
    private static let words: [String: (en: String, zh: String)] = [
        "locked": ("Locked on", "已鎖定"),
        "ready_aids": ("Ready", "就緒"),
    ]

    private struct Size {
        var name: String
        var arguments: [String]
        /// The app's frame on the device: the whole screen, or the smaller test frame at the top left.
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

    /// Launches the fixture in both languages and both sizes and checks each; `each` gets every launch with its
    /// language, for the caller's own checks.
    private func render(
        _ fixture: String, file: StaticString = #filePath, line: UInt = #line,
        each: (XCUIApplication, String) -> Void = { _, _ in }
    ) {
        let word = Self.words[fixture]!
        for size in Self.sizes.reversed() {
            for (language, expected) in [("zh-Hant", word.zh), ("en", word.en)] {
                let app = XCUIApplication.teleop(
                    Self.aidsPinned + ["-operatingFixture", fixture, "-startRoute", "p4_standby"] + size.arguments,
                    language: language)
                app.launch()
                let what = "\(fixture) \(language) \(size.name)"
                let state = app.element("operating.state")
                XCTAssertTrue(state.waitForExistence(timeout: 8), what, file: file, line: line)
                XCTAssertEqual(state.label, expected, what, file: file, line: line)
                attachScreenshot("\(fixture)-\(language)-\(size.name)")
                checkLayout(app, frame: size.frame ?? app.windows.firstMatch.frame, what: what, file: file, line: line)
                each(app, language)
            }
        }
    }

    func testLocked() {
        render("locked") { app, language in
            let detail = language == "en" ? "Any key or touch stops it" : "按任一鍵或觸碰即停"
            XCTAssertTrue(app.staticTexts[detail].exists, "\(language): how it stops")
            for id in ["guide.above", "guide.behind"] {
                XCTAssertTrue(app.element(id).exists, "\(language): \(id)")
            }
        }
    }

    func testTheGuideWithItsAids() {
        render("ready_aids")
    }

    private struct Seen {
        var label: String
        var identifier: String
        var frame: CGRect
        var type: XCUIElement.ElementType
    }

    private func flatten(_ snapshot: XCUIElementSnapshot) -> [Seen] {
        [
            Seen(
                label: snapshot.label, identifier: snapshot.identifier, frame: snapshot.frame,
                type: snapshot.elementType)
        ]
            + snapshot.children.flatMap(flatten)
    }

    /// The operating screen's layout rules, as the version 1.0.1 fixtures are held to them: no text off the screen,
    /// over other text, over a panel of the guide or under a control, none reaching the gap above STOP, and each panel
    /// of the guide at least 40 pt.
    private func checkLayout(_ app: XCUIApplication, frame screen: CGRect, what: String, file: StaticString, line: UInt)
    {
        guard let snapshot = try? app.snapshot() else {
            return XCTFail("no snapshot of \(what)", file: file, line: line)
        }
        let all = flatten(snapshot)
        guard let stop = all.first(where: { $0.identifier == "operating.stop" })?.frame else {
            return XCTFail("\(what): no STOP band", file: file, line: line)
        }
        let gapTop = stop.minY - 16 * screen.height / 874
        // Controls draw their own words inside them.
        let controls =
            all.filter { $0.identifier.hasPrefix("buttons.") || $0.identifier == "stop.release" }.map(\.frame) + [stop]
        let texts = all.filter { seen in
            seen.type == .staticText && !seen.label.isEmpty && seen.identifier != "operating.stop"
                && !controls.contains { $0.insetBy(dx: -1, dy: -1).contains(seen.frame) }
        }
        let tolerance: CGFloat = 0.5
        for text in texts {
            XCTAssertTrue(
                screen.insetBy(dx: -tolerance, dy: -tolerance).contains(text.frame),
                "\(what): \"\(text.label)\" \(text.frame) leaves the screen \(screen)", file: file, line: line)
            XCTAssertLessThanOrEqual(
                text.frame.maxY, gapTop + tolerance,
                "\(what): \"\(text.label)\" \(text.frame) reaches the gap above STOP", file: file, line: line)
        }
        let panels = all.filter { $0.identifier == "guide.above" || $0.identifier == "guide.behind" }
        for panel in panels {
            XCTAssertGreaterThanOrEqual(
                min(panel.frame.width, panel.frame.height), 40,
                "\(what): \(panel.identifier) \(panel.frame) is too small to read", file: file, line: line)
        }
        for (index, a) in texts.enumerated() {
            for b in texts.dropFirst(index + 1) {
                let overlap = a.frame.intersection(b.frame)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) runs into \"\(b.label)\" \(b.frame)", file: file, line: line)
            }
            for panel in panels {
                let overlap = a.frame.intersection(panel.frame)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) covers the guide \(panel.frame)", file: file, line: line)
            }
            for control in controls {
                let overlap = a.frame.intersection(control)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) runs under a control \(control)", file: file, line: line)
            }
        }
    }
}
