import XCTest

/// The first-run permission prompt, as far as XCUITest can go.
final class ManualCheckTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expect(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
    }

    private func openS2WithCameraUnanswered() {
        app.resetAuthorizationStatus(for: .camera)
        app.launchArguments = XCUIApplication.quiet + ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", "s2_permissions"]
        app.launch()
        expect("permissions.continue")
    }

    /// Continue opens the system permission prompt, then the tutorial.
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
}
