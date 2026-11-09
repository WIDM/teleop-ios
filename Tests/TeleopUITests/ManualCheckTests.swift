import XCTest

/// The hand checks run on a real iPhone, as far as XCUITest can go: it asserts which haptics the app
/// requests, not how they feel. Volume keys cannot be pressed from XCUITest, so they have no test here.
final class ManualCheckTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-startRoute", "p4_standby", "-startConnected", "YES", "-recordHaptics", "YES"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expect(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
    }

    private var haptics: [String] {
        let log = element("test.haptics").label.dropFirst("log:".count)
        return log.isEmpty ? [] : log.components(separatedBy: ",")
    }

    private func openDebugSheet() {
        expect("status.mode_pill")
        element("status.mode_pill").press(forDuration: 1.3)
    }

    private func simulateHighLatency() {
        openDebugSheet()
        expect("standby.simulate_high_latency")
        element("standby.simulate_high_latency").tap()
        expect("standby.blocked_banner")
    }

    private func openHoldPad() -> XCUIElement {
        openDebugSheet()
        expect("standby.fallback")
        element("standby.fallback").tap()
        expect("fallback.hold")
        return element("fallback.hold")
    }

    /// Reads the pad value one second into a two second press.
    private func valueDuringPress(of pad: XCUIElement) -> String? {
        var value: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { value = pad.value as? String }
        pad.press(forDuration: 2.0)
        return value
    }

    func testStopRequestsLongBuzz() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        XCTAssertEqual(haptics, ["emergencyLoop"])
    }

    func testEarlyReleaseKeepsLongBuzz() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        element("stop.release").press(forDuration: 0.3)
        XCTAssertTrue(element("stop.release").exists)
        XCTAssertEqual(haptics, ["emergencyLoop"])
    }

    func testFullReleaseCancelsLongBuzzThenOneShort() {
        expect("stop")
        element("stop").tap()
        expect("stop.release")
        element("stop.release").press(forDuration: 1.3)
        expect("standby.settings")
        XCTAssertEqual(haptics, ["emergencyLoop", "cancel", "stopReleased"])
    }

    func testHoldPadFromDebugSheetMovesWhilePressed() {
        let pad = openHoldPad()
        XCTAssertEqual(pad.value as? String, "stopped")
        XCTAssertEqual(valueDuringPress(of: pad), "moving")
        XCTAssertEqual(pad.value as? String, "stopped")
    }

    func testHighLatencyBlocksHoldPadWithThreeShort() {
        simulateHighLatency()
        let pad = openHoldPad()
        XCTAssertEqual(valueDuringPress(of: pad), "stopped")
        XCTAssertEqual(pad.value as? String, "stopped")
        XCTAssertEqual(haptics, ["commandBlocked"])
    }

    /// A real finger drifts while held. One press should give one cue.
    func testBlockedHoldWithMovingFingerBuzzesOnce() {
        simulateHighLatency()
        let pad = openHoldPad()
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.3, thenDragTo: end)
        XCTAssertEqual(haptics, ["commandBlocked"])
    }

    /// docs/figma-map.md S2: "Continue opens the system permission prompts."
    func testS2ContinueShowsCameraPromptThenTutorial() {
        openS2WithCameraUnanswered()
        element("permissions.continue").tap()
        XCTAssertGreaterThanOrEqual(answerSystemPrompts(allow: true), 1)
        expect("tutorial.skip")
    }

    func testDenyingPromptsStillReachesTutorial() {
        openS2WithCameraUnanswered()
        element("permissions.continue").tap()
        XCTAssertGreaterThanOrEqual(answerSystemPrompts(allow: false), 1)
        expect("tutorial.skip")
    }

    private func openS2WithCameraUnanswered() {
        app.resetAuthorizationStatus(for: .camera)
        app.launchArguments = ["-startRoute", "s2_permissions", "-startConnected", "YES"]
        app.launch()
        expect("permissions.continue")
    }

    // Spec gap found by hand on 2026-11-09. A strict expected failure: it turns red once the gap is fixed,
    // so the marker has to be removed then.

    /// docs/figma-map.md P6: "tap Reset scene -> P4."
    func testResetFromHighLatencyReturnsToStandby() {
        simulateHighLatency()
        app.buttons["Reset"].tap()
        XCTExpectFailure("The Reset button has no action.")
        XCTAssertTrue(element("standby.blocked_banner").waitForNonExistence(timeout: 3))
    }
}
