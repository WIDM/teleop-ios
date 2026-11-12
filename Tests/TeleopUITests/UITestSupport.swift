import XCTest

extension XCUIApplication {
    /// Every UI test launch: the app plays no sound, speech or haptics (the simulator would put them through the
    /// computer's speakers), and still records every cue.
    static let quiet = ["-quietCues", "YES"]

    /// Practice (the built-in demo, no server), English, scheme A, right hand, unless the caller says otherwise. The
    /// mode, the hand and the task aid are saved settings, so every launch pins them.
    static func teleop(_ extra: [String] = [], language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = quiet + [
            "-appLanguage", language, "-liveLink", "NO", "-controlMode", "screenTurns", "-hand", "right",
            "-taskAid", "YES", "-firstRunDone", "YES",
        ] + extra
        return app
    }

    func element(_ id: String) -> XCUIElement {
        descendants(matching: .any)[id].firstMatch
    }
}

extension XCTestCase {
    func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.element(id).waitForExistence(timeout: timeout), "missing \(id)", file: file, line: line)
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until the element's label is `label`.
    func expectLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", label)
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(found, .completed, "\(element) reads \(element.exists ? element.label : "nothing"), not \(label)", file: file, line: line)
    }

    /// Nothing in the app says "Connected" or 已連線: practice never claims a connection (§7.4).
    func assertNoConnectedWord(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let claims = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connected' OR label CONTAINS '已連線'"))
        XCTAssertEqual(claims.count, 0, "\(claims.allElementsBoundByIndex.map(\.label))", file: file, line: line)
    }
}
