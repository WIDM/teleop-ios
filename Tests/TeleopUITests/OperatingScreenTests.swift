import XCTest

/// Every operating-screen fixture (one per state of §7.2 in version 1, in the phone modes and in buttons mode, with
/// and without task objects, recording and not, practice) renders in English and in Traditional Chinese, at the
/// test device's 874 pt and at 667 pt, with a screenshot attached. No text leaves the screen, runs into another,
/// or reaches the gap above STOP; the button pad's targets are at least 60 pt.
final class OperatingScreenTests: XCTestCase {
    /// The fixture, and the state word it shows in English and in Chinese.
    private static let words: [String: (en: String, zh: String)] = [
        "not_connected": ("Not connected", "未連線"),
        "connecting": ("Connecting", "連線中"),
        "ready": ("Ready", "就緒"),
        "ready_hotel": ("Ready", "就緒"),
        "moving": ("Moving", "移動中"),
        "moving_hotel": ("Moving", "移動中"),
        "moving_no_arm": ("Moving", "移動中"),
        "turning": ("Turning", "轉腕中"),
        "tilting_estimated": ("Tilting", "傾斜中"),
        "opening": ("Opening", "打開中"),
        "closing_gripped": ("Closing", "夾緊中"),
        "holding": ("Moving", "移動中"),
        "wait_saving": ("Wait", "請稍等"),
        "wait_resetting": ("Wait", "請稍等"),
        "camera_stopped": ("Camera stopped", "相機停了"),
        "refused": ("Hold the phone upright", "手機請拿直"),
        "slow_link": ("Slow link", "網路太慢"),
        "stopped": ("STOPPED", "已急停"),
        "stopped_release": ("STOPPED", "已急停"),
        "stopped_unknown_server": ("STOPPED", "已急停"),
        "link_lost": ("Link lost", "連線中斷"),
        "saved": ("Saved 13", "已存 13"),
        "rec_off_countdown": ("Ready", "就緒"),
        "outside": ("Ready", "就緒"),
        "approximate": ("Ready", "就緒"),
        "approximate_hotel": ("Moving", "移動中"),
        "practice_ready": ("Ready", "就緒"),
        "practice_stopped": ("STOPPED", "已急停"),
        "buttons_ready": ("Ready", "就緒"),
        "buttons_moving": ("Moving", "移動中"),
        "buttons_stopped": ("STOPPED", "已急停"),
        "buttons_practice": ("Ready", "就緒"),
    ]

    private struct Size {
        var name: String
        var arguments: [String]
        /// The app's frame on the device: the whole screen, or the smaller test frame at the top left.
        var frame: CGRect?
    }

