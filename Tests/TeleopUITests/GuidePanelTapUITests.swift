import TeleopServerHost
import TeleopServerModel
import XCTest

/// A tap on the guide's view from above sends the jaws there, against the server model this test process serves on
/// 127.0.0.1: a tap inside the drawn view goes, and a tap just outside it does nothing, so the rectangle the input
/// rules judge a tap against is the one the screen draws. Each launch pins both of the aids' settings and changes
/// neither.
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
}
