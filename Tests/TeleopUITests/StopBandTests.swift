import UIKit
import XCTest

/// The STOP band ends where the bottom safe area begins. A press on it stops at once; a press in the strip under it,
/// where the system's swipe home begins, does nothing; nothing red is drawn there. On the operating screen and on
/// every other screen that carries the band, at the test device's 874 pt and at 667 pt.
final class StopBandTests: XCTestCase {
    /// The test device's bottom safe area, under the home indicator, as on the owner's phone.
    static let safeBottom: CGFloat = 34

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: The operating screen

    private func launchOperating(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.teleop(["-startRoute", "p4_standby", "-recordHaptics", "YES"] + extra)
        app.launch()
        expectLabel(app.element("operating.state"), "Ready")
        return app
    }

    func testOnTheOperatingScreenAPressUnderTheBandDoesNothingAndOneOnItStops() {
        let app = launchOperating()
        let screen = app.windows.firstMatch.frame
        let band = stopBandRows(app)
        XCTAssertEqual(band.top, 768, accuracy: 0.5, "the band's top edge has not moved")
        XCTAssertEqual(band.bottom, screen.maxY - Self.safeBottom, accuracy: 0.5, "it ends where the safe area begins")
        assertNothingRed(under: band.bottom, down: screen.maxY, across: screen.width, "operating screen 874")
        attachScreenshot("stop-band-operating-874")

        assertNothingComesOf(app, press: CGPoint(x: screen.midX, y: band.bottom + Self.safeBottom / 2))
        assertNothingComesOf(app, press: CGPoint(x: 20, y: screen.maxY - 4))
        // His swipe home, up from the strip through the band and the gap into the control surface. The screen defers
        // the system's edge gestures, so the first swipe stays in the app.
        assertNothingComesOf(
            app, swipeFrom: CGPoint(x: screen.midX, y: band.bottom + 20), to: CGPoint(x: screen.midX, y: band.top - 200)
        )
        XCTAssertEqual(app.state, .runningForeground, "the first swipe from the bottom edge stays in the app")

        // The band's lowest row stops while the finger is still on it; sliding off the band afterwards changes nothing.
        expectStoppedWhileHolding(
            app, at: CGPoint(x: screen.midX, y: band.bottom - 3), thenDragTo: CGPoint(x: screen.midX, y: 400))
    }

    /// The short screen the UI tests draw has no bottom safe area: the band runs to its bottom edge and stops there.
    func testOnTheShortScreenTheBandRunsToTheBottomEdge() {
        let app = launchOperating(["-screenFrame", "375x667x20x0"])
        let band = stopBandRows(app)
        XCTAssertEqual(band.top, 667 - 72 * 667 / 874, accuracy: 0.5)
        XCTAssertEqual(band.bottom, 667, accuracy: 0.5)
        expectStoppedWhileHolding(app, at: CGPoint(x: 187, y: 665))
    }

    /// The same short screen with a 34 pt safe area under it: the band is scaled, the strip is not, and the drawing
    /// and the input rules agree on where one ends and the other begins.
    func testOnAShortScreenWithASafeAreaTheStripUnderTheBandDoesNothing() {
        let app = launchOperating(["-screenFrame", "375x667x20x34"])
        let band = stopBandRows(app)
        XCTAssertEqual(band.top, 667 - Self.safeBottom - 72 * 667 / 874, accuracy: 0.5)
        XCTAssertEqual(band.bottom, 667 - Self.safeBottom, accuracy: 0.5)
        assertNothingRed(under: band.bottom, down: 667, across: 375, "operating screen 667 with a safe area")
        attachScreenshot("stop-band-operating-667-safe-area")
        assertNothingComesOf(app, press: CGPoint(x: 187, y: band.bottom + 2))
        assertNothingComesOf(app, swipeFrom: CGPoint(x: 187, y: 660), to: CGPoint(x: 187, y: 300))
        expectStoppedWhileHolding(app, at: CGPoint(x: 187, y: band.bottom - 2))
    }

