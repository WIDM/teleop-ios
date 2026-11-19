import TeleopServerHost
import TeleopServerModel
import XCTest

final class VoiceAxisEntryUITests: XCTestCase {
    private var server: LocalTeleopServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = LocalTeleopServer(captureCommands: true)
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testVoiceEntryWithoutAidsOnRegularScreen() {
        exerciseEntry(aids: false, shortScreen: false, mode: "screenTurns")
    }

    func testVoiceEntryWithAidsOnRegularScreen() {
        exerciseEntry(aids: true, shortScreen: false, mode: "keyTurns")
    }

    func testVoiceEntryWithoutAidsOnShortScreen() {
        exerciseEntry(aids: false, shortScreen: true, mode: "keyTurns")
    }

    func testVoiceEntryWithAidsOnShortScreen() {
        exerciseEntry(aids: true, shortScreen: true, mode: "screenTurns")
    }

    private func exerciseEntry(aids: Bool, shortScreen: Bool, mode: String) {
        let app = XCUIApplication.teleop(
            [
                "-liveLink", "YES", "-serverAddress", server.address, "-startRoute", "p4_standby",
                "-controlMode", mode, "-assist", aids ? "YES" : "NO", "-taskAid", aids ? "YES" : "NO",
                "-lockVariant", "off",
            ] + (shortScreen ? ["-screenFrame", "375x667x20x0"] : []))
        app.launch()
        defer { app.terminate() }
        expectLabel(app.element("operating.state"), "Available", timeout: 8)
        let voice = app.element("voice.axis")
        let precision = app.element("precision.open")
        let stop = app.element("operating.stop")
        expect(app, "voice.axis")
        XCTAssertEqual(app.element("guide.above").exists, aids)
        XCTAssertEqual(app.element("guide.behind").exists, aids)
        XCTAssertTrue(voice.isHittable)
        XCTAssertTrue(precision.isHittable)
        XCTAssertTrue(stop.isHittable)
        XCTAssertGreaterThanOrEqual(voice.frame.height, 44)
        XCTAssertGreaterThanOrEqual(voice.frame.width, 44)
        XCTAssertFalse(voice.frame.intersects(precision.frame))
        XCTAssertLessThanOrEqual(voice.frame.maxY, stopBandRows(app).top)
        if shortScreen {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 375, height: 667).contains(voice.frame))
        }
        let arm = server.inspect { $0.world.arm }
        let jaw = server.inspect { $0.world.jaw }
        let before = server.commandTrace().events.count
        voice.tap()
        expectLabel(voice, "Tool control required")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(server.inspect { $0.world.arm }, arm)
        XCTAssertEqual(server.inspect { $0.world.jaw }, jaw)
        let trace = server.commandTrace()
        XCTAssertEqual(trace.droppedCount, 0)
        XCTAssertFalse(
            trace.events.dropFirst(before).contains {
                $0.direction == .received
                    && ["pose_start", "pose_update", "jog_start", "gripper_jog_start", "orient_start"].contains($0.type)
            }, "A refused voice entry must not send movement commands")
        XCTAssertTrue(stop.isHittable)
        XCTAssertTrue(precision.isHittable)
        attachScreenshot("voice-entry-aids-\(aids)-short-\(shortScreen)-\(mode)")
        stop.tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, true)
    }
}
