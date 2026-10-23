import Foundation

/// Shared JSON coders for the PlatyNotch wire protocol. Keys are mapped with explicit
/// CodingKeys on each model (not a key strategy) so free-form payloads such as
/// `Limits.extra` and raw envelope data keep their original keys.
public enum JSONCoding {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid RFC 3339 date: \(s)"))
            }
            return date
        }
        return d
    }

    /// Encodes dates as Go does: RFC 3339 UTC, fractional seconds only when non-zero.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }

    static func parseDate(_ s: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        let whole = date.timeIntervalSince1970.rounded(.down)
        let hasFraction = date.timeIntervalSince1970 - whole >= 0.0005
        f.formatOptions = hasFraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.string(from: hasFraction ? date : Date(timeIntervalSince1970: whole))
    }
}

/// Arbitrary JSON value, used for opaque payloads (`Envelope.data`, `Approval.input`, ...).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Raw JSON payload that round-trips structurally and can be decoded into a typed model later.
public struct RawJSON: Codable, Sendable, Equatable {
    public var value: JSONValue

    public init(_ value: JSONValue) { self.value = value }

    public init<T: Encodable>(encoding payload: T) throws {
        let data = try JSONCoding.encoder.encode(payload)
        self.value = try JSONValue.parse(data)
    }

    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }

    public func data() throws -> Data { try JSONCoding.encoder.encode(value) }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: data())
    }
}
