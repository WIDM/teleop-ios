import XCTest

final class StopFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-startRoute", "p4_standby"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expect(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
    }

    func testStopTapShowsEStoppedScreen() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        XCTAssertFalse(element("standby.settings").exists)
    }

    func testEarlyReleaseKeepsEStopped() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        element("stop.release").press(forDuration: 0.3)
        XCTAssertTrue(element("stop.release").exists)
        XCTAssertFalse(element("standby.settings").exists)
    }

    func testHoldingReleaseForOneSecondReturnsToStandby() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        element("stop.release").press(forDuration: 1.3)
        expect("standby.settings")
        XCTAssertFalse(element("stop.release").exists)
    }

    func testDebugSheetIsReachableFromModePill() {
        expect("status.mode_pill")
        element("status.mode_pill").press(forDuration: 1.3)
        expect("standby.simulate_high_latency")
    }

    func testDebugSheetKeepsStopReachable() {
        expect("status.mode_pill")
        element("status.mode_pill").press(forDuration: 1.3)
        expect("standby.simulate_high_latency")
        expect("stop.debug")
        element("stop.debug").tap()
        expect("stop.release")
    }

    func testFallbackHoldAreaMovesWhilePressedAndStopsOnRelease() {
        app.terminate()
        app.launchArguments = ["-startRoute", "s5_fallback", "-startConnected", "YES"]
        app.launch()
        let pad = element("fallback.hold")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "fallback.hold").count, 1)
        XCTAssertEqual(pad.value as? String, "stopped")
        // press(forDuration:) pumps the run loop, so a main-queue block can sample the value mid-press.
        var duringPress: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            duringPress = pad.value as? String
        }
        pad.press(forDuration: 2.0)
        XCTAssertEqual(duringPress, "moving")
        XCTAssertEqual(pad.value as? String, "stopped")
    }

    private func relaunch(at route: String) {
        app.terminate()
        app.launchArguments = ["-startRoute", route, "-startConnected", "YES"]
        app.launch()
    }

    func testRecordingFallbackOffersHoldPadAndGripper() {
        relaunch(at: "s5a_fallback_recording")
        let pad = element("fallback.hold_recording")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "fallback.hold_recording").count, 1)
        XCTAssertEqual(pad.value as? String, "stopped")
        var duringPress: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            duringPress = pad.value as? String
        }
        pad.press(forDuration: 2.0)
        XCTAssertEqual(duringPress, "moving")
        XCTAssertEqual(pad.value as? String, "stopped")
        expect("fallback.toggle")
        XCTAssertTrue(element("fallback.toggle").isHittable)
    }

    func testTutorialLastStepHasNoSkip() {
        relaunch(at: "t3_tutorial")
        expect("tutorial.back")
        expect("tutorial.next")
        XCTAssertFalse(element("tutorial.skip").exists)
    }

    func testBaseHandleTapReleasesToStandby() {
        relaunch(at: "s3m_base")
        expect("base.release")
        element("base.release").tap()
        expect("standby.base")
    }

    func testCloudCheckTitleLongPressReachesFailScreen() {
        relaunch(at: "p2_cloud_pass")
        expect("cloud.title")
        XCTAssertEqual(element("cloud.primary").label, "Enter standby")
        element("cloud.title").press(forDuration: 1.5)
        XCTAssertTrue(app.staticTexts["No heartbeat from the robot"].waitForExistence(timeout: 5))
    }
}
