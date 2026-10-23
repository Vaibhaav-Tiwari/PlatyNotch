import Foundation

/// JSON that keeps object key order and number literals exactly as read, so a file
/// written by Go (or by the Pro edition) can be edited without reordering or
/// dropping keys this app does not know.
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The number's literal text (`20`, `1.5e3`), never reformatted.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public static func number(_ i: Int) -> OrderedJSON { .number(String(i)) }

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.last { $0.0 == key }?.1
    }

    public var keys: [String] {
        guard case .object(let pairs) = self else { return [] }
        return pairs.map(\.0)
    }

    /// Re-encodes this value compactly as plain JSON data (for `JSONDecoder`).
    public var data: Data { Data(serialized(indent: nil).utf8) }

    // MARK: - Parse

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let offset: Int
        public let reason: String
        public var description: String { "invalid JSON at byte \(offset): \(reason)" }
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.error("trailing characters") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        static let maxDepth = 512

        func error(_ reason: String) -> ParseError { ParseError(offset: i, reason: reason) }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for b in literal.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw error("expected \(literal)") }
                i += 1
            }
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < Self.maxDepth else { throw error("nested too deeply") }
            guard i < bytes.count else { throw error("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var pairs: [(String, OrderedJSON)] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected key") }
                    let k = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    pairs.append((k, try value(depth: depth + 1)))
                    skipSpace()
                    guard i < bytes.count else { throw error("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                    throw error("expected , or }")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw error("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw error("expected , or ]")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default:
                return .number(try number())
            }
        }

        mutating func number() throws -> String {
            let start = i
            func digits(_ p: inout Parser) -> Int {
                let s = p.i
                while p.i < p.bytes.count, (0x30...0x39).contains(p.bytes[p.i]) { p.i += 1 }
                return p.i - s
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw error("invalid value") }
            if bytes[i] == UInt8(ascii: "0") { i += 1 } else { _ = digits(&self) }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digits(&self) > 0 else { throw error("invalid number") }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits(&self) > 0 else { throw error("invalid number") }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count,
                  let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw error("invalid \\u escape") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1   // opening quote
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw error("unterminated string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                if b < 0x20 { throw error("control character in string") }
                if b != UInt8(ascii: "\\") { out.append(b); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw error("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), i + 6 <= bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw error("invalid escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: - Serialize

    /// Go `json.MarshalIndent(v, "", "  ")` layout when `indent` is set; compact otherwise.
    /// Strings are escaped as Go does (including `<`, `>`, `&`, U+2028 and U+2029).
    public func serialized(indent: String? = "  ") -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, indent: String?, level: Int) {
        func newline(_ l: Int) {
            guard let indent else { return }
            out += "\n" + String(repeating: indent, count: l)
        }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.quote(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                newline(level + 1)
                item.write(into: &out, indent: indent, level: level + 1)
            }
            newline(level)
            out += "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{"
            for (n, (k, v)) in pairs.enumerated() {
                if n > 0 { out += "," }
                newline(level + 1)
                Self.quote(k, into: &out)
                out += indent == nil ? ":" : ": "
                v.write(into: &out, indent: indent, level: level + 1)
            }
            newline(level)
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", ">", "&", "\u{2028}", "\u{2029}":
                out += String(format: "\\u%04x", u.value)
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}

/// A change to apply to an `OrderedJSON` object: keys it names are set, removed or
/// merged in place; every other key (and every key's position) is left alone.
public indirect enum OrderedJSONPatch: Sendable, Equatable {
    case set(OrderedJSON)
    case remove
    case merge([(String, OrderedJSONPatch)])

    public static func == (a: OrderedJSONPatch, b: OrderedJSONPatch) -> Bool {
        switch (a, b) {
        case let (.set(x), .set(y)): return x == y
        case (.remove, .remove): return true
        case let (.merge(x), .merge(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Applies the patch. A merge into a non-object starts from an empty object;
    /// new keys are appended in patch order.
    public func apply(to value: OrderedJSON?) -> OrderedJSON? {
        switch self {
        case .set(let v): return v
        case .remove: return nil
        case .merge(let changes):
            var pairs: [(String, OrderedJSON)]
            if case .object(let existing) = value { pairs = existing } else { pairs = [] }
            for (key, change) in changes {
                let index = pairs.lastIndex { $0.0 == key }
                let current = index.map { pairs[$0].1 }
                let next = change.apply(to: current)
                switch (index, next) {
                case let (i?, v?):
                    // Edit in place; drop earlier duplicates of the key (the last one wins, as in Go).
                    pairs[i].1 = v
                    pairs = pairs.enumerated().filter { $0.offset == i || $0.element.0 != key }.map(\.element)
                case let (nil, v?): pairs.append((key, v))
                case (_?, nil): pairs.removeAll { $0.0 == key }
                case (nil, nil): break
                }
            }
            return .object(pairs)
        }
    }
}
