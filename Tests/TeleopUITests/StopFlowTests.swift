import XCTest

final class StopFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", "p4_standby"]
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

    func testFallbackHoldAreaMovesWhilePressedAndStopsOnRelease() {
        app.terminate()
        app.launchArguments = ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", "s5_fallback", "-startConnected", "YES"]
        app.launch()
        let pad = element("fallback.hold")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "fallback.hold").count, 1)
        XCTAssertEqual(pad.value as? String, "stopped")
        XCTAssertTrue(pad.valuesDuringPress().contains("moving"))
        XCTAssertEqual(pad.value as? String, "stopped")
    }

    private func relaunch(at route: String) {
        app.terminate()
        app.launchArguments = ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", route, "-startConnected", "YES"]
        app.launch()
    }

    func testFallbackGripperButtonsMoveOnlyWhilePressed() {
        relaunch(at: "s5_fallback")
        for id in ["gripper.close", "gripper.open"] {
            let button = element(id)
            XCTAssertTrue(button.waitForExistence(timeout: 5), id)
            XCTAssertEqual(button.value as? String, "stopped", id)
            XCTAssertTrue(button.valuesDuringPress().contains("moving"), id)
            XCTAssertEqual(button.value as? String, "stopped", id)
        }
    }

    func testStandbyOffersTheOpenHandle() {
        relaunch(at: "p4_standby")
        let handle = element("gripper.open")
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertTrue(handle.isHittable)
        XCTAssertTrue(handle.valuesDuringPress().contains("moving"))
        XCTAssertEqual(handle.value as? String, "stopped")
    }

    func testStandbyOffersTheJawTurnHandles() {
        relaunch(at: "p4_standby")
        for id in ["jaw.turn_positive", "jaw.turn_negative"] {
            let handle = element(id)
            XCTAssertTrue(handle.waitForExistence(timeout: 5), id)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: id).count, 1, id)
            XCTAssertTrue(handle.isHittable, id)
            XCTAssertGreaterThanOrEqual(handle.frame.height, 48, id)
            XCTAssertEqual(handle.value as? String, "stopped", id)
            XCTAssertTrue(handle.valuesDuringPress().contains("moving"), id)
            XCTAssertEqual(handle.value as? String, "stopped", id)
        }
        XCTAssertTrue(element("gripper.open").isHittable, "the open handle must stay reachable")
    }

    func testTutorialLastStepHasNoSkip() {
        relaunch(at: "t3_tutorial")
        expect("tutorial.back")
        expect("tutorial.next")
        XCTAssertFalse(element("tutorial.skip").exists)
    }

    func testCloudCheckTitleLongPressReachesFailScreen() {
        relaunch(at: "p2_cloud_pass")
        expect("cloud.title")
        XCTAssertEqual(element("cloud.primary").label, "Enter standby")
        element("cloud.title").press(forDuration: 1.5)
        XCTAssertTrue(app.staticTexts["No heartbeat from the robot"].waitForExistence(timeout: 5))
    }
}
