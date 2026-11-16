import XCTest

/// The aids' controls in Settings: on a page of their own, opened by the button beside Done and never part of the form,
/// with the master switch and lock's choices, each choice a row that shows its whole sentence, disabled while the
/// switch is off; and the tutorial's lines for the lock chosen, for the tap on the guide and for the guide's arrows.
/// Each value is reached by a launch that pins it, never by turning it in the app: a UI test cannot remove a saved
/// setting afterwards, and the other UI tests launch with neither of the aids' settings saved.
final class AssistSettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The button's words and lock's choices, in the order shown, in each language.
    private static let words: [String: (aids: String, lock: [String])] = [
        "en": ("Aids", ["Off", "Press, then press to stop", "Hold, then slide a thumb up"]),
        "zh-Hant": ("輔助", ["關", "按一下，再按一下就停", "按住，再用拇指往上滑"]),
    ]

    /// Lock's choices as a launch names them, in the order shown.
    private static let lockValues = ["off", "pressPress", "holdThenSlide"]

    private struct Height {
        var name: String
        var arguments: [String]
        /// The app's frame on the device: the whole screen, or the smaller test frame at the top left.
        var frame: CGRect?
    }

    private static let heights: [String: Height] = [
        "874": Height(name: "874", arguments: [], frame: nil),
        "667": Height(
            name: "667", arguments: ["-screenFrame", "375x667x20x0"], frame: CGRect(x: 0, y: 0, width: 375, height: 667)
        ),
    ]

    /// With Settings just opened none of the aids' controls is in the form, nor anywhere down to its last row. The
    /// button beside Done shows their page in the form's place, under the same header and above the same STOP band;
    /// the way back shows the form again; Done leaves Settings from the page; and Settings opens on the form again.
    func testTheAidsAreOnAPageOfTheirOwnNotInTheForm() {
        let app = openSettings(assist: "YES", lock: "pressPress")
        let button = app.element("settings.aids")
        XCTAssertTrue(button.isHittable, "the button beside Done")
        XCTAssertEqual(button.label, "Aids")
        XCTAssertLessThanOrEqual(
            button.frame.maxY, app.collectionViews.firstMatch.frame.minY + 1, "the button is above the form, not in it")
        expectNoAidsControl(app, "Settings just opened")
        let version = app.element("settings.version")
        scroll(app, until: version) { expectNoAidsControl(app, "the form scrolled") }
        XCTAssertTrue(version.isHittable, "the form's last row in view")
        expectNoAidsControl(app, "the form's last screenful")
        let band = app.element("stop").frame

        button.tap()
        expect(app, "settings.assist")
        XCTAssertEqual(app.element("settings.aids_title").label, "Aids")
        XCTAssertFalse(app.element("settings.version").exists, "the form is not shown with the page")
        XCTAssertFalse(app.element("settings.task_aid").exists, "the form is not shown with the page")
        XCTAssertEqual(app.element("stop").frame, band, "the STOP band as on the form")
        XCTAssertTrue(app.element("stop").isHittable, "the STOP band can be pressed")
        XCTAssertTrue(app.element("settings.done").isHittable, "Done on the page")
        attachScreenshot("settings-aids-page")

        app.element("settings.aids_back").tap()
        expect(app, "settings.task_aid")
        expectNoAidsControl(app, "back on the form")
        app.element("settings.aids").tap()
        expect(app, "settings.assist")
        app.element("settings.done").tap()
        expectLabel(app.element("operating.state"), "Ready")
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        expect(app, "settings.task_aid")
        expectNoAidsControl(app, "Settings opened again")
    }

    /// Each lock choice, from a launch that pins it, in each language, reached through the button: the switch is on,
    /// the chosen row is the one selected, and every choice's row has its whole sentence for its label and lies on
    /// the screen above the STOP band, at the test device's height and at the smaller phone's.
    func testEachLockChoiceIsReachedThroughTheButtonAndShownWhole() {
        let cases: [(lock: String, language: String, height: String)] = [
            ("off", "en", "874"), ("pressPress", "en", "667"), ("holdThenSlide", "en", "874"),
            ("off", "zh-Hant", "667"), ("pressPress", "zh-Hant", "874"), ("holdThenSlide", "zh-Hant", "667"),
        ]
        for one in cases {
            let what = "\(one.lock) \(one.language) \(one.height)"
            let height = Self.heights[one.height]!
            let app = openAidsPage(assist: "YES", lock: one.lock, language: one.language, height: height)
            expectValue(app.element("settings.assist"), "1", what)
            expectLockRows(
                app, chosen: one.lock, enabled: true, language: one.language, screen: height.frame, what: what)
            attachScreenshot("settings-aids-\(one.lock)-\(one.language)-\(one.height)")
            app.terminate()
        }
    }

    /// With the switch off, from a launch in each language, the button and the page are still there, since the
    /// switch is turned on there again; lock's choices show the one chosen and cannot be chosen.
    func testWithTheSwitchOffThePageStaysAndLockCannotBeChosen() {
        for (language, lock) in [("en", "pressPress"), ("zh-Hant", "holdThenSlide")] {
            let what = "switch off \(language)"
            let app = openAidsPage(assist: "NO", lock: lock, language: language, height: Self.heights["874"]!)
            let toggle = app.element("settings.assist")
            XCTAssertTrue(toggle.isHittable, "\(what): the switch")
            expectValue(toggle, "0", what)
            expectLockRows(app, chosen: lock, enabled: false, language: language, screen: nil, what: what)
            attachScreenshot("settings-aids-off-\(language)")
            app.terminate()
        }
    }

    /// The aids' page in both languages at both heights, with a screenshot each: nothing on it leaves the screen,
    /// runs into anything else or reaches the STOP band, which is where it is on the form and can be pressed.
    func testTheAidsPageLayout() {
        for height in [Self.heights["874"]!, Self.heights["667"]!] {
            for language in ["en", "zh-Hant"] {
                let what = "\(language) \(height.name)"
                let app = openSettings(
                    assist: "YES", lock: "pressPress", language: language, extra: height.arguments)
                let band = app.element("stop").frame
                app.element("settings.aids").tap()
                expect(app, "settings.assist")
                XCTAssertEqual(app.element("stop").frame, band, "\(what): the STOP band as on the form")
                XCTAssertTrue(app.element("stop").isHittable, "\(what): the STOP band can be pressed")
                attachScreenshot("settings-aids-layout-\(language)-\(height.name)")
                checkLayout(app, screen: height.frame ?? app.windows.firstMatch.frame, what: what)
                app.terminate()
            }
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
    private func openSettings(
        assist: String, lock: String, language: String = "en", extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication.teleop(
            ["-startRoute", "p4_standby", "-assist", assist, "-lockVariant", lock] + extra, language: language)
        app.launch()
        expectLabel(app.element("operating.state"), language == "en" ? "Ready" : "就緒", timeout: 8)
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        return app
    }

    /// The aids' page, reached through the button beside Done; the button's words and the page's title are checked on
    /// the way.
    private func openAidsPage(assist: String, lock: String, language: String, height: Height) -> XCUIApplication {
        let app = openSettings(assist: assist, lock: lock, language: language, extra: height.arguments)
        let aids = Self.words[language]!.aids
        let button = app.element("settings.aids")
        XCTAssertEqual(button.label, aids, "\(language): the button's words")
        button.tap()
        expect(app, "settings.assist")
        XCTAssertEqual(app.element("settings.aids_title").label, aids, "\(language): the page's title")
        return app
    }

    /// Lock's choices on the aids' page: one row per choice, in order, each labelled with its whole sentence and lying
    /// on the screen above the STOP band; the chosen one selected and the others not; all of them enabled, or none.
    private func expectLockRows(
        _ app: XCUIApplication, chosen: String, enabled: Bool, language: String, screen: CGRect?, what: String,
        line: UInt = #line
    ) {
        let rows = app.buttons.matching(identifier: "settings.lock")
        let sentences = Self.words[language]!.lock
        XCTAssertEqual(rows.count, sentences.count, "\(what): one row per choice", line: line)
        let screen = screen ?? app.windows.firstMatch.frame
        let bandTop = app.element("stop").frame.minY
        for (index, sentence) in sentences.enumerated() {
            let row = rows.element(boundBy: index)
            let name = "\(what), row \(index)"
            XCTAssertEqual(row.label, sentence, "\(name): the whole sentence", line: line)
            XCTAssertTrue(screen.contains(row.frame), "\(name) \(row.frame) leaves the screen \(screen)", line: line)
            XCTAssertLessThanOrEqual(row.frame.maxY, bandTop, "\(name) \(row.frame) reaches STOP", line: line)
            XCTAssertEqual(row.isEnabled, enabled, "\(name): can be chosen", line: line)
            XCTAssertEqual(row.isSelected, Self.lockValues[index] == chosen, "\(name): selected", line: line)
        }
    }

    /// None of the aids' controls, and none of their words, is on the screen. "Off" is left out: Smoothing's first
    /// step in the form says it too.
    private func expectNoAidsControl(_ app: XCUIApplication, _ what: String, line: UInt = #line) {
        let identifiers = ["settings.assist", "settings.lock", "settings.aids_back", "settings.aids_title"]
        let labels =
            [
                "Hands-free aids", "Lock",
                "Off turns lock, tap-to-go and the guide's extra cues off. Lock works in the phone modes.",
            ]
            + Self.words["en"]!.lock.dropFirst()
        let found = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@", identifiers, labels))
        XCTAssertEqual(found.count, 0, "\(what): \(found.allElementsBoundByIndex.map(\.label))", line: line)
    }

    /// Scrolls the form up 100 points at a time, with no fling, until `element` is in view, calling `each` before every
    /// step. The drag runs down the left margin, beside the rows, so it can land on no control.
    private func scroll(_ app: XCUIApplication, until element: XCUIElement, each: () -> Void = {}) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6))
        let to = from.withOffset(CGVector(dx: 0, dy: -100))
        for _ in 0..<20 where !(element.exists && element.isHittable) {
            each()
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func expectValue(_ element: XCUIElement, _ value: String, _ what: String, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(
            found, .completed, "\(what): \(element) is \(String(describing: element.value)), not \(value)",
            line: line)
    }

    private struct Seen {
        var label: String
        var identifier: String
        var frame: CGRect
        var type: XCUIElement.ElementType
        /// Where it sits in the hierarchy: the index of each element on the way down to it, its own last.
        var path: [Int]
    }

    private func flatten(_ snapshot: XCUIElementSnapshot, path: [Int] = [0]) -> [Seen] {
        let seen = Seen(
            label: snapshot.label, identifier: snapshot.identifier, frame: snapshot.frame,
            type: snapshot.elementType, path: path)
        return [seen] + snapshot.children.enumerated().flatMap { flatten($1, path: path + [$0]) }
    }

    /// Every text, button, switch and picture on the screen lies inside it and above the STOP band (or in the band,
    /// as its own words), and runs into no other, unless one holds the other, as a control holds its own words.
    private func checkLayout(_ app: XCUIApplication, screen: CGRect, what: String, line: UInt = #line) {
        guard let snapshot = try? app.snapshot() else {
            return XCTFail("no snapshot of \(what)", line: line)
        }
        let all = flatten(snapshot)
        guard let band = all.first(where: { $0.identifier == "stop" && $0.type == .button }) else {
            return XCTFail("\(what): no STOP band", line: line)
        }
        let kinds: [XCUIElement.ElementType] = [.staticText, .button, .switch, .image]
        let shown = all.filter { kinds.contains($0.type) && !$0.frame.isEmpty }
        let tolerance: CGFloat = 0.5
        for seen in shown {
            let name = "\(what): \(seen.type.rawValue) \"\(seen.label)\" \(seen.frame)"
            XCTAssertTrue(
                screen.insetBy(dx: -tolerance, dy: -tolerance).contains(seen.frame),
                "\(name) leaves the screen \(screen)",
                line: line)
            if !seen.path.starts(with: band.path) {
                XCTAssertLessThanOrEqual(
                    seen.frame.maxY, band.frame.minY + tolerance, "\(name) reaches the STOP band \(band.frame)",
                    line: line)
            }
        }
        for (index, a) in shown.enumerated() {
            for b in shown.dropFirst(index + 1) where !a.path.starts(with: b.path) && !b.path.starts(with: a.path) {
                let overlap = a.frame.intersection(b.frame)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) runs into \"\(b.label)\" \(b.frame)", line: line)
            }
        }
    }
}