    // MARK: The other screens

    private struct OtherScreen {
        var name: String
        var arguments: [String]
        /// An element that shows while the app is still on that screen.
        var marker: String
        var opensFromTheOperatingScreen = false
    }

    private static let otherScreens = [
        OtherScreen(name: "Connect", arguments: ["-startRoute", "s1_connect"], marker: "connect.practice"),
        OtherScreen(
            name: "Settings", arguments: ["-startRoute", "p4_standby"], marker: "settings.done",
            opensFromTheOperatingScreen: true),
        OtherScreen(name: "tutorial", arguments: ["-startRoute", "t1_tutorial"], marker: "tutorial.next"),
        OtherScreen(name: "Permissions", arguments: ["-startRoute", "s2_permissions"], marker: "permissions.continue"),
    ]

    private func open(_ screen: OtherScreen, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.teleop(screen.arguments + extra)
        app.launch()
        if screen.opensFromTheOperatingScreen {
            expect(app, "operating.gear")
            app.element("operating.gear").tap()
        }
        expect(app, screen.marker)
        expect(app, "stop")
        return app
    }

    func testOnEveryOtherScreenAPressUnderTheBandDoesNothingAndOneOnItStops() {
        for screen in Self.otherScreens {
            let app = open(screen)
            let window = app.windows.firstMatch.frame
            let band = app.element("stop").frame
            XCTAssertEqual(band.height, 72, accuracy: 0.5, screen.name)
            XCTAssertEqual(window.maxY - band.maxY, Self.safeBottom, accuracy: 0.5, "\(screen.name): above the strip")
            XCTAssertEqual(app.element("stop").label, "STOP 急停")

            press(app, at: CGPoint(x: window.midX, y: band.maxY + Self.safeBottom / 2))
            press(app, at: CGPoint(x: 30, y: window.maxY - 4))
            XCTAssertFalse(
                app.element("operating.state").waitForExistence(timeout: 1), "\(screen.name): the strip stopped")
            XCTAssertTrue(app.element(screen.marker).exists, "\(screen.name): still showing")

            expectStoppedWhileHolding(app, at: CGPoint(x: window.midX, y: band.maxY - 3), screen.name)
            app.terminate()
        }
    }

    func testOnEveryOtherScreenNothingRedIsDrawnUnderTheBand() {
        for screen in Self.otherScreens {
            let app = open(screen)
            let window = app.windows.firstMatch.frame
            let band = app.element("stop").frame
            let picture = Picture(XCUIScreen.main.screenshot().image)
            XCTAssertTrue(picture.isRed(at: CGPoint(x: 8, y: band.midY)), "\(screen.name): the band is red")
            assertNothingRed(under: band.maxY, down: window.maxY, across: window.width, screen.name)
            attachScreenshot("stop-band-\(screen.name)-874")
            app.terminate()
        }
    }

    /// At 667 pt the test frame has no safe area: the band sits on the frame's bottom edge and stops there.
    func testOnEveryOtherScreenAtTheShortHeightAPressOnTheBandStops() {
        for screen in Self.otherScreens where screen.name != "Permissions" {
            let app = open(screen, ["-screenFrame", "375x667x20x0"])
            let band = app.element("stop").frame
            XCTAssertEqual(band.height, 72, accuracy: 0.5, screen.name)
            XCTAssertEqual(band.maxY, 667, accuracy: 0.5, screen.name)
            expectStoppedWhileHolding(app, at: CGPoint(x: 187, y: 665), screen.name)
            app.terminate()
        }
    }

    // MARK: Pressing and looking

    private func point(_ app: XCUIApplication, _ p: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
    }

    private func press(_ app: XCUIApplication, at p: CGPoint, for duration: TimeInterval = 0.1) {
        point(app, p).press(forDuration: duration)
    }

