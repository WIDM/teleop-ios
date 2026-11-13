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
            let prompt = springboard.alerts[id]
            // A prompt that is still sliding in ignores a tap. A tap that did not take is made again, as a person
            // would make it.
            var taps = 0
            while prompt.exists, taps < 3 {
                let named = prompt.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", suffix)).firstMatch
                if named.exists {
                    named.tap()
                } else {
                    XCTAssertEqual(prompt.buttons.count, 2, "cannot tell the buttons apart by place")
                    prompt.buttons.element(boundBy: allow ? 1 : 0).tap()
                }
                taps += 1
                if prompt.waitForNonExistence(timeout: 3) { break }
            }
            XCTAssertFalse(prompt.exists, "the prompt \"\(id)\" stayed up after \(taps) taps")
            answered += 1
        }
        return answered
    }
}
