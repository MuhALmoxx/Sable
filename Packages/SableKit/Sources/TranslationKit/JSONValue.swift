import Foundation

// OWNER: translation agent.

/// Tiny JSON value with ORDERED objects, so request bodies and prompt payloads serialise
/// deterministically and in a readable order (context before units before following lines).
public indirect enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool { lhs.serialized() == rhs.serialized() }
    public func hash(into hasher: inout Hasher) { hasher.combine(serialized()) }

    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public var data: Data { Data(serialized().utf8) }

    private func write(into out: inout String) {
        switch self {
        case let .string(s): JSONValue.writeString(s, into: &out)
        case let .number(d):
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 { out += String(Int(d)) } else if d.isFinite { out += String(d) } else { out += "null" }
        case let .int(i): out += String(i)
        case let .bool(b): out += b ? "true" : "false"
        case .null: out += "null"
        case let .array(items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