    /// Holds a finger on `p` for 5 s (then slides it to `end`, if given) and fails unless the app stopped while the
    /// finger was still down, so a STOP that waited for the lift fails. A press holds up the test until the finger
    /// lifts, and the test may only look from that same thread, so the moment comes from the developer log in
    /// Settings, which notes each action to the second.
    private func expectStoppedWhileHolding(
        _ app: XCUIApplication, at p: CGPoint, thenDragTo end: CGPoint? = nil, _ what: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if let end {
            point(app, p).press(forDuration: 5, thenDragTo: point(app, end))
        } else {
            point(app, p).press(forDuration: 5)
        }
        let lifted = Self.secondOfDay(Date())
        expectLabel(app.element("operating.state"), "STOPPED", timeout: 2, file: file, line: line)
        guard let stopped = lastStopInTheLog(app, file: file, line: line) else { return }
        // A STOP at touch-down is logged about 5 s before the lift, one at the lift 0 or 1 s before it.
        var early = (lifted - stopped + 86_400) % 86_400
        if early > 43_200 { early -= 86_400 }
        XCTAssertTrue(
            (3...30).contains(early), "\(what) \(p): the STOP came \(early) s before the lift", file: file, line: line)
    }

    private static func secondOfDay(_ date: Date) -> Int {
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (time.hour ?? 0) * 3600 + (time.minute ?? 0) * 60 + (time.second ?? 0)
    }

    /// Opens Settings from the operating screen, shows the developer log (five taps on the version) and returns the
    /// second of the day of its last STOP.
    private func lastStopInTheLog(_ app: XCUIApplication, file: StaticString, line: UInt) -> Int? {
        app.element("operating.gear").tap()
        expect(app, "settings.done", file: file, line: line)
        let version = app.element("settings.version")
        for _ in 0..<6 where !(version.exists && version.isHittable) { app.swipeUp() }
        for _ in 0..<5 { version.tap() }
        let log = app.element("settings.log")
        for _ in 0..<4 where !(log.exists && log.isHittable) { app.swipeUp() }
        let text = log.label
        guard let mark = text.range(of: "→ stop", options: .backwards) else {
            XCTFail("no STOP in the developer log: \(text)", file: file, line: line)
            return nil
        }
        let clock = text[..<mark.lowerBound].trimmingCharacters(in: .whitespaces).suffix(8)
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else {
            XCTFail("no time before the STOP in the developer log: \(text)", file: file, line: line)
            return nil
        }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// The operating screen stays Ready and plays no cue.
    private func assertNothingComesOf(
        _ app: XCUIApplication, press p: CGPoint? = nil, swipeFrom start: CGPoint? = nil, to end: CGPoint? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let cues = app.element("test.haptics").label
        if let p { press(app, at: p) }
        if let start, let end {
            point(app, start).press(
                forDuration: 0.02, thenDragTo: point(app, end), withVelocity: .fast,
                thenHoldForDuration: 0)
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "Ready"), object: app.element("operating.state"))
        changed.isInverted = true
        XCTAssertEqual(
            XCTWaiter().wait(for: [changed], timeout: 1), .completed,
            "\(String(describing: p ?? start)): the state reads \(app.element("operating.state").label)", file: file,
            line: line)
        XCTAssertEqual(app.element("test.haptics").label, cues, "no cue", file: file, line: line)
    }

    /// Reads a grid of pixels between the band's lower edge and `bottom`, 8 pt apart across and 3 pt down.
    private func assertNothingRed(
        under top: CGFloat, down bottom: CGFloat, across width: CGFloat, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let picture = Picture(XCUIScreen.main.screenshot().image)
        var red: [CGPoint] = []
        var y = top + 1
        while y < bottom - 0.5 {
            for x in stride(from: 2, to: width - 1, by: 8) where picture.isRed(at: CGPoint(x: x, y: y)) {
                red.append(CGPoint(x: x, y: y))
            }
            y += 3
        }
        XCTAssertTrue(red.isEmpty, "\(what): red under the band at \(red.prefix(5))", file: file, line: line)
    }
}
