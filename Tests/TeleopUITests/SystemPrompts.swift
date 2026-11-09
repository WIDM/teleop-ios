import XCTest

extension XCTestCase {
    /// Answers system permission alerts until none is left, and returns how many there were.
    /// Buttons are found by identifier because their text follows the device language.
    @discardableResult
    func answerSystemPrompts(allow: Bool) -> Int {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        let suffix = allow ? "-allow-button" : "-deny-button"
        var answered = 0
        while answered < 3, alert.waitForExistence(timeout: 3) {
            let id = alert.identifier
            alert.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", suffix)).firstMatch.tap()
            XCTAssertTrue(springboard.alerts[id].waitForNonExistence(timeout: 5))
            answered += 1
        }
        return answered
    }
}
