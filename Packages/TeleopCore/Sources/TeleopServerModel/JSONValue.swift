import Foundation

/// A JSON value that keeps what the wire said. The server is written in Python and tells `1` from `1.0`
/// and `true` from `1` when it validates a message, so an integer stays `.int` and a real number `.double`.
/// Objects keep their key order, as the server's dictionaries do.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Only a JSON integer, as Python's `type(x) is int`.
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// An integer or a real number, never a boolean.
    public var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var members: [JSONMember]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Key names of an object, nil for anything else.
    public var keys: Set<String>? { members.map { Set($0.map(\.key)) } }

    /// The same object with `key` set, appended if new, replaced in place if not.
    public func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        var list = members ?? []
        if let index = list.firstIndex(where: { $0.key == key }) {
            list[index].value = value
        } else {
            list.append(JSONMember(key, value))
        }
        return .object(list)
    }

    public static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(pairs.map { JSONMember($0.key, $0.value) })
    }

    public static func numbers(_ values: [Double]) -> JSONValue {
        .array(values.map { .double($0) })
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

// MARK: - Text

extension JSONValue {
    /// Parses one JSON document the way Python's `json.loads` does, including its `NaN` and `Infinity` words.
    /// Nil when the text is not JSON.
    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(bytes: Array(text.utf8))
        guard let value = parser.value() else { return nil }
        parser.skipSpace()
        return parser.atEnd ? value : nil
    }

    /// JSON text with the separators Python's `json.dumps` uses.
    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += Self.number(value)
        case .string(let value): Self.quote(value, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += ", " }
                value.write(to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += ", " }
                Self.quote(member.key, into: &out)
                out += ": "
                member.value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity") }
        // Swift's shortest round-trip form matches Python's repr closely enough: 0.0, 40.24, 1e-05.
        return "\(value)"
    }

    private static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index >= bytes.count }

    mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value() -> JSONValue? {
        skipSpace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map { .string($0) }
        case UInt8(ascii: "t"): return word("true", .bool(true))
        case UInt8(ascii: "f"): return word("false", .bool(false))
        case UInt8(ascii: "n"): return word("null", .null)
        case UInt8(ascii: "N"): return word("NaN", .double(.nan))
        case UInt8(ascii: "I"): return word("Infinity", .double(.infinity))
        default:
            if bytes[index] == UInt8(ascii: "-"), word("-Infinity", .double(-.infinity)) != nil {
                return .double(-.infinity)
            }
            return number()
        }
    }

    private mutating func word(_ text: String, _ result: JSONValue) -> JSONValue? {
        let expected = Array(text.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            return nil
        }
        index += expected.count
        return result
    }

    private mutating func object() -> JSONValue? {
        index += 1
        var members: [JSONMember] = []
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = value() else { return nil }
            // A repeated key keeps its first place and its last value, like a Python dict.
            if let existing = members.firstIndex(where: { $0.key == key }) {
                members[existing].value = value
            } else {
                members.append(JSONMember(key, value))
            }
            skipSpace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "}") else { return nil }
            index += 1
            return .object(members)
        }
    }

    private mutating func array() -> JSONValue? {
        index += 1
        var values: [JSONValue] = []
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            guard let value = value() else { return nil }
            values.append(value)
            skipSpace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "]") else { return nil }
            index += 1
            return .array(values)
        }
    }

    private mutating func string() -> String? {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flushRaw() -> Bool {
            guard !raw.isEmpty else { return true }
            guard let text = String(bytes: raw, encoding: .utf8) else { return false }
            scalars.append(contentsOf: text.unicodeScalars)
            raw = []
            return true
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard flushRaw() else { return nil }
                return String(scalars)
            case UInt8(ascii: "\\"):
                guard flushRaw(), index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    if (0xD800..<0xDC00).contains(code) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                              bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                        index += 2
                        guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { return nil }
                    scalars.append(scalar)
                default:
                    return nil
                }
            default:
                // Python's strict mode refuses raw control characters inside a string.
                guard byte >= 0x20 else { return nil }
                raw.append(byte)
            }
        }
        return nil
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              let code = UInt32(text, radix: 16) else { return nil }
        index += 4
        return code
    }

    private mutating func number() -> JSONValue? {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        var real = false
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            real = true
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            real = true
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .ascii) else { return nil }
        if !real, let integer = Int(text) { return .int(integer) }
        return Double(text).map { .double($0) }
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
}
