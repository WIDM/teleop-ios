import XCTest

/// The left handle column (open, two turns, two tilts) and the two guide views, on the screens that show them.
final class GuideAndHandlesTests: XCTestCase {
    private var app: XCUIApplication!

    private let handleIds = ["gripper.open", "jaw.turn_positive", "jaw.turn_negative", "jaw.tilt_down", "jaw.tilt_up"]

    private func launch(route: String, extra: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-appLanguage", "en", "-liveLink", "NO", "-startRoute", route, "-startConnected", "YES"] + extra
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expect(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: 5), "missing \(id)", file: file, line: line)
    }

    /// Frames of everything on the screen that the handle column or the guide must stay clear of.
    private func neighbours() -> [(name: String, frame: CGRect)] {
        var found: [(String, CGRect)] = []
        for id in ["stop", "volume_hint", "standby.blocked_banner"] where element(id).exists {
            found.append((id, element(id).frame))
        }
        // Only the tappable hint box has an identifier; the others are plain text inside a 12 pt padded box.
        let hint = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'vol+'")).firstMatch
        if hint.exists, !element("volume_hint").exists {
            found.append(("hint text", hint.frame.insetBy(dx: -12, dy: -12)))
        }
        return found
    }

    private func assertFiveHandlesClear(of route: String, file: StaticString = #filePath, line: UInt = #line) {
        launch(route: route)
        for id in handleIds { expect(id) }
        let handles = handleIds.map { (name: $0, frame: element($0).frame) }
        for handle in handles {
            XCTAssertGreaterThanOrEqual(handle.frame.height, 48, "\(route) \(handle.name) is too short", file: file, line: line)
            XCTAssertTrue(element(handle.name).isHittable, "\(route) \(handle.name) is not hittable", file: file, line: line)
        }
        for (i, a) in handles.enumerated() {
            for b in handles.dropFirst(i + 1) {
                XCTAssertFalse(a.frame.intersects(b.frame), "\(route): \(a.name) \(a.frame) overlaps \(b.name) \(b.frame)", file: file, line: line)
            }
            for other in neighbours() {
                XCTAssertFalse(a.frame.intersects(other.frame), "\(route): \(a.name) \(a.frame) overlaps \(other.name) \(other.frame)", file: file, line: line)
            }
        }
        XCTAssertEqual(handles.map(\.name), handles.sorted { $0.frame.minY < $1.frame.minY }.map(\.name), "\(route): order down the column", file: file, line: line)
    }

    func testFiveHandlesStayClearOfTheOtherControlsOnStandby() { assertFiveHandlesClear(of: "p4_standby") }
    func testFiveHandlesStayClearOfTheOtherControlsUnderTheLatencyBanner() { assertFiveHandlesClear(of: "p6_high_latency") }

    func testTiltHandlesMoveOnlyWhilePressed() {
        launch(route: "p4_standby")
        for id in ["jaw.tilt_down", "jaw.tilt_up"] {
            let handle = element(id)
            XCTAssertTrue(handle.waitForExistence(timeout: 5), id)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: id).count, 1, id)
            XCTAssertEqual(handle.value as? String, "stopped", id)
            XCTAssertTrue(handle.valuesDuringPress().contains("moving"), id)
            XCTAssertEqual(handle.value as? String, "stopped", id)
        }
        XCTAssertEqual(element("jaw.tilt_down").label, "Tilt the jaws down")
        XCTAssertEqual(element("jaw.tilt_up").label, "Tilt the jaws up")
    }

    func testGuideShowsTheTopViewAndTheViewFromBehindSideBySideInWidth() {
        launch(route: "p4_standby", extra: ["-demoGuidance", "YES"])
        expect("guide.map")
        expect("guide.side_view")
        expect("guide.height_gap")
        XCTAssertTrue(app.staticTexts["From above"].exists)
        XCTAssertTrue(app.staticTexts["From behind"].exists)
        let top = element("guide.map").frame, side = element("guide.side_view").frame
        XCTAssertEqual(top.width, side.width, accuracy: 0.5, "same width")
        XCTAssertEqual(top.minX, side.minX, accuracy: 0.5, "same left edge")
        XCTAssertLessThan(top.maxY, side.minY, "the side view is under the top view")
        let gap = element("guide.height_gap").label
        XCTAssertTrue(gap.hasSuffix("cm above"), "the demo has the jaws about 2 cm above the cube: \(gap)")

        let guide = top.union(side)
        let handles = handleIds.map { element($0).frame }
        for frame in handles + neighbours().map(\.frame) {
            XCTAssertFalse(guide.intersects(frame), "the guide \(guide) covers \(frame)")
        }
        XCTAssertTrue(element("stop").isHittable)
        for id in handleIds { XCTAssertTrue(element(id).isHittable, id) }

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "guide-two-views"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
