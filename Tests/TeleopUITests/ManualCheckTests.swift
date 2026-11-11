import XCTest

/// The hand checks run on a real iPhone, as far as XCUITest can go: it asserts which haptics the app
/// requests, not how they feel. Volume keys cannot be pressed from XCUITest, so they have no test here.
final class ManualCheckTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", "p4_standby", "-startConnected", "YES", "-recordHaptics", "YES"]
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

    /// Relaunches with commands blocked, as after two slow round trips on a live link.
    private func relaunchBlocked(at route: String = "p4_standby") {
        app.terminate()
        app.launchArguments = ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", route, "-startConnected", "YES", "-startBlocked", "YES", "-recordHaptics", "YES"]
        app.launch()
        expect("standby.blocked_banner")
    }

    private func openHoldPad() -> XCUIElement {
        expect("volume_hint")
        element("volume_hint").tap()
        expect("fallback.hold")
        return element("fallback.hold")
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

    func testHoldPadMovesWhilePressed() {
        let pad = openHoldPad()
        XCTAssertEqual(pad.value as? String, "stopped")
        XCTAssertTrue(pad.valuesDuringPress().contains("moving"))
        XCTAssertEqual(pad.value as? String, "stopped")
    }

    func testHighLatencyBlocksHoldPadWithThreeShort() {
        relaunchBlocked()
        let pad = openHoldPad()
        let values = pad.valuesDuringPress()
        XCTAssertFalse(values.isEmpty, "the pad was never read during the press")
        XCTAssertFalse(values.contains("moving"), "the pad moved although the hold was blocked")
        XCTAssertEqual(pad.value as? String, "stopped")
        XCTAssertEqual(haptics, ["commandBlocked"])
    }

    /// A real finger drifts while held. One press should give one cue.
    func testBlockedHoldWithMovingFingerBuzzesOnce() {
        relaunchBlocked()
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
        app.launchArguments = ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", "s2_permissions", "-startConnected", "YES"]
        app.launch()
        expect("permissions.continue")
    }

    /// docs/figma-map.md P6: "tap Reset scene -> P4."
    func testResetFromHighLatencyReturnsToStandby() {
        relaunchBlocked(at: "p6_high_latency")
        element("standby.reset").tap()
        XCTAssertTrue(element("standby.blocked_banner").waitForNonExistence(timeout: 3))
        expect("standby.settings")
    }
}
