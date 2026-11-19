import UIKit
import XCTest

/// The aids' controls in Settings: on a page of their own, opened by the button beside Done and never part of the form,
/// with the master switch and what Off turns off under it, then lock's choices under their own header and where lock
/// works under them. Each choice is a row of its own that shows its whole sentence, the chosen one marked and selected,
/// all of them disabled while the switch is off; Settings opens on its form every time. And the tutorial's lines for
/// the lock chosen, for the tap on the guide and for the guide's arrows. Each value is reached by a launch that pins
/// it, never by turning it in the app: a UI test cannot remove a saved setting afterwards, and the other UI tests
/// launch with neither of the aids' settings saved.
final class AssistSettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The page's words in one language.
    private struct Words {
        /// The button beside Done, and the page's title.
        var aids: String
        /// The way back to the form, as VoiceOver says it.
        var back: String
        /// The header of lock's choices.
        var lock: String
        /// Lock's choices, in the order shown.
        var choices: [String]
        /// Under the switch: what Off turns off.
        var switchHelp: String
        /// Under lock's choices: where lock works.
        var lockHelp: String
    }

    private static let words: [String: Words] = [
        "en": Words(
            aids: "Aids", back: "Back to Settings", lock: "Lock",
            choices: ["Off", "Press, then press to stop", "Hold, then slide a thumb up"],
            switchHelp: "Off turns lock, tap-to-go and the guide's extra cues off.",
            lockHelp: "Lock works in the phone modes."),
        "zh-Hant": Words(
            aids: "輔助", back: "回到設定", lock: "鎖定",
            choices: ["關", "按一下，再按一下就停", "按住，再用拇指往上滑"],
            switchHelp: "關閉時，鎖定、點選前往和導引圖的額外提示都會關閉。",
            lockHelp: "鎖定只在螢幕轉腕和按鍵轉腕模式有效。"),
    ]

    /// Lock's choices as a launch names them, and the identifier of each one's row, in the order shown.
    private static let choices: [(value: String, identifier: String)] = [
        ("off", "settings.lock.off"), ("pressPress", "settings.lock.press_press"),
        ("holdThenSlide", "settings.lock.hold_slide"),
    ]

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
    /// the way back, which VoiceOver calls the way back to Settings, shows the form again; Done leaves Settings from
    /// the page; and Settings opens on the form again.
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
        XCTAssertEqual(app.element("settings.aids_back").label, "Back to Settings", "the way back, to VoiceOver")
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
        expectLabel(app.element("operating.state"), "Available")
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        expect(app, "settings.task_aid")
        expectNoAidsControl(app, "Settings opened again")
    }

    /// A STOP pressed while the aids' page shows leaves Settings for the stopped operating screen; Settings opened from
    /// there shows its form under the STOPPED band, not the page.
    func testAfterAStopOnTheAidsPageSettingsOpensOnTheForm() {
        let app = openAidsPage(assist: "YES", lock: "pressPress", language: "en", height: Self.heights["874"]!)
        app.element("stop").tap()
        expectLabel(app.element("operating.state"), "STOPPED")
        app.element("operating.gear").tap()
        expect(app, "settings.stopped")
        expect(app, "settings.aids")
        XCTAssertTrue(app.staticTexts["Mode"].exists, "the form's first row")
        XCTAssertFalse(app.element("settings.assist").exists, "the aids' page is not shown")
        XCTAssertFalse(app.element("settings.aids_back").exists, "the aids' page is not shown")
        attachScreenshot("settings-after-stop-on-the-aids-page")
    }

    /// Each lock choice, from a launch that pins it, in each language, reached through the button: the switch is on;
    /// each choice is found by its own identifier, under lock's header and labelled with its whole sentence; the chosen
    /// one alone carries the selected trait and shows the mark; and no choice's sentence is cut, read from the row's
    /// pixels, at the test device's height and at the smaller phone's.
    func testTheChosenLockIsSelectedAndMarkedAndNoChoiceIsCut() {
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

    /// The aids' page in both languages at both heights, with a screenshot each: what Off turns off is under the
    /// switch, above lock's header, and where lock works is under lock's last choice; nothing on the page leaves the
    /// screen, runs into anything else or reaches the STOP band, which is where it is on the form and can be pressed.
    func testTheAidsPageLayoutWithEachExplanationUnderItsSection() {
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
                expectExplanations(app, language: language, what: what)
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
        expectLabel(app.element("operating.state"), language == "en" ? "Available" : "可操作", timeout: 8)
        app.element("operating.gear").tap()
        expect(app, "settings.done")
        return app
    }

    /// The aids' page, reached through the button beside Done; the button's words, the page's title and what VoiceOver
    /// calls the way back are checked on the way.
    private func openAidsPage(assist: String, lock: String, language: String, height: Height) -> XCUIApplication {
        let app = openSettings(assist: assist, lock: lock, language: language, extra: height.arguments)
        let words = Self.words[language]!
        let button = app.element("settings.aids")
        XCTAssertEqual(button.label, words.aids, "\(language): the button's words")
        button.tap()
        expect(app, "settings.assist")
        XCTAssertEqual(app.element("settings.aids_title").label, words.aids, "\(language): the page's title")
        XCTAssertEqual(app.element("settings.aids_back").label, words.back, "\(language): the way back, to VoiceOver")
        return app
    }

    /// Lock's choices on the aids' page: under lock's header, which is no choice itself and lies in no row, one row
    /// per choice in order, each found by its identifier, labelled with its whole sentence and lying on the screen
    /// above the STOP band; the chosen one selected and the others not; all of them enabled, or none. Then their
    /// pixels: no sentence is cut, and the chosen row alone shows the mark.
    private func expectLockRows(
        _ app: XCUIApplication, chosen: String, enabled: Bool, language: String, screen: CGRect?, what: String,
        line: UInt = #line
    ) {
        let words = Self.words[language]!
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", words.lock)).firstMatch
        XCTAssertTrue(header.exists, "\(what): lock's header", line: line)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label ==[c] %@", words.lock)).count, 0,
            "\(what): lock's header is not a choice", line: line)
        // A row that only says the word would read as a fourth choice: the word is the section's header, drawn on the
        // page's background, where each choice is drawn on a row of its own.
        expectOnThePagesBackground(
            header, notOn: app.buttons[Self.choices[0].identifier], what: "\(what), \(words.lock)", line: line)
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.lock'"))
        XCTAssertEqual(choices.count, Self.choices.count, "\(what): one row per choice", line: line)
        let screen = screen ?? app.windows.firstMatch.frame
        let bandTop = app.element("stop").frame.minY
        var above = header.frame.maxY
        for (index, choice) in Self.choices.enumerated() {
            let row = app.buttons[choice.identifier]
            let name = "\(what), \(choice.identifier)"
            XCTAssertTrue(row.exists, "\(name): its row", line: line)
            XCTAssertEqual(row.label, words.choices[index], "\(name): its sentence", line: line)
            XCTAssertGreaterThanOrEqual(row.frame.minY, above - 0.5, "\(name) \(row.frame): in order", line: line)
            XCTAssertTrue(screen.contains(row.frame), "\(name) \(row.frame) leaves the screen \(screen)", line: line)
            XCTAssertLessThanOrEqual(row.frame.maxY, bandTop + 0.5, "\(name) \(row.frame) reaches STOP", line: line)
            XCTAssertEqual(row.isEnabled, enabled, "\(name): can be chosen", line: line)
            XCTAssertEqual(row.isSelected, choice.value == chosen, "\(name): selected", line: line)
            above = row.frame.maxY
        }
        let rows = Self.choices.map { app.buttons[$0.identifier].frame }
        let marked = Self.choices.map { $0.value == chosen }
        expectDrawnWhole(rows: rows, sentences: words.choices, marked: marked, what: what, line: line)
    }

    /// `element` is drawn on the page's background and not on a row: read at the middle of its frame's top edge, the
    /// screenshot shows the colour of the page's margin beside it, and not the colour `row` shows at the middle of its
    /// own top edge. The screenshot is taken again until both hold, as the page may still be drawing.
    private func expectOnThePagesBackground(_ element: XCUIElement, notOn row: XCUIElement, what: String, line: UInt) {
        let frame = element.frame
        let rowFrame = row.frame
        let same = { (a: (r: Int, g: Int, b: Int), b: (r: Int, g: Int, b: Int)) -> Bool in
            max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) <= 4
        }
        var seen: (behind: (r: Int, g: Int, b: Int), page: (r: Int, g: Int, b: Int), row: (r: Int, g: Int, b: Int))
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let picture = Picture(XCUIScreen.main.screenshot().image)
            seen = (
                picture.colour(at: CGPoint(x: frame.midX, y: frame.minY + 2)),
                picture.colour(at: CGPoint(x: frame.minX / 2, y: frame.midY)),
                picture.colour(at: CGPoint(x: rowFrame.midX, y: rowFrame.minY + 2))
            )
        } while !(same(seen.behind, seen.page) && !same(seen.behind, seen.row)) && Date() < deadline
        XCTAssertTrue(
            same(seen.behind, seen.page), "\(what) \(frame): drawn on \(seen.behind), the page is \(seen.page)",
            line: line)
        XCTAssertFalse(
            same(seen.behind, seen.row), "\(what) \(frame): drawn on \(seen.behind), as a row is", line: line)
    }

    /// How far a row's drawing reaches, read from a screenshot: the runs of inked columns across it.
    private struct RowInk {
        var runs: [(from: CGFloat, to: CGFloat)]
        /// The first run, the sentence.
        var sentence: CGFloat { runs.first.map { $0.to - $0.from } ?? 0 }
    }

    /// Wider than any gap between two words or after a full-width comma, narrower than the room between a sentence
    /// and the mark at the row's end.
    private static let wordGap: CGFloat = 24

    /// Each row's sentence is drawn whole: on one line, its ink reaches as far as the sentence is wide in the body
    /// font, which the rows use, as this process measures it, give or take the blank edges of its first and last
    /// letters. A sentence cut short, or ended with an ellipsis, reaches less far. After the sentence the chosen row
    /// shows the mark, and the others nothing. The screenshot is taken again until all hold, as the page may still be
    /// drawing.
    private func expectDrawnWhole(
        rows: [CGRect], sentences: [String], marked: [Bool], what: String, line: UInt
    ) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let widths = sentences.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let holds = { (ink: RowInk, index: Int) -> Bool in
            ink.runs.count == (marked[index] ? 2 : 1) && ink.sentence >= widths[index] - Self.edges
                && ink.sentence <= widths[index] + 1
        }
        var seen: [RowInk] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let picture = Picture(XCUIScreen.main.screenshot().image)
            seen = rows.map { RowInk(runs: picture.inkRuns(in: $0, gap: Self.wordGap)) }
        } while !seen.indices.allSatisfy({ holds(seen[$0], $0) }) && Date() < deadline
        for (index, ink) in seen.enumerated() {
            let name = "\(what), \"\(sentences[index])\" in \(rows[index])"
            XCTAssertEqual(
                ink.runs.count, marked[index] ? 2 : 1,
                "\(name): the sentence, then the mark only if chosen: \(ink.runs)", line: line)
            XCTAssertGreaterThanOrEqual(
                ink.sentence, widths[index] - Self.edges,
                "\(name): drawn \(ink.sentence) pt wide, the sentence is \(widths[index]) pt: cut", line: line)
            XCTAssertLessThanOrEqual(
                ink.sentence, widths[index] + 1,
                "\(name): drawn \(ink.sentence) pt wide, the sentence is \(widths[index]) pt: more than the sentence",
                line: line)
        }
    }

    /// The most the blank edges of a sentence's first and last letters take from its measured width.
    private static let edges: CGFloat = 4

    /// Under the switch, above lock's header, what Off turns off; under lock's last choice, where lock works. Each
    /// lies on the screen above the STOP band.
    private func expectExplanations(_ app: XCUIApplication, language: String, what: String, line: UInt = #line) {
        let words = Self.words[language]!
        let switchHelp = app.staticTexts[words.switchHelp]
        let lockHelp = app.staticTexts[words.lockHelp]
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", words.lock)).firstMatch
        XCTAssertTrue(switchHelp.exists, "\(what): what Off turns off", line: line)
        XCTAssertTrue(lockHelp.exists, "\(what): where lock works", line: line)
        XCTAssertTrue(header.exists, "\(what): lock's header", line: line)
        let toggle = app.element("settings.assist").frame
        let last = app.buttons[Self.choices.last!.identifier].frame
        let bandTop = app.element("stop").frame.minY
        // Neighbouring frames meet to within a rounding.
        XCTAssertGreaterThanOrEqual(
            switchHelp.frame.minY, toggle.maxY - 0.5, "\(what): \(switchHelp.frame) under the switch \(toggle)",
            line: line)
        XCTAssertLessThanOrEqual(
            switchHelp.frame.maxY, header.frame.minY + 0.5,
            "\(what): \(switchHelp.frame) above lock's header \(header.frame)", line: line)
        XCTAssertGreaterThanOrEqual(
            lockHelp.frame.minY, last.maxY - 0.5, "\(what): \(lockHelp.frame) under the last choice \(last)",
            line: line)
        XCTAssertLessThanOrEqual(
            lockHelp.frame.maxY, bandTop + 0.5, "\(what): \(lockHelp.frame) reaches STOP", line: line)
    }

    /// None of the aids' controls, and none of their words, is on the screen. "Off" is left out: Smoothing's first
    /// step in the form says it too.
    private func expectNoAidsControl(_ app: XCUIApplication, _ what: String, line: UInt = #line) {
        let words = Self.words["en"]!
        let identifiers =
            ["settings.assist", "settings.aids_back", "settings.aids_title"] + Self.choices.map(\.identifier)
        let labels = ["Hands-free aids", words.switchHelp, words.lockHelp] + words.choices.dropFirst()
        let found = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@ OR label ==[c] %@", identifiers, labels, words.lock))
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

extension Picture {
    /// The runs of inked columns across `rect`, in points, left to right. A column is inked where a pixel in it, away
    /// from the rect's top and bottom edges, differs clearly from the background, read at the middle of its top edge;
    /// a gap of more than `gap` points between inked columns starts a new run.
    fileprivate func inkRuns(in rect: CGRect, gap: CGFloat) -> [(from: CGFloat, to: CGFloat)] {
        let background = pixel(column: Int(rect.midX * scale), row: Int((rect.minY + 2) * scale))
        let rows = Int((rect.minY + 4) * scale)..<Int((rect.maxY - 4) * scale)
        let columns = Int((rect.minX + 2) * scale)..<Int((rect.maxX - 2) * scale)
        var runs: [(from: CGFloat, to: CGFloat)] = []
        var first: Int?
        var last = 0
        for column in columns {
            let inked = rows.contains { row in
                let seen = pixel(column: column, row: row)
                return max(abs(seen.r - background.r), abs(seen.g - background.g), abs(seen.b - background.b)) > 64
            }
            guard inked else { continue }
            if let start = first, CGFloat(column - last - 1) / scale > gap {
                runs.append((CGFloat(start) / scale, CGFloat(last + 1) / scale))
                first = column
            } else if first == nil {
                first = column
            }
            last = column
        }
        if let start = first { runs.append((CGFloat(start) / scale, CGFloat(last + 1) / scale)) }
        return runs
    }

    /// The colour at `point`, in points.
    fileprivate func colour(at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        pixel(column: Int(point.x * scale), row: Int(point.y * scale))
    }

    private func pixel(column: Int, row: Int) -> (r: Int, g: Int, b: Int) {
        let x = min(max(column, 0), width - 1)
        let y = min(max(row, 0), height - 1)
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}
