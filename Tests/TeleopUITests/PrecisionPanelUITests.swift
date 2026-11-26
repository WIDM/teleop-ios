import TeleopServerHost
import TeleopServerModel
import XCTest

final class PrecisionPanelUITests: XCTestCase {
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

    private func launch(mode: String, shortScreen: Bool = false) -> XCUIApplication {
        let app = XCUIApplication.teleop(
            [
                "-liveLink", "YES", "-serverAddress", server.address, "-startRoute", "p4_standby",
                "-controlMode", mode, "-assist", "NO", "-taskAid", "NO", "-lockVariant", "off",
            ] + (shortScreen ? ["-screenFrame", "375x667x20x0"] : []))
        app.launch()
        expectLabel(app.element("operating.state"), "Available", timeout: 8)
        XCTAssertFalse(app.element("guide.above").exists)
        XCTAssertFalse(app.element("guide.behind").exists)
        expect(app, "precision.open")
        app.element("precision.open").tap()
        expect(app, "precision.close")
        expect(app, "buttons.up")
        XCTAssertFalse(app.element("buttons.speed").exists)
        return app
    }

    func testScreenTurnsHasFineHeightAndJawsWithoutAidsOrGuide() {
        exerciseHeightAndJaws(mode: "screenTurns", expectedMode: "Screen turns (A)")
    }

    func testKeyTurnsHasFineHeightAndJawsWithoutAidsOrGuide() {
        exerciseHeightAndJaws(mode: "keyTurns", expectedMode: "Key turns (B)")
    }

    private func exerciseHeightAndJaws(mode: String, expectedMode: String) {
        let app = launch(mode: mode)
        attachScreenshot("precision-\(mode)-aids-off")
        let original = server.inspect { $0.world.arm }
        let beforeUp = server.commandTrace().events.count
        app.element("buttons.up").press(forDuration: 2)
        assertCompletedPose(since: beforeUp)
        let raised = server.inspect { $0.world.arm }
        XCTAssertGreaterThan(raised.z - original.z, 0.005)
        XCTAssertLessThan(raised.z - original.z, 0.03, "a two-second fine hold must not use coarse speed")
        XCTAssertEqual(raised.x, original.x, accuracy: 0.002)
        XCTAssertEqual(raised.y, original.y, accuracy: 0.002)

        let beforeDown = server.commandTrace().events.count
        app.element("buttons.down").press(forDuration: 2)
        assertCompletedPose(since: beforeDown)
        let lowered = server.inspect { $0.world.arm }
        XCTAssertGreaterThan(raised.z - lowered.z, 0.005)
        XCTAssertLessThan(raised.z - lowered.z, 0.03)
        XCTAssertEqual(lowered.x, raised.x, accuracy: 0.002)
        XCTAssertEqual(lowered.y, raised.y, accuracy: 0.002)

        let jawBefore = server.inspect { $0.world.jaw }
        let beforeOpen = server.commandTrace().events.count
        app.element("buttons.open").press(forDuration: 0.6)
        assertCompletedJaw(since: beforeOpen)
        let opened = server.inspect { $0.world.jaw }
        XCTAssertGreaterThan(opened, jawBefore + 5)
        let beforeClose = server.commandTrace().events.count
        app.element("buttons.close").press(forDuration: 0.6)
        assertCompletedJaw(since: beforeClose)
        XCTAssertLessThan(server.inspect { $0.world.jaw }, opened - 5)
        XCTAssertEqual(server.inspect { $0.world.arm }, lowered, "jaw controls must not move the arm")

        app.element("precision.close").tap()
        expect(app, "precision.open")
        XCTAssertFalse(app.element("buttons.up").exists)
        XCTAssertEqual(app.element("operating.mode").label, expectedMode)
        XCTAssertFalse(app.element("guide.above").exists)
        XCTAssertFalse(app.element("guide.behind").exists)
        XCTAssertEqual(server.commandTrace().droppedCount, 0)
    }

