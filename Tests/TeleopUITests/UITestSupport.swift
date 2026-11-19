import UIKit
import XCTest

extension XCUIApplication {
    /// Every UI test launch: the app plays no sound, speech or haptics (the simulator would put them through the
    /// computer's speakers), and still records every cue.
    static let quiet = ["-quietCues", "YES"]

    /// Practice (the built-in demo, no server), English, scheme A, right hand, unless the caller says otherwise. The
    /// mode, the hand and the task aid are saved settings, so every launch pins them.
    static func teleop(_ extra: [String] = [], language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            quiet + [
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
    func expect(
        _ app: XCUIApplication, _ id: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(app.element(id).waitForExistence(timeout: timeout), "missing \(id)", file: file, line: line)
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until the element's label is `label`.
    func expectLabel(
        _ element: XCUIElement, _ label: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label == %@", label)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(
            found, .completed, "\(element) reads \(element.exists ? element.label : "nothing"), not \(label)",
            file: file, line: line)
    }

    /// Nothing in the app says "Connected" or 已連線: practice never claims a connection (§7.4).
    func assertNoConnectedWord(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let claims = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Connected' OR label CONTAINS '已連線'"))
        XCTAssertEqual(claims.count, 0, "\(claims.allElementsBoundByIndex.map(\.label))", file: file, line: line)
    }
}

extension XCTestCase {
    /// The operating screen's red STOP band, top and bottom, read from a screenshot down the column at x = 8 from the
    /// middle of its label. The band has no element of its own, only its label, which is as tall as its words.
    func stopBandRows(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) -> (top: CGFloat, bottom: CGFloat) {
        let label = app.element("operating.stop").frame
        let picture = Picture(XCUIScreen.main.screenshot().image)
        let rows = picture.redRows(x: 8, around: label.midY)
        XCTAssertNotNil(rows, "no red at the middle of the STOP label \(label)", file: file, line: line)
        return rows ?? (label.minY, label.maxY)
    }
}

/// A screenshot's pixels, read in points.
struct Picture {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init(_ image: UIImage) {
        let cg = image.cgImage!
        width = cg.width
        height = cg.height
        scale = CGFloat(cg.width) / image.size.width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        self.bytes = bytes
    }

    /// The emergency red (#DC2626) or anything near it.
    func isRed(at point: CGPoint) -> Bool {
        isRed(column: Int(point.x * scale), row: Int(point.y * scale))
    }

    /// The red run through `y` in the column at `x`, in points: its first row and the row after its last.
    func redRows(x: CGFloat, around y: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        let column = Int(x * scale)
        var top = Int(y * scale)
        guard isRed(column: column, row: top) else { return nil }
        var bottom = top
        while top > 0, isRed(column: column, row: top - 1) { top -= 1 }
        while bottom < height - 1, isRed(column: column, row: bottom + 1) { bottom += 1 }
        return (CGFloat(top) / scale, CGFloat(bottom + 1) / scale)
    }

    private func isRed(column: Int, row: Int) -> Bool {
        let x = min(max(column, 0), width - 1)
        let y = min(max(row, 0), height - 1)
        let i = (y * width + x) * 4
        let (r, g, b) = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        return r > 160 && g < 110 && b < 110 && r - max(g, b) > 90
    }
}
