import TeleopCore
import XCTest
@testable import Teleop

/// The record kept on the phone: each line reaches its file stamped with the wall-clock time to the millisecond and
/// the seconds since the record's start, without being asked; lines are appended across launches; a file at its limit
/// is set aside as `session.1.log`, at launch and when a write would take it past; no server address is ever written;
/// and the host process of the unit tests keeps no file.
final class SessionRecordTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRecordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var logURL: URL { folder.appendingPathComponent("session.log") }
    private var asideURL: URL { folder.appendingPathComponent("session.1.log") }

    private func contents(_ url: URL?) -> String {
        url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// The words of each line, without the two times in front.
    private func words(_ url: URL) -> [String] {
        contents(url).split(separator: "\n").map { $0.split(separator: " ", maxSplits: 3).last.map(String.init) ?? "" }
    }

    /// Waits up to `timeout` for the file to hold `text`, reading it again and again.
    private func waitFor(_ text: String, in url: URL, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if contents(url).contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < end
        return contents(url).contains(text)
    }

    func testTheAppRecordsSettingsLinkTransitionsAndSpeech() {
        let record = SessionRecord(url: logURL)
        let model = AppModel(
            start: .p4, speech: NoSpeech(), liveLink: true, assistOn: false, sessionRecord: record)
        model.session.state.markConnected()
        model.send(.linkLatency(ms: 450))
        model.send(.linkLatency(ms: 480))
        model.send(.linkLatency(ms: 40))
        model.raise(.refused(.tapStill))
        model.log("link: connecting wss://robot.example:1234")
        record.flush()
        let lines = words(logURL)
        XCTAssertTrue(lines.contains { $0.hasPrefix("launch version=") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("settings mode=") && $0.contains("assist=false") })
        XCTAssertTrue(lines.contains("slow link on rtt_ms=[450, 480]"))
        XCTAssertTrue(lines.contains("slow link off rtt_ms=[40]"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("screen refused") })
        let start = lines.firstIndex {
            $0.hasPrefix("speech start id=") && $0.contains("say.tap_still")
        }
        let finish = lines.firstIndex { $0.hasPrefix("speech end id=") && $0.hasSuffix(" finished") }
        XCTAssertNotNil(start)
        XCTAssertNotNil(finish)
        if let start, let finish { XCTAssertLessThan(start, finish) }
        XCTAssertTrue(lines.contains("link: connecting <server>"))
        XCTAssertFalse(contents(logURL).contains("robot.example"))
    }

    func testTheAppRecordsHowTheCameraMarkCleared() {
        let record = SessionRecord(url: logURL)
        let model = AppModel(start: .p4, liveLink: false, inputClock: { 10 }, sessionRecord: record)
        model.controller.cameraInterrupted(true)
        model.controller.trackerRan(at: 11)
        model.poseFrame(nil, at: 12)
        model.controller.cameraInterrupted(true)
        model.controller.cameraInterrupted(false)
        record.flush()
        let marks = words(logURL).filter { $0.hasPrefix("camera mark ") }
        XCTAssertEqual(
            marks,
            [
                "camera mark set",
                "camera mark cleared by a frame after the app's run stamp=12.0",
                "camera mark set",
                "camera mark cleared by the end report",
            ])
    }

    func testTheAppRecordsTheWholeTouchOnceAtLift() {
        let record = SessionRecord(url: logURL)
        let model = AppModel(start: .p4, liveLink: false, inputClock: { 10 }, sessionRecord: record)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        model.guidePanelChanged(SurfaceLayout.Rect(x: 100, y: 260, width: 200, height: 200))
        model.touch(TouchSample(id: 1, phase: .began, x: 200, y: 350, majorRadius: 1), at: 10)
        model.touch(TouchSample(id: 1, phase: .moved, x: 232, y: 350, majorRadius: 1), at: 10.05)
        model.guidePanelChanged(nil)
        model.touch(TouchSample(id: 1, phase: .ended, x: 201, y: 350, majorRadius: 1), at: 10.1)
        record.flush()
        let touches = words(logURL).filter { $0.hasPrefix("touch ") }
        XCTAssertEqual(touches.count, 1)
        XCTAssertTrue(touches.first?.contains("x=200.0 y=350.0 duration_s=0.100 travel_mm=5.00") == true)
        XCTAssertTrue(touches.first?.contains("panel=Rect(x: 100.0, y: 260.0, width: 200.0, height: 200.0)") == true)
    }

    func testALineReachesTheFileUnaskedWithItsTimes() throws {
        let record = SessionRecord(url: logURL)
        record.note("slow link on")
        XCTAssertTrue(waitFor("slow link on", in: logURL), "the line was written without a flush")
        let line = try XCTUnwrap(contents(logURL).split(separator: "\n").first.map(String.init))
        let stamped = try NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \+\d+\.\d{3} slow link on$"#)
        XCTAssertEqual(
            stamped.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 1,
            "wall-clock time to the millisecond, then seconds since the start: \(line)")
    }

    func testLinesAreAppendedAcrossLaunches() {
        let first = SessionRecord(url: logURL)
        first.note("first launch")
        first.flush()
        let second = SessionRecord(url: logURL)
        second.note("second launch")
        second.flush()
        XCTAssertEqual(words(logURL), ["first launch", "second launch"], "kept, and the new launch after it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asideURL.path), "nothing set aside under the limit")
    }

    func testAFileOverTheLimitIsSetAsideAtLaunch() throws {
        try Data("an older launch set aside before\n".utf8).write(to: asideURL)
        try Data((String(repeating: "x", count: 150) + " the last launch\n").utf8).write(to: logURL)
        let record = SessionRecord(url: logURL, limit: 100)
        record.note("this launch")
        record.flush()
        XCTAssertEqual(words(logURL), ["this launch"], "a new file for this launch")
        XCTAssertTrue(contents(asideURL).contains("the last launch"), "the full file is set aside whole")
        XCTAssertFalse(contents(asideURL).contains("an older launch"), "replacing the one set aside before")
    }

    func testAWriteThatCrossesTheLimitSetsTheFileAside() {
        // Each of these lines is about 66 bytes with its two times.
        let record = SessionRecord(url: logURL, delay: 60, limit: 150)
        record.note("one " + String(repeating: "a", count: 30))
        record.flush()
        record.note("two " + String(repeating: "b", count: 30))
        record.flush()
        XCTAssertEqual(words(logURL).count, 2, "two lines fit under the limit")
        record.note("three " + String(repeating: "c", count: 30))
        record.flush()
        XCTAssertEqual(words(logURL), ["three " + String(repeating: "c", count: 30)], "the line that would cross it")
        XCTAssertEqual(words(asideURL).map { $0.prefix(4) }, ["one ", "two "], "the full file, set aside")
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, 150)
    }

    func testServerAddressesAreNeverWritten() {
        let record = SessionRecord(url: logURL, delay: 60)
        record.note("link: connecting ws://192.168.1.20:8765")
        record.note("link: connecting wss://lab.example.org:443/teleop?x=1")
        record.note("saved server 10.0.0.5:8765 and 100.64.12.7")
        record.note("saved server teleop-mac.local:8765 then lab.example.org:9000.")
        record.note("saved server [fd7a:115c::5]:8765")
        record.note("ready at 14:38:22.746, tilt 12.5, iPhone17,1, version 1.1.1 (16)")
        record.flush()
        let text = contents(logURL)
        for address in [
            "192.168", "lab.example.org", "10.0.0.5", "100.64", "teleop-mac", "fd7a", "8765", "9000", "ws://",
            "wss://",
        ] {
            XCTAssertFalse(text.contains(address), "\(address) was written: \(text)")
        }
        XCTAssertEqual(
            words(logURL),
            [
                "link: connecting <server>",
                "link: connecting <server>",
                "saved server <server> and <server>",
                "saved server <server> then <server>.",
                "saved server <server>",
                "ready at 14:38:22.746, tilt 12.5, iPhone17,1, version 1.1.1 (16)",
            ])
    }

    func testNothingIsWrittenWithoutAFile() throws {
        let record = SessionRecord(url: nil, delay: 0)
        record.note("nowhere to go")
        record.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertNil(SessionRecord.shared.url, "the host process of the unit tests keeps no file")
        XCTAssertNil(
            SessionRecord.defaultURL(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        XCTAssertEqual(SessionRecord.defaultURL(environment: [:]), documents.appendingPathComponent("session.log"))
    }

    func testTheLaunchLineNamesTheAppAndThePhone() {
        let record = SessionRecord(url: logURL, delay: 60)
        record.launched()
        record.launched()
        record.flush()
        let lines = words(logURL)
        XCTAssertEqual(lines.count, 1, "once per process: \(lines)")
        let line = lines.first ?? ""
        XCTAssertTrue(line.hasPrefix("launch version="), line)
        for part in [" build=", " device=", " system="] { XCTAssertTrue(line.contains(part), line) }
    }
}
