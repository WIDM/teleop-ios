import TeleopServerHost
import TeleopServerModel
import XCTest

/// A tap on the guide's view from above sends the jaws there, against the server model this test process serves on
/// 127.0.0.1: a tap inside the drawn view goes, a tap just outside any of its four edges does nothing, and one just
/// inside each edge is judged against the view, so the rectangle the input rules judge a tap against is the one the
/// screen draws. Each launch pins both of the aids' settings and changes neither.
final class GuidePanelTapUITests: XCTestCase {
    private var server: LocalTeleopServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = LocalTeleopServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// The operating screen on the local server with the guide drawn, ready.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication.teleop([
            "-liveLink", "YES", "-serverAddress", server.address, "-startRoute", "p4_standby", "-assist", "YES",
            "-lockVariant", "off",
        ])
        app.launch()
        expectLabel(app.element("operating.state"), "Ready", timeout: 8)
        expect(app, "guide.above")
        return app
    }

    private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    /// The middle of each edge of `frame`, moved `inward` points toward its centre (outward when negative).
    private func edges(of frame: CGRect, inward: CGFloat) -> [(edge: String, x: CGFloat, y: CGFloat)] {
        [
            ("left", frame.minX + inward, frame.midY), ("right", frame.maxX - inward, frame.midY),
            ("top", frame.midX, frame.minY + inward), ("bottom", frame.midX, frame.maxY - inward),
        ]
    }

    /// Every word the state showed over `seconds`, each once. A refusal's word is shown for a second only, so the
    /// screen is read again and again rather than waited on.
    private func wordsShown(_ app: XCUIApplication, for seconds: TimeInterval) -> Set<String> {
        let state = app.element("operating.state")
        var shown: Set<String> = []
        let end = Date().addingTimeInterval(seconds)
        repeat { shown.insert(state.label) } while Date() < end
        return shown
    }

    /// The first of `words` the state shows within `seconds`, read the same way; nil if none.
    private func firstWord(_ app: XCUIApplication, of words: Set<String>, within seconds: TimeInterval) -> String? {
        let state = app.element("operating.state")
        let end = Date().addingTimeInterval(seconds)
        repeat {
            let word = state.label
            if words.contains(word) { return word }
        } while Date() < end
        return nil
    }

    /// A quarter of the way across and down the drawn view: the screen says "Going" while the jaws go there, and
    /// "Ready" once they have arrived.
    func testATapOnTheDrawnPanelGoes() {
        let app = launch()
        let frame = app.element("guide.above").frame
        let start = server.inspect { $0.world.arm }
        tap(app, x: frame.minX + 0.25 * frame.width, y: frame.minY + 0.25 * frame.height)
        let state = app.element("operating.state")
        expectLabel(state, "Going")
        attachScreenshot("guide-tap-going")
        expectLabel(state, "Ready", timeout: 15)
        let moved = server.inspect { $0.world.arm } - start
        XCTAssertGreaterThan((moved * moved).sum().squareRoot(), 0.02, "the arm went to the tapped point")
    }

    /// 6 pt left of the drawn view, at its middle height: nothing goes, and the arm stays where it was.
    func testATapJustOutsideTheDrawnPanelDoesNotGo() {
        let app = launch()
        let frame = app.element("guide.above").frame
        let start = server.inspect { $0.world.arm }
        tap(app, x: frame.minX - 6, y: frame.midY)
        let going = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Going"), object: app.element("operating.state"))
        going.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [going], timeout: 2), .completed, "no move started")
        XCTAssertEqual(app.element("operating.state").label, "Ready")
        XCTAssertEqual(server.inspect { $0.world.arm }, start, "the arm did not move")
    }

    /// 6 pt outside each of the drawn view's four edges, at the edge's middle: nothing goes and nothing is told, the
    /// screen saying "Ready" throughout, neither "Going" nor a refusal, and the arm stays where it was.
    func testATapJustOutsideAnyEdgeOfTheDrawnPanelDoesNothing() {
        let app = launch()
        let frame = app.element("guide.above").frame
        let start = server.inspect { $0.world.arm }
        for (edge, x, y) in edges(of: frame, inward: -6) {
            tap(app, x: x, y: y)
            XCTAssertEqual(wordsShown(app, for: 2), ["Ready"], "\(edge): no move and no refusal")
            XCTAssertEqual(server.inspect { $0.world.arm }, start, "\(edge): the arm did not move")
        }
    }

    /// 6 pt inside each of the drawn view's four edges, at the edge's middle: the tap is judged against the view. A
    /// place in the margin drawn around the work box is refused, the screen saying "Outside the work area", and the
    /// arm stays; a place in the box starts a move, which a touch elsewhere on the surface then stops.
    func testATapJustInsideEachEdgeOfTheDrawnPanelIsJudged() {
        let app = launch()
        let frame = app.element("guide.above").frame
        let state = app.element("operating.state")
        for (edge, x, y) in edges(of: frame, inward: 6) {
            let start = server.inspect { $0.world.arm }
            tap(app, x: x, y: y)
            switch firstWord(app, of: ["Going", "Outside the work area"], within: 5) {
            case "Going"?:
                // Any touch stops a move nobody holds; this one lands on the surface well below the view.
                tap(app, x: frame.midX, y: frame.maxY + 60)
            case "Outside the work area"?:
                attachScreenshot("guide-tap-inside-\(edge)")
                XCTAssertEqual(server.inspect { $0.world.arm }, start, "\(edge): refused, the arm stays")
            case let word:
                XCTFail("\(edge): the tap was not judged against the view, the screen read \(String(describing: word))")
            }
            expectLabel(state, "Ready", timeout: 5)
        }
    }
}
