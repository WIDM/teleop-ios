import TeleopServerHost
import TeleopServerModel
import XCTest

/// A tap on the guide's view from above sends the jaws there, against the server model this test process serves on
/// 127.0.0.1: a tap inside the drawn view goes, a tap just outside any of its edges names the top view, and one just
/// inside each edge is judged against the view, so the rectangle the input rules judge a tap against is the one the
/// screen draws. Each launch pins both of the aids' settings and changes neither.
final class GuidePanelTapUITests: XCTestCase {
    private var server: LocalTeleopServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = LocalTeleopServer(captureCommands: true)
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// The operating screen on the local server with the guide drawn, ready.
    private func launch(aimViews: Bool = false) -> XCUIApplication {
        let app = XCUIApplication.teleop([
            "-liveLink", "YES", "-serverAddress", server.address, "-startRoute", "p4_standby", "-assist", "YES",
            "-lockVariant", "off", "-aimViews", aimViews ? "YES" : "NO",
        ])
        app.launch()
        expectLabel(app.element("operating.state"), "Available", timeout: 8)
        expect(app, "guide.above")
        return app
    }

    private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    private func assertOneCompletedPoseHold(
        since offset: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [server] _, _ in
                guard let trace = server?.commandTrace() else { return false }
                let events = Array(trace.events.dropFirst(offset))
                let starts = events.filter { $0.direction == .received && $0.type == "pose_start" }
                guard let start = starts.first else { return false }
                return events.contains {
                    $0.direction == .sent && $0.type == "ack" && $0.sequence == start.sequence
                        && $0.connection == start.connection && $0.status == "ok" && $0.reason == "pose_stopped"
                }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 3), .completed, file: file, line: line)
        let trace = server.commandTrace()
        XCTAssertEqual(trace.droppedCount, 0, "command evidence must be complete", file: file, line: line)
        let events = Array(trace.events.dropFirst(offset))
        XCTAssertEqual(
            events.filter { $0.direction == .received && $0.type == "pose_start" }.count,
            1, "a retarget must keep one hold open", file: file, line: line)
        XCTAssertEqual(
            events.filter { $0.direction == .received && $0.type == "pose_stop" }.count,
            1, file: file, line: line)
        XCTAssertFalse(events.contains { $0.direction == .sent && $0.status == "rejected" }, file: file, line: line)
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false, file: file, line: line)
        XCTAssertEqual(server.inspect { $0.state["ik"]?.stringValue }, "ok", file: file, line: line)
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
    /// "Available" once they have arrived.
    func testATapOnTheDrawnPanelGoes() {
        let app = launch()
        let frame = app.element("guide.above").frame
        let start = server.inspect { $0.world.arm }
        tap(app, x: frame.minX + 0.25 * frame.width, y: frame.minY + 0.25 * frame.height)
        let state = app.element("operating.state")
        expectLabel(state, "Going")
        attachScreenshot("guide-tap-going")
        expectLabel(state, "Available", timeout: 15)
        let moved = server.inspect { $0.world.arm } - start
        XCTAssertGreaterThan((moved * moved).sum().squareRoot(), 0.02, "the arm went to the tapped point")
    }

    func testTheRearPanelChangesHeightAndKeepsTheViewsFixed() throws {
        let app = launch(aimViews: true)
        let above = app.element("guide.above").frame
        let behind = app.element("guide.behind").frame
        let tapX = behind.midX.rounded()
        let raisedY = (behind.minY + 0.01 * behind.height).rounded()
        let floorY = (behind.minY + 0.85 * behind.height).rounded()
        XCTAssertGreaterThan(above.width, 240)
        XCTAssertEqual(behind.width, above.width, accuracy: 1)
        let start = server.inspect { $0.world.arm }
        let beforeRaise = server.commandTrace().events.count
        tap(app, x: tapX, y: raisedY)
        let reached = XCTNSPredicateExpectation(
            predicate: NSPredicate { [server] _, _ in
                guard let server else { return false }
                return server.inspect { $0.world.arm.z } - start.z > 0.01
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 10), .completed)
        XCTAssertEqual(app.element("guide.above").frame, above)
        XCTAssertEqual(app.element("guide.behind").frame, behind)
        expectLabel(app.element("operating.state"), "Available", timeout: 15)
        assertOneCompletedPoseHold(since: beforeRaise)
        let change = server.inspect { $0.world.arm } - start
        let table = server.config.tableTopWorld - server.config.baseInWorld.z
        let rearSpan = 0.09 + 0.16 * 0.15 / 2
        XCTAssertEqual(
            start.z + change.z + server.config.toolOffset.z,
            table + 0.09 - Double((raisedY - behind.minY) / behind.height) * rearSpan, accuracy: 0.008)
        XCTAssertGreaterThan(change.z, 0.01)
        XCTAssertLessThan(abs(change.x), 0.015)
        XCTAssertLessThan(abs(change.y), 0.015)
        attachScreenshot("rear-height-column-raised")
        let raised = server.inspect { $0.world.arm }
        let beforeDescent = server.commandTrace().events.count
        tap(app, x: tapX, y: floorY)
        expectLabel(app.element("operating.state"), "Available", timeout: 15)
        assertOneCompletedPoseHold(since: beforeDescent)
        let lowered = server.inspect { $0.world.arm }
        XCTAssertLessThan(lowered.z, raised.z - 0.01)
        XCTAssertLessThan(abs(lowered.x - raised.x), 0.015)
        XCTAssertLessThan(abs(lowered.y - raised.y), 0.015)
        XCTAssertEqual(lowered.z + server.config.toolOffset.z, table + 0.05, accuracy: 0.008)
        let beforeFloorTap = server.commandTrace().events.count
        tap(app, x: tapX, y: floorY)
        XCTAssertEqual(
            firstWord(app, of: ["Hold + to lower", "Going", "Arrived"], within: 2),
            "Hold + to lower")
        attachScreenshot("rear-height-floor-explained")
        XCTAssertEqual(server.inspect { $0.world.arm }, lowered, "the floor tap must not start another move")
        XCTAssertFalse(
            server.commandTrace().events.dropFirst(beforeFloorTap).contains {
                $0.direction == .received && $0.type == "pose_start"
            })
        XCTAssertEqual(server.commandTrace().droppedCount, 0)
    }

    func testASecondRearTapLowersTheRunningHeightTarget() throws {
        let app = launch(aimViews: true)
        let behind = app.element("guide.behind").frame
        let tapX = (behind.minX + 0.2 * behind.width).rounded()
        let raisedY = (behind.minY + 0.02 * behind.height).rounded()
        let loweredY = (behind.minY + 0.38 * behind.height).rounded()
        let beforeRetarget = server.commandTrace().events.count
        tap(app, x: tapX, y: raisedY)
        expectLabel(app.element("operating.state"), "Going")
        tap(app, x: tapX, y: loweredY)
        expectLabel(app.element("operating.state"), "Available", timeout: 15)
        assertOneCompletedPoseHold(since: beforeRetarget)
        let retargeted = server.inspect { $0.world.arm }
        let table = server.config.tableTopWorld - server.config.baseInWorld.z
        let rearSpan = 0.09 + 0.16 * 0.15 / 2
        let loweredHeight = table + 0.09 - Double((loweredY - behind.minY) / behind.height) * rearSpan
        let acrossShare = Double((tapX - behind.minX) / behind.width)
        let requestedX = server.config.armStart.x + server.config.toolOffset.x + (0.5 - acrossShare) * 0.16 * 1.3
        XCTAssertEqual(retargeted.x + server.config.toolOffset.x, requestedX, accuracy: 0.008)
        XCTAssertEqual(retargeted.y, server.config.armStart.y, accuracy: 0.008)
        XCTAssertEqual(
            retargeted.z + server.config.toolOffset.z, loweredHeight, accuracy: 0.008,
            "the second tap must reach the lower target, not merely stop the first move")
        let beforeRaise = server.commandTrace().events.count
        tap(app, x: tapX, y: raisedY)
        expectLabel(app.element("operating.state"), "Available", timeout: 15)
        assertOneCompletedPoseHold(since: beforeRaise)
        let raised = server.inspect { $0.world.arm }
        XCTAssertGreaterThan(
            raised.z - retargeted.z, 0.01,
            "the second tap selected a lower height than the first")
        XCTAssertEqual(
            raised.z + server.config.toolOffset.z,
            table + 0.09 - Double((raisedY - behind.minY) / behind.height) * rearSpan, accuracy: 0.008)
        XCTAssertEqual(raised.x, retargeted.x, accuracy: 0.008)
        XCTAssertEqual(raised.y, retargeted.y, accuracy: 0.008)
    }

    func testASecondTapMovesToTheNewSideWhileTheFirstMoveIsRunning() {
        let app = launch(aimViews: true)
        let frame = app.element("guide.above").frame
        let start = server.inspect { $0.world.arm }
        tap(app, x: frame.minX + 0.18 * frame.width, y: frame.minY + 0.18 * frame.height)
        expectLabel(app.element("operating.state"), "Going")
        tap(app, x: frame.minX + 0.75 * frame.width, y: frame.minY + 0.72 * frame.height)
        let reached = XCTNSPredicateExpectation(
            predicate: NSPredicate { [server] _, _ in
                guard let server else { return false }
                return server.inspect { $0.world.arm.x } < start.x - 0.02
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 15), .completed)
        expectLabel(app.element("operating.state"), "Available", timeout: 15)
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
        XCTAssertEqual(firstWord(app, of: ["Tap the top view", "Going"], within: 1), "Tap the top view")
        XCTAssertEqual(XCTWaiter().wait(for: [going], timeout: 2), .completed, "no move started")
        XCTAssertEqual(app.element("operating.state").label, "Available")
        XCTAssertEqual(server.inspect { $0.world.arm }, start, "the arm did not move")
    }

    /// 6 pt outside each edge, the screen says to tap the top view and the arm stays where it was.
    func testATapJustOutsideAnyEdgeOfTheDrawnPanelNamesTheTopView() {
        let app = launch()
        let frame = app.element("guide.above").frame
        let start = server.inspect { $0.world.arm }
        for (edge, x, y) in edges(of: frame, inward: -6) {
            tap(app, x: x, y: y)
            let words = wordsShown(app, for: 2)
            XCTAssertTrue(words.contains("Tap the top view"), "\(edge): \(words)")
            XCTAssertTrue(words.isSubset(of: ["Tap the top view", "Available"]), "\(edge): \(words)")
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
            expectLabel(state, "Available", timeout: 5)
        }
    }
}
