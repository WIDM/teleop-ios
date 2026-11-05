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

    func testFallbackHoldAreaAcceptsPress() {
        app.terminate()
        app.launchArguments = ["-startRoute", "s5_fallback"]
        app.launch()
        expect("fallback.hold")
        element("fallback.hold").press(forDuration: 0.5)
        expect("fallback.hold")
    }
}