    func testShortScreenPanelOwnsItsBackgroundAndLeavesStopUsable() {
        let app = launch(mode: "keyTurns", shortScreen: true)
        let screen = CGRect(x: 0, y: 0, width: 375, height: 667)
        let stop = app.element("operating.stop")
        let band = stopBandRows(app)
        let panel = app.element("precision.panel").frame
        XCTAssertFalse(panel.isEmpty)
        XCTAssertLessThanOrEqual(panel.maxY, band.top)
        func checkButtons(_ ids: [String]) {
            for id in ids {
                let button = app.element("buttons.\(id)")
                XCTAssertTrue(button.isHittable, id)
                XCTAssertGreaterThanOrEqual(button.frame.width, 60, id)
                XCTAssertGreaterThanOrEqual(button.frame.height, 60, id)
                XCTAssertTrue(screen.contains(button.frame), id)
                XCTAssertLessThanOrEqual(button.frame.maxY, band.top, id)
            }
        }
        checkButtons(["up", "down", "left", "right", "forward", "back", "open", "close"])
        XCTAssertTrue(app.element("precision.close").isHittable)
        XCTAssertTrue(app.element("precision.page").isHittable)
        app.element("precision.page").tap()
        checkButtons(["up", "down", "tilt_up", "tilt_down", "turn_left", "turn_right", "open", "close"])
        for id in ["left", "right", "forward", "back"] {
            XCTAssertFalse(app.element("buttons.\(id)").exists, "\(id) gives its cell to a wrist button")
        }
        attachScreenshot("precision-667-wrist-page")
        app.element("precision.page").tap()
        expect(app, "buttons.forward")
        XCTAssertTrue(stop.isHittable)
        attachScreenshot("precision-667-aids-off-stop-visible")

        let before = server.commandTrace().events.count
        let arm = server.inspect { $0.world.arm }
        let jaw = server.inspect { $0.world.jaw }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: panel.minX + 3, dy: panel.midY)).press(forDuration: 1)
        XCTAssertEqual(server.commandTrace().events.count, before, "the tray margin must not start a phone hold")
        XCTAssertEqual(server.inspect { $0.world.arm }, arm)
        XCTAssertEqual(server.inspect { $0.world.jaw }, jaw)
        XCTAssertTrue(app.element("precision.close").exists)

        stop.tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, true)
        XCTAssertEqual(server.commandTrace().droppedCount, 0)
    }

    func testEntryDoesNotCoverGuideReadoutsOrHintsOnRegularScreen() {
        assertEntryHasItsOwnSpace(shortScreen: false)
    }

    func testEntryDoesNotCoverGuideReadoutsOrHintsOnShortScreen() {
        assertEntryHasItsOwnSpace(shortScreen: true)
    }

    private func assertEntryHasItsOwnSpace(shortScreen: Bool) {
        for mode in ["screenTurns", "keyTurns"] {
            for aids in [false, true] {
                let app = XCUIApplication.teleop(
                    [
                        "-liveLink", "YES", "-serverAddress", server.address, "-startRoute", "p4_standby",
                        "-controlMode", mode, "-assist", aids ? "YES" : "NO", "-taskAid", "YES",
                        "-lockVariant", "off",
                    ] + (shortScreen ? ["-screenFrame", "375x667x20x0"] : []))
                app.launch()
                expectLabel(app.element("operating.state"), "Available", timeout: 8)
                let entry = app.element("precision.open")
                XCTAssertTrue(entry.isHittable)
                XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
                XCTAssertLessThanOrEqual(entry.frame.maxY, stopBandRows(app).top)
                let ids =
                    ["guide.above", "guide.behind", "readout.height", "readout.jaws", "readout.wrist"]
                    + (mode == "screenTurns" ? ["operating.hint"] : ["operating.hint_open", "operating.hint_close"])
                for id in ids {
                    let element = app.element(id)
                    XCTAssertTrue(element.exists, "\(mode), aids \(aids): missing \(id)")
                    XCTAssertFalse(element.frame.intersects(entry.frame), "\(id) overlaps the precision entry")
                }
                attachScreenshot("precision-entry-\(mode)-aids-\(aids)-short-\(shortScreen)")
                app.terminate()
            }
        }
    }

    private func assertCompletedPose(since offset: Int, file: StaticString = #filePath, line: UInt = #line) {
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [server] _, _ in
                guard let events = server?.commandTrace().events.dropFirst(offset),
                    let start = events.first(where: { $0.direction == .received && $0.type == "pose_start" })
                else { return false }
                return events.contains {
                    $0.direction == .sent && $0.sequence == start.sequence && $0.connection == start.connection
                        && $0.status == "ok" && $0.reason == "pose_stopped"
                }
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: UITestWaits.serverAnswer), .completed, file: file, line: line)
        let trace = server.commandTrace()
        let events = trace.events.dropFirst(offset)
        XCTAssertEqual(trace.droppedCount, 0, file: file, line: line)
        XCTAssertEqual(
            events.filter { $0.direction == .received && $0.type == "pose_start" }.count, 1, file: file, line: line)
        XCTAssertEqual(
            events.filter { $0.direction == .received && $0.type == "pose_stop" }.count, 1, file: file, line: line)
        XCTAssertFalse(events.contains { $0.status == "rejected" }, file: file, line: line)
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false, file: file, line: line)
    }

    private func assertCompletedJaw(since offset: Int, file: StaticString = #filePath, line: UInt = #line) {
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [server] _, _ in
                server?.commandTrace().events.dropFirst(offset).contains {
                    $0.direction == .sent && $0.status == "ok" && $0.reason == "gripper_jog_stopped"
                } == true
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: UITestWaits.serverAnswer), .completed, file: file, line: line)
        let trace = server.commandTrace()
        let events = trace.events.dropFirst(offset)
        XCTAssertEqual(trace.droppedCount, 0, file: file, line: line)
        XCTAssertEqual(
            events.filter { $0.reason == "gripper_jog_stop_requested" && $0.status == "ok" }.count, 1, file: file,
            line: line)
        XCTAssertEqual(
            events.filter { $0.reason == "gripper_jog_stopped" && $0.status == "ok" }.count, 1, file: file, line: line)
        XCTAssertFalse(events.contains { $0.status == "rejected" }, file: file, line: line)
        XCTAssertFalse(events.contains { $0.direction == .received && $0.type == "pose_start" }, file: file, line: line)
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false, file: file, line: line)
    }
}
