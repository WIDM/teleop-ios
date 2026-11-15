import XCTest

/// The aids' section in Settings: right after the Task aid section, above Recording, with the master switch. Each value
/// of the switch is reached by a launch that pins it, never by turning it in the app: a UI test cannot remove a saved
/// setting afterwards, and the other UI tests launch with neither of the aids' settings saved.
final class AssistSettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheAidsSectionFollowsTheTaskAidAndHoldsTheSwitch() {
        let app = openSettings(assist: "YES")
        let taskAid = app.element("settings.task_aid")
        let assist = app.element("settings.assist")
        let recording = app.element("settings.rec_status")
        scroll(app, until: recording)
        XCTAssertTrue(recording.isHittable, "Recording in view")
        XCTAssertTrue(assist.exists, "the switch in view with Recording")
        XCTAssertTrue(taskAid.exists, "the task aid in view with Recording")
        XCTAssertGreaterThan(assist.frame.minY, taskAid.frame.maxY, "after the task aid")
        XCTAssertLessThan(assist.frame.maxY, recording.frame.minY, "before Recording")
        XCTAssertTrue(app.staticTexts["Hands-free aids"].exists)
        expectValue(assist, "1")
        attachScreenshot("settings-aids-on")
        app.terminate()

        // The other value, from a second launch: nothing in the app is turned.
        let off = openSettings(assist: "NO")
        let switchedOff = off.element("settings.assist")
        scroll(off, until: switchedOff)
        XCTAssertTrue(switchedOff.isHittable, "the switch in view")
        expectValue(switchedOff, "0")
        attachScreenshot("settings-aids-off")
    }

    /// Settings, opened from the operating screen, with the aids' two settings pinned for this launch.
    private func openSettings(assist: String) -> XCUIApplication {
        let app = XCUIApplication.teleop(["-startRoute", "p4_standby", "-assist", assist, "-lockVariant", "off"])
        app.launch()
        expectLabel(app.element("operating.state"), "Ready")
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        return app
    }

    /// Scrolls the form up 100 points at a time, with no fling, until `element` is in view. The drag runs down the
    /// left margin, beside the rows, so it can land on no control.
    private func scroll(_ app: XCUIApplication, until element: XCUIElement) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6))
        let to = from.withOffset(CGVector(dx: 0, dy: -100))
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func expectValue(_ element: XCUIElement, _ value: String, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(
            found, .completed, "\(element) is \(String(describing: element.value)), not \(value)", line: line)
    }
}
