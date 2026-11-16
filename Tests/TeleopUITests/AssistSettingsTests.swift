import XCTest

/// The aids' section in Settings: right after the Task aid section, above Recording, with the master switch and the
/// lock row below it, which shows the lock chosen and is disabled while the switch is off; and the tutorial's lines for
/// the lock chosen, for the tap on the guide and for the guide's arrows. Each value is reached by a launch that pins
/// it, never by turning it in the app: a UI test cannot remove a saved setting afterwards, and the other UI tests
/// launch with neither of the aids' settings saved.
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

    /// The tutorial's last page says a tap on the guide's view from above sends the jaws there, in the phone modes with
    /// the switch on and the task aid on, in both languages, and the page scrolls to the whole line; with the switch
    /// off, with the task aid off (no guide is drawn to tap) or in buttons mode it has no such line.
    func testTheTutorialTeachesTheTap() {
        // The app reads the task aid as a saved Bool, which a launch argument gives only in property-list form; a
        // plain NO would be read as no saved value, which is on.
        let cases: [(assist: String, mode: String, taskAid: String, language: String, line: String?)] = [
            ("YES", "screenTurns", "YES", "en", "Tap the view from above to send the jaws there."),
            ("YES", "keyTurns", "YES", "zh-Hant", "點一下「從上面看」的圖，夾爪就會移到那裡。"),
            ("NO", "screenTurns", "YES", "en", nil),
            ("YES", "buttons", "YES", "en", nil),
            ("YES", "screenTurns", "<false/>", "en", nil),
        ]
        for one in cases {
            let what = "\(one.assist) \(one.mode) task aid \(one.taskAid) \(one.language)"
            let app = XCUIApplication.teleop(
                [
                    "-startRoute", "t3_tutorial", "-assist", one.assist, "-lockVariant", "off", "-controlMode",
                    one.mode, "-taskAid", one.taskAid,
                ], language: one.language)
            app.launch()
            expect(app, "tutorial.title")
            let tapLines = app.staticTexts.containing(
                NSPredicate(format: "label BEGINSWITH 'Tap the view from above' OR label BEGINSWITH '點一下「從上面看」'"))
            if let line = one.line {
                let shown = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", line)).firstMatch
                XCTAssertTrue(shown.waitForExistence(timeout: 5), "\(what): the tap line")
                XCTAssertEqual(tapLines.count, 1, what)
                let page = app.scrollViews.firstMatch
                let inView = { shown.frame.minY >= page.frame.minY && shown.frame.maxY <= page.frame.maxY }
                scrollPage(page, until: inView)
                XCTAssertTrue(inView(), "\(what): the whole line in view, \(shown.frame) in \(page.frame)")
                attachScreenshot("tutorial-tap-\(one.mode)-\(one.language)")
            } else {
                XCTAssertEqual(tapLines.count, 0, "\(what): no tap line")
            }
            app.terminate()
        }
    }

    /// The tutorial's line about the guide also says that the guide's Forward and Up arrows are true for the picture,
    /// not for the hand, when the aids draw them, in both languages; at the smaller phone's height the page scrolls to
    /// the whole line, as it does to its last lines. With the switch off the guide has no arrows, and with the task aid
    /// off or in buttons mode no guide is drawn: the line then says only what the on-target cue means.
    func testTheTutorialSaysTheGuidesArrowsAreThePictures() {
        let cases: [(language: String, sentence: String)] = [
            ("en", "The guide's Forward and Up arrows are true for the picture, not for your hand."),
            ("zh-Hant", "導引圖上「前」和「上」的箭頭是畫面裡的方向，不是你手的方向。"),
        ]
        let heights: [(name: String, arguments: [String])] = [
            ("874", []), ("667", ["-screenFrame", "375x667x20x0"]),
        ]
        for height in heights {
            for one in cases {
                let what = "\(one.language) at \(height.name)"
                let app = XCUIApplication.teleop(
                    ["-startRoute", "t3_tutorial", "-assist", "YES", "-lockVariant", "off"] + height.arguments,
                    language: one.language)
                app.launch()
                expect(app, "tutorial.title")
                let line = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", one.sentence)).firstMatch
                XCTAssertTrue(line.waitForExistence(timeout: 5), "\(what): the guide's line says it")
                let page = app.scrollViews.firstMatch
                let inView = { line.frame.minY >= page.frame.minY && line.frame.maxY <= page.frame.maxY }
                scrollPage(page, until: inView)
                XCTAssertTrue(inView(), "\(what): the whole line in view, \(line.frame) in \(page.frame)")
                XCTAssertTrue(app.element("tutorial.next").isHittable, "\(what): the buttons stay")
                attachScreenshot("tutorial-arrows-\(one.language)-\(height.name)")
                app.terminate()
            }
        }
        let onTargetOnly =
            "When the guide shows a target, a tick and then a soft buzz mean the jaws are on it. Let go, then close."
        // The task aid is read as a saved Bool, which a launch argument gives only in property-list form.
        let noArrows: [(what: String, arguments: [String])] = [
            ("switch off", ["-assist", "NO"]),
            ("task aid off", ["-assist", "YES", "-taskAid", "<false/>"]),
            ("buttons mode", ["-assist", "YES", "-controlMode", "buttons"]),
        ]
        for one in noArrows {
            let app = XCUIApplication.teleop(["-startRoute", "t3_tutorial", "-lockVariant", "off"] + one.arguments)
            app.launch()
            expect(app, "tutorial.title")
            let line = app.staticTexts.containing(
                NSPredicate(format: "label BEGINSWITH 'When the guide shows a target'")
            ).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 5), "\(one.what): the guide's line")
            XCTAssertEqual(line.label, onTargetOnly, "\(one.what): nothing about arrows")
            app.terminate()
        }
    }

    /// Scrolls `page` up 100 points at a time, with no fling, until `done`.
    private func scrollPage(_ page: XCUIElement, until done: () -> Bool) {
        let from = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let to = from.withOffset(CGVector(dx: 0, dy: -100))
        for _ in 0..<10 where !done() {
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
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

    /// The choice the picker's row shows: its value when it has one, else the end of its label, which names the choice
    /// after the row's own name ("Lock, Off" here). The separator differs between languages, and a system may expose
    /// the choice as the value instead, so neither is assumed.
    private func expectChoice(_ picker: XCUIElement, _ choice: String, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return Self.shows(value: element.value, label: element.label, choice)
        }
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: picker)], timeout: 5)
        let value = String(describing: picker.value)
        XCTAssertEqual(
            found, .completed, "\(picker) has value \(value) and label \(picker.label), not the choice \(choice)",
            line: line)
    }

    private static func shows(value: Any?, label: String, _ choice: String) -> Bool {
        if let value = value as? String, !value.isEmpty { return value == choice }
        return label.hasSuffix(choice) && label.count > choice.count
    }

    private func expectValue(_ element: XCUIElement, _ value: String, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(
            found, .completed, "\(element) is \(String(describing: element.value)), not \(value)", line: line)
    }
}
