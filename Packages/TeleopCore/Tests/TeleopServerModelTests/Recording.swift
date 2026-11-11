import Foundation
import TeleopServerModel

/// One recording of the real server: what a client sent and what came back, with times in seconds from the
/// start of the scenario. Made by the lab's trace script against the S4 server on 2026-11-11 (see docs/TESTING.md).
struct Recording {
    struct Line {
        let time: Double
        /// True for client to server.
        let outgoing: Bool
        let message: JSONValue

        var type: String { message["type"]?.stringValue ?? "" }
        var seq: Int? { message["seq"]?.intValue }
        var payload: JSONValue { message["payload"] ?? .object([]) }
    }

    let name: String
    let lines: [Line]

    /// Client messages. The note the script writes when it reopens the socket is not one.
    var sent: [Line] { lines.filter { $0.outgoing && $0.seq != nil } }
    var received: [Line] { lines.filter { !$0.outgoing } }
    var duration: Double { lines.last?.time ?? 0 }

    static func load(_ name: String) throws -> Recording {
        guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Recordings") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = try text.split(separator: "\n").map { row -> Line in
            guard let value = JSONValue.parse(String(row)), let time = value["t"]?.numberValue,
                  let direction = value["dir"]?.stringValue, let message = value["msg"] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: name])
            }
            return Line(time: time, outgoing: direction == "out", message: message)
        }
        return Recording(name: name, lines: lines)
    }
}
