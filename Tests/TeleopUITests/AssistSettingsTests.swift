import XCTest

/// The aids' section in Settings: right after the Task aid section, above Recording, with the master switch and the
/// lock row below it, which shows the lock chosen and is disabled while the switch is off; and the tutorial's line for
/// the lock chosen. Each value is reached by a launch that pins it, never by turning it in the app: a UI test cannot
/// remove a saved setting afterwards, and the other UI tests launch with neither of the aids' settings saved.
final class AssistSettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheAidsSectionFollowsTheTaskAidAndHoldsTheSwitch() {
        let app = openSettings(assist: "YES", lock: "off")
        let taskAid = app.element("settings.task_aid")
        let assist = app.element("settings.assist")
        let lock = app.element("settings.lock")
        let recording = app.element("settings.rec_status")
        scroll(app, until: recording)
        XCTAssertTrue(recording.isHittable, "Recording in view")
        XCTAssertTrue(assist.exists, "the switch in view with Recording")
        XCTAssertTrue(lock.exists, "the lock row in view with Recording")
        XCTAssertTrue(taskAid.exists, "the task aid in view with Recording")
        XCTAssertGreaterThan(assist.frame.minY, taskAid.frame.maxY, "after the task aid")
        XCTAssertGreaterThanOrEqual(lock.frame.minY, assist.frame.maxY - 1, "the lock row under the switch")
        XCTAssertLessThan(lock.frame.maxY, recording.frame.minY, "before Recording")
        XCTAssertTrue(app.staticTexts["Hands-free aids"].exists)
        expectValue(assist, "1")
        XCTAssertTrue(lock.isEnabled, "lock can be chosen while the switch is on")
        expectChoice(lock, "Off")
        attachScreenshot("settings-aids-on")
        app.terminate()

        // The other value, from a second launch: nothing in the app is turned.
        let off = openSettings(assist: "NO", lock: "off")
        let switchedOff = off.element("settings.assist")
        scroll(off, until: off.element("settings.lock"))
        XCTAssertTrue(switchedOff.isHittable, "the switch in view")
        expectValue(switchedOff, "0")
        XCTAssertFalse(off.element("settings.lock").isEnabled, "lock cannot be chosen while the switch is off")
        attachScreenshot("settings-aids-off")
    }

    /// Each lock choice, from a launch that pins it, is the one the row shows.
    func testTheLockRowShowsTheLockChosen() {
        let choices = [("pressPress", "Press, then press to stop"), ("holdThenSlide", "Hold, then slide a thumb up")]
        for (choice, shown) in choices {
            let app = openSettings(assist: "YES", lock: choice)
            let lock = app.element("settings.lock")
            scroll(app, until: lock)
            XCTAssertTrue(lock.isEnabled, choice)
            expectChoice(lock, shown)
            attachScreenshot("settings-lock-\(choice)")
            app.terminate()
        }
    }

    /// The tutorial's last page says how the chosen lock latches and stops, in the phone modes, in both languages; with
    /// no lock, with the switch off or in buttons mode it has no such line.
    func testTheTutorialTeachesTheLockChosen() {
        let cases: [(assist: String, lock: String, mode: String, language: String, line: String?)] = [
            ("YES", "pressPress", "screenTurns", "en", "Lock: a press of the upper key keeps the arm following."),
            ("YES", "holdThenSlide", "keyTurns", "zh-Hant", "鎖定：按住上面的音量鍵時，拇指在螢幕上往上滑。"),
            ("YES", "off", "screenTurns", "en", nil),
            ("NO", "pressPress", "screenTurns", "en", nil),
            ("YES", "pressPress", "buttons", "en", nil),
        ]
        for one in cases {
            let what = "\(one.assist) \(one.lock) \(one.mode) \(one.language)"
            let app = XCUIApplication.teleop(
                [
                    "-startRoute", "t3_tutorial", "-assist", one.assist, "-lockVariant", one.lock, "-controlMode",
                    one.mode,
                ], language: one.language)
            app.launch()
            expect(app, "tutorial.title")
            let lockLines = app.staticTexts.containing(
                NSPredicate(format: "label BEGINSWITH 'Lock:' OR label BEGINSWITH '鎖定：'"))
            if let line = one.line {
                let shown = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", line)).firstMatch
                XCTAssertTrue(shown.waitForExistence(timeout: 5), "\(what): the lock line")
                XCTAssertEqual(lockLines.count, 1, what)
                attachScreenshot("tutorial-lock-\(one.lock)-\(one.language)")
            } else {
                XCTAssertEqual(lockLines.count, 0, "\(what): no lock line")
            }
            app.terminate()
        }
    }

    /// Settings, opened from the operating screen, with the aids' two settings pinned for this launch.
    private func openSettings(assist: String, lock: String) -> XCUIApplication {
        let app = XCUIApplication.teleop(["-startRoute", "p4_standby", "-assist", assist, "-lockVariant", lock])
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

    /// The picker's row names the choice it shows after its own name ("Lock, Off").
    private func expectChoice(_ picker: XCUIElement, _ choice: String, line: UInt = #line) {
        let predicate = NSPredicate(format: "label ENDSWITH %@", ", " + choice)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: picker)], timeout: 5)
        XCTAssertEqual(found, .completed, "\(picker) reads \(picker.label), not the choice \(choice)", line: line)
    }

    private func expectValue(_ element: XCUIElement, _ value: String, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(
            found, .completed, "\(element) is \(String(describing: element.value)), not \(value)", line: line)
    }
}
