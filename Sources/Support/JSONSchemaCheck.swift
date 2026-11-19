import Foundation

/// A small JSON Schema checker for LLM results (section 5.2).
/// Covers the keywords YTA's own schemas use: type, properties, required,
/// additionalProperties (false), items, enum, minItems, maxItems, minLength, maxLength,
/// minimum, maximum. Anything else is ignored.
public enum JSONSchemaCheck {
    /// Returns the problems found, empty when the value fits the schema.
    public static func problems(in value: JSONValue, against schema: JSONValue, at path: String = "$") -> [String] {
        guard case .object(let s) = schema else { return [] }
        var found: [String] = []

        if case .array(let options)? = s["enum"], !options.contains(value) {
            found.append("\(path) is not one of the allowed values")
        }

        if let type = s["type"] {
            let allowed: [String]
            switch type {
            case .string(let t): allowed = [t]
            case .array(let list): allowed = list.compactMap { if case .string(let t) = $0 { t } else { nil } }
            default: allowed = []
            }
            if !allowed.isEmpty, !allowed.contains(where: { matches(value, type: $0) }) {
                found.append("\(path) should be \(allowed.joined(separator: " or "))")
                return found
            }
        }

        switch value {
        case .object(let object):
            if case .array(let required)? = s["required"] {
                for case .string(let key) in required where object[key] == nil || object[key] == .null {
                    found.append("\(path).\(key) is missing")
                }
            }
            let properties = s["properties"]?.objectValue ?? [:]
            for (key, child) in object {
                if let childSchema = properties[key] {
                    found += problems(in: child, against: childSchema, at: "\(path).\(key)")
                } else if s["additionalProperties"] == .bool(false) {
                    found.append("\(path).\(key) is not expected")
                }
            }
        case .array(let items):
            if let min = s["minItems"]?.intValue, items.count < min { found.append("\(path) needs at least \(min) items") }
            if let max = s["maxItems"]?.intValue, items.count > max { found.append("\(path) allows at most \(max) items") }
            if let itemSchema = s["items"] {
                for (index, item) in items.enumerated() {
                    found += problems(in: item, against: itemSchema, at: "\(path)[\(index)]")
                }
            }
        case .string(let text):
            if let min = s["minLength"]?.intValue, text.count < min { found.append("\(path) is shorter than \(min) characters") }
            if let max = s["maxLength"]?.intValue, text.count > max { found.append("\(path) is longer than \(max) characters") }
        case .number(let number):
            if case .number(let min)? = s["minimum"], number < min { found.append("\(path) is below \(min)") }
            if case .number(let max)? = s["maximum"], number > max { found.append("\(path) is above \(max)") }
        default:
            break
        }
        return found
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number):
            return true
        case ("integer", .number(let n)):
            return n.rounded() == n
        default:
            return false
        }
    }

    /// Pulls a JSON value out of model text: the whole text, a fenced block, or the outermost braces.
    public static func extractJSON(from text: String) -> JSONValue? {
        let decoder = JSONCoding.decoder()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? decoder.decode(JSONValue.self, from: Data(trimmed.utf8)) { return value }
        if let fence = trimmed.range(of: "```"),
           let end = trimmed.range(of: "```", range: fence.upperBound..<trimmed.endIndex) {
            var inner = String(trimmed[fence.upperBound..<end.lowerBound])
            if let newline = inner.firstIndex(of: "\n"), !inner[..<newline].contains("{") { inner = String(inner[inner.index(after: newline)...]) }
            if let value = try? decoder.decode(JSONValue.self, from: Data(inner.utf8)) { return value }
        }
        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close {
            if let value = try? decoder.decode(JSONValue.self, from: Data(trimmed[open...close].utf8)) { return value }
        }
        return nil
    }
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Compact JSON text.
    public var compactString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }

    public static func parse(_ text: String) -> JSONValue? {
        try? JSONCoding.decoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
