import Foundation

/// Shared JSON settings. Files are pretty printed with sorted keys so diffs stay readable.
public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A loosely typed JSON value. Used to keep fields the app does not know about,
/// so a newer or hand-edited file never loses data when the app writes it back.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

public enum JSONMerge {
    /// Encodes `value` and lays it over `existing`, so keys the app does not model survive.
    public static func encodePreserving<T: Encodable>(_ value: T, over existing: Data?) throws -> Data {
        let encoder = JSONCoding.encoder()
        let fresh = try JSONCoding.decoder().decode(JSONValue.self, from: encoder.encode(value))
        guard
            let existing,
            case .object(var base)? = try? JSONCoding.decoder().decode(JSONValue.self, from: existing),
            case .object(let overlay) = fresh
        else {
            return try encoder.encode(fresh)
        }
        for (key, value) in overlay { base[key] = value }
        return try encoder.encode(JSONValue.object(base))
    }
}