    private static let sizes = [
        Size(name: "874", arguments: [], frame: nil),
        Size(
            name: "667", arguments: ["-screenFrame", "375x667x20x0"], frame: CGRect(x: 0, y: 0, width: 375, height: 667)
        ),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches the fixture in both languages and both sizes and checks each; returns the English 874 pt launch for
    /// the caller's own checks.
    @discardableResult
    private func render(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let word = Self.words[fixture]!
        var english: XCUIApplication!
        for size in Self.sizes.reversed() {
            for (language, expected) in [("zh-Hant", word.zh), ("en", word.en)] {
                let app = XCUIApplication.teleop(
                    ["-operatingFixture", fixture, "-startRoute", "p4_standby"] + size.arguments, language: language
                )
                app.launch()
                let state = app.element("operating.state")
                XCTAssertTrue(
                    state.waitForExistence(timeout: 8), "\(fixture) \(language) \(size.name)", file: file, line: line)
                XCTAssertEqual(state.label, expected, "\(fixture) \(language) \(size.name)", file: file, line: line)
                attachScreenshot("\(fixture)-\(language)-\(size.name)")
                checkLayout(
                    app, frame: size.frame ?? app.windows.firstMatch.frame, what: "\(fixture) \(language) \(size.name)",
                    file: file, line: line)
                if language == "en", size.frame == nil { english = app }
            }
        }
        return english
    }

    private struct Seen {
        var label: String
        var identifier: String
        var frame: CGRect
        var type: XCUIElement.ElementType
    }

    private func flatten(_ snapshot: XCUIElementSnapshot) -> [Seen] {
        [
            Seen(
                label: snapshot.label, identifier: snapshot.identifier, frame: snapshot.frame,
                type: snapshot.elementType)
        ]
            + snapshot.children.flatMap(flatten)
    }

    private func checkLayout(_ app: XCUIApplication, frame screen: CGRect, what: String, file: StaticString, line: UInt)
    {
        guard let snapshot = try? app.snapshot() else {
            return XCTFail("no snapshot of \(what)", file: file, line: line)
        }
        let all = flatten(snapshot)
        guard let stop = all.first(where: { $0.identifier == "operating.stop" })?.frame else {
            return XCTFail("\(what): no STOP band", file: file, line: line)
        }
        let gapTop = stop.minY - 16 * screen.height / 874
        // Controls draw their own words inside them.
        let controls =
            all.filter { $0.identifier.hasPrefix("buttons.") || $0.identifier == "stop.release" }.map(\.frame) + [stop]
        let texts = all.filter { seen in
            seen.type == .staticText && !seen.label.isEmpty && seen.identifier != "operating.stop"
                && !controls.contains { $0.insetBy(dx: -1, dy: -1).contains(seen.frame) }
        }
        let tolerance: CGFloat = 0.5
        for text in texts {
            XCTAssertTrue(
                screen.insetBy(dx: -tolerance, dy: -tolerance).contains(text.frame),
                "\(what): \"\(text.label)\" \(text.frame) leaves the screen \(screen)", file: file, line: line)
            XCTAssertLessThanOrEqual(
                text.frame.maxY, gapTop + tolerance,
                "\(what): \"\(text.label)\" \(text.frame) reaches the gap above STOP", file: file, line: line)
        }
        let panels = all.filter { $0.identifier == "guide.above" || $0.identifier == "guide.behind" }
        for panel in panels {
            // A guide squeezed to a sliver would still "exist".
            XCTAssertGreaterThanOrEqual(
                min(panel.frame.width, panel.frame.height), 40,
                "\(what): \(panel.identifier) \(panel.frame) is too small to read", file: file, line: line)
        }
        for (index, a) in texts.enumerated() {
            for b in texts.dropFirst(index + 1) {
                let overlap = a.frame.intersection(b.frame)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) runs into \"\(b.label)\" \(b.frame)", file: file, line: line)
            }
            for panel in panels {
                let overlap = a.frame.intersection(panel.frame)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) covers the guide \(panel.frame)", file: file, line: line)
            }
            for control in controls {
                let overlap = a.frame.intersection(control)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame) runs under a control \(control)", file: file, line: line)
            }
        }
        for control in all where control.identifier.hasPrefix("buttons.") && control.identifier != "buttons.speed" {
            XCTAssertGreaterThanOrEqual(
                min(control.frame.width, control.frame.height), 60 - tolerance,
                "\(what): \(control.identifier) \(control.frame) is under 60 pt", file: file, line: line)
            XCTAssertTrue(
                screen.contains(control.frame), "\(what): \(control.identifier) leaves the screen", file: file,
                line: line)
            XCTAssertLessThanOrEqual(
                control.frame.maxY, gapTop + tolerance, "\(what): \(control.identifier) reaches the gap", file: file,
                line: line)
        }
    }

    private func exists(_ app: XCUIApplication, _ id: String) -> Bool { app.element(id).exists }

    // MARK: Phone modes

    func testNotConnected() {
        let app = render("not_connected")
        XCTAssertFalse(exists(app, "guide"), "no arm, no guide")
        XCTAssertTrue(app.staticTexts["Tap here to choose a server"].exists)
        XCTAssertTrue(exists(app, "operating.connect"), "the word opens Connect")
        XCTAssertEqual(app.element("operating.link").label, "No link")
    }

    func testConnecting() {
        let app = render("connecting")
        XCTAssertTrue(app.staticTexts["192.168.0.10:8765"].exists)
    }

    func testReadyWithTaskObjects() {
        let app = render("ready")
        for id in ["guide", "guide.above", "guide.behind"] {
            XCTAssertTrue(exists(app, id), id)
        }
        // What a person reads, from the fixture's arm: 3 cm above the box's centre, the target 2.5 cm across and 5.5 cm
        // forward of it, on the table.
        XCTAssertEqual(app.element("readout.height").label, "Height 6.2 cm")
        XCTAssertEqual(app.element("readout.jaws").label, "Jaws 90% open")
        XCTAssertEqual(app.element("readout.wrist").label, "Wrist turn 90° · tilt 0°")
        XCTAssertEqual(app.element("readout.target").label, "Target 6.0 cm across · 4.9 cm above")
        XCTAssertEqual(app.element("operating.rec").label, "REC armed · 12 saved · 3 discarded")
        XCTAssertEqual(app.element("operating.mode").label, "Screen turns (A)")
        XCTAssertEqual(app.element("operating.link").label, "Link up")
        XCTAssertTrue(exists(app, "operating.hint"), "scheme A's faint hint")
        XCTAssertFalse(exists(app, "practice.mark"))
        XCTAssertFalse(exists(app, "stop.release"))
    }

    /// The hotel case: the server reports no task objects, and the guide still shows the arm.
    func testReadyWithNoTaskObjects() {
        let app = render("ready_hotel")
        for id in ["guide.above", "guide.behind"] {
            XCTAssertTrue(exists(app, id), id)
        }
        XCTAssertEqual(app.element("readout.height").label, "Height 2.7 cm")
        XCTAssertEqual(app.element("readout.jaws").label, "Jaws 80% open")
        XCTAssertEqual(app.element("readout.wrist").label, "Wrist turn 90° · tilt -3°")
        XCTAssertFalse(exists(app, "readout.target"))
        XCTAssertFalse(exists(app, "readout.goal"))
        XCTAssertEqual(app.element("operating.rec").label, "Not recording")
    }

    func testMovingWhileRecording() {
        let app = render("moving")
        XCTAssertEqual(app.element("operating.rec").label, "REC 0:12 · 12 saved")
        XCTAssertTrue(exists(app, "readout.target"))
    }

    func testMovingCatchingUpWithNoTaskObjects() {
        let app = render("moving_hotel")
        XCTAssertTrue(app.staticTexts["Catching up"].exists)
    }

    func testMovingWithNoArmData() {
        let app = render("moving_no_arm")
        XCTAssertTrue(app.staticTexts["No arm data"].exists)
        XCTAssertFalse(exists(app, "guide"))
        XCTAssertFalse(exists(app, "operating.rec"), "an unknown server's recorder is not described")
    }

    func testTurningInSchemeB() {
        let app = render("turning")
        XCTAssertTrue(app.staticTexts["42° of 55°"].exists)
        XCTAssertEqual(app.element("operating.mode").label, "Key turns (B)")
        // Right hand: the near half, under the thumb, closes.
        let open = app.element("operating.hint_open").frame, close = app.element("operating.hint_close").frame
        XCTAssertLessThan(open.midX, close.midX)
    }

    func testTiltingEstimated() {
        let app = render("tilting_estimated")
        XCTAssertTrue(app.staticTexts["8° of 20° · estimated"].exists)
        XCTAssertEqual(
            app.element("readout.approximate").label, "Jaw position is approximate", "no measured wrist angles")
    }

    func testOpeningOnTarget() {
        let app = render("opening")
        XCTAssertEqual(app.element("readout.target").label, "Target 0.2 cm across · level")
        XCTAssertEqual(app.element("readout.on_target").label, "On target")
        XCTAssertFalse(exists(app, "readout.approximate"))
        XCTAssertEqual(app.element("guide.above").value as? String ?? "", "", "a solid pinch point has nothing to add")
    }

    /// The same reading as On target, but an estimate that may be off by more than half the window: drawn hollow,
    /// said in words and to VoiceOver, and never On target.
    func testAnApproximatePinchPointSaysSoAndIsNeverOnTarget() {
        let app = render("approximate")
        XCTAssertEqual(app.element("readout.approximate").label, "Jaw position is approximate")
        XCTAssertEqual(app.element("readout.target").label, "Target 0.2 cm across · level")
        XCTAssertFalse(exists(app, "readout.on_target"))
        XCTAssertEqual(app.element("guide.above").value as? String, "Jaw position is approximate")
        XCTAssertEqual(app.element("guide.behind").value as? String, "Jaw position is approximate")
    }

    func testAnApproximatePinchPointWithNoTaskObjects() {
        let app = render("approximate_hotel")
        XCTAssertEqual(app.element("readout.approximate").label, "Jaw position is approximate")
        XCTAssertFalse(exists(app, "readout.target"))
        XCTAssertEqual(app.element("guide.above").value as? String, "Jaw position is approximate")
    }

    func testClosingGripped() {
        let app = render("closing_gripped")
        XCTAssertTrue(app.staticTexts["Gripped"].exists)
        XCTAssertTrue(exists(app, "readout.holding"))
        XCTAssertTrue(exists(app, "readout.goal"))
    }

    func testHoldingSteersToTheGoal() {
        let app = render("holding")
        XCTAssertEqual(app.element("readout.holding").label, "Holding")
        XCTAssertEqual(app.element("readout.goal").label, "Goal 2.5 cm across · 4.3 cm above")
        XCTAssertFalse(exists(app, "readout.target"))
    }

    func testWaitSaving() {
        let app = render("wait_saving")
        XCTAssertTrue(app.staticTexts["Saving"].exists)
        XCTAssertEqual(app.element("operating.rec").label, "REC waiting · 13 saved · 3 discarded")
    }

    func testWaitResetting() {
        XCTAssertTrue(render("wait_resetting").staticTexts["Resetting"].exists)
    }

    func testCameraStopped() {
        XCTAssertTrue(render("camera_stopped").staticTexts["Volume keys change the volume"].exists)
    }

    func testRefused() {
        render("refused")
    }

    func testSlowLink() {
        let app = render("slow_link")
        XCTAssertTrue(app.staticTexts["450 ms"].exists)
        XCTAssertEqual(app.element("operating.link").label, "Slow link")
    }

    /// With a recorder, the stop's only exit is the reset: no release button.
    func testStoppedWhileRecording() {
        let app = render("stopped")
        XCTAssertTrue(app.staticTexts["You pressed stop"].exists)
        XCTAssertTrue(app.staticTexts["Hold the top edge to reset"].exists)
        XCTAssertFalse(exists(app, "stop.release"))
        XCTAssertTrue(exists(app, "guide"), "nothing covers the guide")
        XCTAssertEqual(app.element("operating.rec").label, "REC off: reset to record")
    }

    func testStoppedWithNoRecorderOffersRelease() {
        let app = render("stopped_release")
        XCTAssertTrue(exists(app, "stop.release"))
        XCTAssertFalse(app.staticTexts["Recording, if any, stays off until a reset."].exists)
    }

    func testStoppedOnAnUnknownServerWarnsAboutRecording() {
        let app = render("stopped_unknown_server")
        XCTAssertTrue(exists(app, "stop.release"))
        XCTAssertTrue(app.staticTexts["Recording, if any, stays off until a reset."].exists)
    }

    func testLinkLost() {
        let app = render("link_lost")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].exists)
        XCTAssertTrue(exists(app, "guide"), "the last known arm stays shown")
    }

    func testSaved() {
        render("saved")
    }

    func testRecordingOffAndTheResetCountdown() {
        let app = render("rec_off_countdown")
        XCTAssertEqual(app.element("operating.countdown").value as? String, "60%")
    }

    func testAReadingOutsideTheWorkspace() {
        let app = render("outside")
        XCTAssertTrue(exists(app, "readout.outside"))
    }

    // MARK: Practice

    func testPracticeReady() {
        let app = render("practice_ready")
        XCTAssertTrue(exists(app, "practice.mark"))
        XCTAssertEqual(app.element("operating.rec").label, "Practice: nothing is recorded")
        XCTAssertEqual(app.element("operating.link").label, "No robot")
        XCTAssertTrue(app.staticTexts["No robot connected"].exists)
        XCTAssertFalse(exists(app, "guide"), "the practice link reports no arm")
        assertNoConnectedWord(app)
    }

    func testPracticeStopped() {
        let app = render("practice_stopped")
        XCTAssertTrue(exists(app, "practice.mark"))
        XCTAssertTrue(exists(app, "stop.release"))
        assertNoConnectedWord(app)
    }

    // MARK: Buttons mode

    func testButtonsReady() {
        let app = render("buttons_ready")
        for id in [
            "buttons.forward", "buttons.back", "buttons.left", "buttons.right", "buttons.up", "buttons.down",
            "buttons.open", "buttons.close", "buttons.speed",
        ] {
            XCTAssertTrue(exists(app, id), id)
        }
        XCTAssertFalse(exists(app, "guide"), "the pad fills the control surface")
        XCTAssertEqual(app.element("operating.mode").label, "Buttons")
    }

    func testButtonsMovingShowsTheHeldButton() {
        let app = render("buttons_moving")
        XCTAssertTrue(app.element("buttons.forward").isSelected)
        XCTAssertEqual(app.element("buttons.speed").label, "Fine")
    }

    func testButtonsStoppedWithTheLeftHand() {
        let app = render("buttons_stopped")
        XCTAssertTrue(exists(app, "stop.release"))
        // Left hand: Close, the near-side gripper button, is on the left.
        XCTAssertLessThan(app.element("buttons.close").frame.midX, app.element("buttons.open").frame.midX)
    }

    func testButtonsPractice() {
        let app = render("buttons_practice")
        XCTAssertTrue(exists(app, "practice.mark"))
        assertNoConnectedWord(app)
    }
}
