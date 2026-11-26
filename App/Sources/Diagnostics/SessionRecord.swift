import Foundation
import UIKit

/// A small record kept on the phone: one line per event, in `Documents/session.log` in the app's container, appended
/// across launches. Each line starts with the wall-clock time to the millisecond and the seconds since the record
/// started in this process. It only records: nothing the app decides, sends, shows or plays reads it.
///
/// The file rotates around `limit`: when a launch finds it at the limit, or a batch would take it past, it is
/// renamed `session.1.log`, replacing an older one. A single large batch may exceed the limit.
///
/// Nothing private is written: a server's address (a ws:// or wss:// address, an IPv4 address, an IPv6 address in
/// brackets, or a host with a port) is written as `<server>`.
///
/// Any thread may add a line, at the cost of one append under a lock. A background queue writes what has gathered a
/// fifth of a second after the first line of a batch, and at once when the app leaves the active state, so the main
/// thread never waits for the file while the operator can still press anything.
final class SessionRecord: @unchecked Sendable {
    static let shared = SessionRecord(url: defaultURL())

    /// Two megabytes.
    static let defaultLimit = 2 * 1024 * 1024

    /// `Documents/session.log`. Nil in the host process of the unit tests, so they never write into the app's own
    /// record (tests give a record a file of their own), and nil if the system names no documents folder.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard AppModel.opensSavedServerAtLaunch(environment: environment) else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("session.log")
    }

    /// The file the lines are appended to; nil keeps no file.
    let url: URL?
    /// Where a full file is set aside: `session.1.log` beside `session.log`.
    let asideURL: URL?
    private let delay: TimeInterval
    private let limit: Int
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var pending: [Line] = []
    private var writeScheduled = false
    private var launchNoted = false
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "session.record.writer", qos: .utility)
    /// The open file and how many bytes it holds. Used on `queue` only.
    private var handle: FileHandle?
    private var size = 0
    /// Used on `queue` only.
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private struct Line {
        let date: Date
        let uptime: TimeInterval
        /// Builds the line's words; called on the writer's queue.
        let words: @Sendable () -> String
    }

    /// - Parameters:
    ///   - url: the file the lines are appended to; nil keeps no file.
    ///   - delay: how long after the first line of a batch the batch is written.
    ///   - limit: the size in bytes the file never grows past.
    init(url: URL?, delay: TimeInterval = 0.2, limit: Int = SessionRecord.defaultLimit) {
        self.url = url
        self.delay = delay
        self.limit = limit
        asideURL = url.map { url in
            let name = url.deletingPathExtension().lastPathComponent + ".1." + url.pathExtension
            return url.deletingLastPathComponent().appendingPathComponent(name)
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Adds one line, stamped now.
    func note(_ text: String) {
        noteLater { text }
    }

    /// Adds one line, stamped now, whose words are built later on the writer's queue: for lines on the path of a
    /// touch, so that the main thread only keeps the values.
    func noteLater(_ words: @escaping @Sendable () -> String) {
        guard url != nil else { return }
        let line = Line(date: Date(), uptime: ProcessInfo.processInfo.systemUptime, words: words)
        lock.lock()
        pending.append(line)
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + delay) { [self] in writePending() } }
    }

    /// Writes every line added so far before returning.
    func flush() {
        queue.sync { writePending() }
    }

    /// Once per process: the launch line (version, build, device model, system version), then a line each time the
    /// app becomes active, will resign active or enters the background, and every line written before it goes.
    func launched() {
        guard url != nil else { return }
        lock.lock()
        let first = !launchNoted
        launchNoted = true
        lock.unlock()
        guard first else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        note(
            "launch version=\(version) build=\(build) device=\(Self.deviceModel())"
                + " system=\(device.systemName) \(device.systemVersion)")
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in self?.note("app became active")
            },
            // Leaving the active state ends every hold, so the main thread does not wait for the file here: the
            // lines go out at once on the writer's queue. Once in the background it waits.
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in self?.left("app will resign active", waiting: false)
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                [weak self] _ in self?.left("app entered the background", waiting: true)
            },
        ]
    }

    private func left(_ words: String, waiting: Bool) {
        note(words)
        if waiting {
            flush()
        } else {
            queue.async { [self] in writePending() }
        }
    }

    private func writePending() {
        lock.lock()
        let batch = pending
        pending = []
        writeScheduled = false
        lock.unlock()
        guard !batch.isEmpty, url != nil else { return }
        var text = ""
        for line in batch {
            let words = Self.withoutAddresses(line.words())
            text += clock.string(from: line.date) + " +" + Self.seconds(line.uptime - started) + " " + words + "\n"
        }
        let data = Data(text.utf8)
        guard var file = openFile() else { return }
        if size > 0, size + data.count > limit {
            guard let fresh = setAside() else { return }
            file = fresh
        }
        do {
            try file.write(contentsOf: data)
            size += data.count
        } catch {
            return
        }
    }

    /// Opens the file the first time this process writes, and sets it aside first when it is already at the limit.
    private func openFile() -> FileHandle? {
        if let handle { return handle }
        guard let url else { return nil }
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if existing >= limit { return setAside() }
        return open(url)
    }

    /// Renames the file `session.1.log`, replacing an older one, and opens a new empty file in its place.
    private func setAside() -> FileHandle? {
        guard let url, let asideURL else { return nil }
        try? handle?.close()
        handle = nil
        size = 0
        try? FileManager.default.removeItem(at: asideURL)
        try? FileManager.default.moveItem(at: url, to: asideURL)
        return open(url)
    }

    private func open(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        size = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }

    private static let addressPatterns: [NSRegularExpression] = [
        // A full address with its scheme, path and all.
        #"(?i)\bwss?://[^\s"'<>]+"#,
        // An IPv6 address in brackets, with or without its port.
        #"\[[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*\](?::\d{1,5})?"#,
        // An IPv4 address, with or without its port.
        #"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b"#,
        // A host name with a port. The name must hold a letter, so a time such as 14:38 stays.
        #"\b(?=[A-Za-z0-9.-]*[A-Za-z])[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?:\d{1,5}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The words with every server address written as `<server>`.
    static func withoutAddresses(_ words: String) -> String {
        var text = words
        for pattern in addressPatterns {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<server>")
        }
        return text
    }

    /// The model identifier, such as iPhone17,1; in the iPhone simulator, the one it simulates.
    static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated + " (simulator)"
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.3f", value) }
}
