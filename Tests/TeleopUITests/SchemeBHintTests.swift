import XCTest

/// Scheme B's two words, Open and Close, sit at the control surface's middle height, each in the outer margin of its
/// own half, beside the guide and far above STOP. They run into nothing the screen draws: the guide's two views, the
/// state word and its detail lines, the read-outs, the recorder line, the practice mark. Which word is on which side
/// follows the hand. Both hands, both languages, at 874 pt and at 667 pt.
final class SchemeBHintTests: XCTestCase {
    private struct Size {
        var name: String
        var arguments: [String]
        var frame: CGRect?
        var safeTop: CGFloat
    }

    private static let sizes = [
        Size(name: "874", arguments: [], frame: nil, safeTop: 62),
        Size(
            name: "667", arguments: ["-screenFrame", "375x667x20x0"],
            frame: CGRect(x: 0, y: 0, width: 375, height: 667), safeTop: 20),
    ]

    override func setUp() {
        continueAfterFailure = false
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

    /// Checks both words on the screen as it is; `rightHanded` says where Open must be.
    private func checkHints(
        _ app: XCUIApplication, size: Size, rightHanded: Bool, what: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let snapshot = try? app.snapshot() else {
            return XCTFail("no snapshot of \(what)", file: file, line: line)
        }
        let all = flatten(snapshot)
        func frame(_ id: String) -> CGRect? { all.first { $0.identifier == id }?.frame }
        guard let open = frame("operating.hint_open"), let close = frame("operating.hint_close"),
            frame("operating.stop") != nil
        else { return XCTFail("\(what): a hint word or the band is missing", file: file, line: line) }
        let screen = size.frame ?? app.windows.firstMatch.frame
        let scale = screen.height / 874
        let bandTop = stopBandRows(app, file: file, line: line).top
        let surfaceTop = size.safeTop + 64 * scale
        let surfaceBottom = bandTop - 16 * scale
        let middle = (surfaceTop + surfaceBottom) / 2

        let (left, right) = rightHanded ? (open, close) : (close, open)
        XCTAssertLessThan(left.midX, right.midX, "\(what): which word is on which side", file: file, line: line)
        // The outer margin of each half, clear of the faint band down the middle and of the 12 pt edge filter.
        XCTAssertGreaterThanOrEqual(left.minX, 12, "\(what): \(left) at the left edge", file: file, line: line)
        XCTAssertLessThanOrEqual(
            right.maxX, screen.maxX - 12, "\(what): \(right) at the right edge", file: file, line: line)
        XCTAssertLessThan(left.maxX, screen.midX - 24, "\(what): \(left) reaches the middle", file: file, line: line)
        XCTAssertGreaterThan(
            right.minX, screen.midX + 24, "\(what): \(right) reaches the middle", file: file, line: line)

        let panels = all.filter { ["guide.above", "guide.behind"].contains($0.identifier) }.map(\.frame)
        // The read-outs sit on one dark box, 10 pt wider on each side and 4 pt taller than their lines.
        let readouts = all.filter { $0.identifier.hasPrefix("readout.") }.map { $0.frame.insetBy(dx: -10, dy: -4) }
        let named = all.filter {
            ["operating.state", "operating.detail", "operating.rec", "practice.mark"].contains($0.identifier)
        }.map(\.frame)
        let texts = all.filter {
            $0.type == .staticText && !$0.label.isEmpty && !$0.identifier.hasPrefix("operating.hint_")
        }.map(\.frame)
        for (word, rect) in [("Open", open), ("Close", close)] {
            XCTAssertEqual(rect.midY, middle, accuracy: 2, "\(what): \(word) at mid height", file: file, line: line)
            for other in panels + readouts + named + texts {
                let overlap = rect.intersection(other)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5,
                    "\(what): \(word) \(rect) runs into \(other)", file: file, line: line)
            }
            let above = bandTop - rect.maxY
            XCTAssertGreaterThan(
                above, 0.4 * (surfaceBottom - surfaceTop), "\(what): \(word) near STOP", file: file, line: line)
            let place = "\(word) at x \(Int(rect.minX)) to \(Int(rect.maxX)), y \(Int(rect.minY)) to \(Int(rect.maxY))"
            let report = "\(what): \(place), \(Int(above.rounded())) pt above the top of the STOP band"
            print("HINT \(report)")
            XCTContext.runActivity(named: report) { _ in }
        }
        if let guide = panels.first {
            print("HINT \(what): guide views x \(Int(guide.minX)) to \(Int(guide.maxX))")
        }
    }

    private func checkFixture(_ fixture: String, rightHanded: Bool) {
        for size in Self.sizes {
            for language in ["en", "zh-Hant"] {
                let app = XCUIApplication.teleop(
                    ["-operatingFixture", fixture, "-startRoute", "p4_standby"] + size.arguments, language: language)
                app.launch()
                expect(app, "operating.hint_open", timeout: 8)
                checkHints(app, size: size, rightHanded: rightHanded, what: "\(fixture) \(language) \(size.name)")
                if language == "en" { attachScreenshot("hints-\(fixture)-\(size.name)") }
            }
        }
    }

    func testRightHandWithTheGuide() {
        checkFixture("turning", rightHanded: true)
    }

    func testLeftHandWithTheGuide() {
        checkFixture("turning_left", rightHanded: false)
    }

    /// The most read-out lines scheme B shows: gripping, steering to the goal.
    func testWithTheMostReadOuts() {
        checkFixture("closing_gripped", rightHanded: true)
    }

    /// Practice in scheme B: the stripes and the practice mark, and no guide. The words leave while stopped.
    func testInPracticeAndGoneWhileStopped() {
        for size in Self.sizes {
            for (hand, rightHanded) in [("right", true), ("left", false)] {
                for language in ["en", "zh-Hant"] {
                    let app = XCUIApplication.teleop(
                        ["-startRoute", "p4_standby", "-controlMode", "keyTurns", "-hand", hand] + size.arguments,
                        language: language)
                    app.launch()
                    expect(app, "operating.hint_open", timeout: 8)
                    let what = "practice \(hand) \(language) \(size.name)"
                    checkHints(app, size: size, rightHanded: rightHanded, what: what)
                    if language == "en", hand == "right" { attachScreenshot("hints-practice-\(size.name)") }
                    guard language == "en", hand == "right" else { continue }
                    app.element("operating.stop").tap()
                    expect(app, "stop.release")
                    XCTAssertFalse(app.element("operating.hint_open").exists, "\(what): stopped")
                    XCTAssertFalse(app.element("operating.hint_close").exists, "\(what): stopped")
                }
            }
        }
    }
}
