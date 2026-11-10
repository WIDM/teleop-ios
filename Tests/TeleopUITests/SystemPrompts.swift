import XCTest

extension XCTestCase {
    /// Answers system permission alerts until none is left, and returns how many there were.
    /// Buttons are found by identifier because their text follows the device language. iOS 18 gives them
    /// none, so there the button is taken by place: a two-button prompt puts the refusal first.
    @discardableResult
    func answerSystemPrompts(allow: Bool) -> Int {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        let suffix = allow ? "-allow-button" : "-deny-button"
        var answered = 0
        while answered < 3, alert.waitForExistence(timeout: 3) {
            let id = alert.identifier.isEmpty ? alert.label : alert.identifier
            let named = alert.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", suffix)).firstMatch
            if named.exists {
                named.tap()
            } else {
                XCTAssertEqual(alert.buttons.count, 2, "cannot tell the buttons apart by place")
                alert.buttons.element(boundBy: allow ? 1 : 0).tap()
            }
            XCTAssertTrue(springboard.alerts[id].waitForNonExistence(timeout: 5))
            answered += 1
        }
        return answered
    }
}
