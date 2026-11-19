import Foundation
import Support

/// One thing YTA can do, described once and used by both the window and MCP clients.
///
/// Every feature the owner can reach in the app is registered as an action. The MCP server lists
/// the registry, so a new action shows up for AI clients without any other change.
public struct ControlAction: Sendable {
    public enum Kind: String, Sendable {
        /// Reads only.
        case read
        /// Changes something that can be changed back.
        case change
        /// Throws work away or deletes something.
        case destructive
    }

    public let name: String
    public let summary: String
    public let kind: Kind
    public let parameters: [Parameter]
    public let perform: @Sendable (ActionInput) async throws -> JSONValue

    public init(_ name: String, _ summary: String, kind: Kind = .change, parameters: [Parameter] = [],
                perform: @escaping @Sendable (ActionInput) async throws -> JSONValue) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.parameters = parameters
        self.perform = perform
    }

    /// The JSON Schema MCP clients read to build a call.
    public var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters { properties[parameter.name] = parameter.schema }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(parameters.filter(\.required).map { .string($0.name) }),
            "additionalProperties": .bool(false),
        ])
    }
}

/// One named argument of an action.
public struct Parameter: Sendable {
    public indirect enum Kind: Sendable, Equatable {
        case string
        case integer
        case number
        case boolean
        /// A JSON object. Used for partial updates whose keys mirror a saved file.
        case object
        case array(Kind)
        case oneOf([String])
    }

    public let name: String
    public let kind: Kind
    public let summary: String
    public let required: Bool

    public init(_ name: String, _ kind: Kind, _ summary: String, required: Bool = true) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.required = required
    }

    public static func optional(_ name: String, _ kind: Kind, _ summary: String) -> Parameter {
        Parameter(name, kind, summary, required: false)
    }

    var schema: JSONValue {
        var object = Self.schema(for: kind).objectValue ?? [:]
        object["description"] = .string(summary)
        return .object(object)
    }

    static func schema(for kind: Kind) -> JSONValue {
        switch kind {
        case .string: .object(["type": .string("string")])
        case .integer: .object(["type": .string("integer")])
        case .number: .object(["type": .string("number")])
        case .boolean: .object(["type": .string("boolean")])
        case .object: .object(["type": .string("object")])
        case .array(let item): .object(["type": .string("array"), "items": schema(for: item)])
        case .oneOf(let values): .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
        }
    }

    /// Why `value` does not fit, or nil.
    func problem(with value: JSONValue) -> String? {
        Self.problem(value, kind: kind, at: name)
    }

    private static func problem(_ value: JSONValue, kind: Kind, at path: String) -> String? {
        switch (kind, value) {
        case (.string, .string), (.boolean, .bool), (.object, .object), (.number, .number): return nil
        case (.integer, .number(let number)):
            return number.rounded() == number ? nil : "\(path) must be a whole number."
        case (.oneOf(let values), .string(let text)):
            return values.contains(text) ? nil : "\(path) must be one of: \(values.joined(separator: ", "))."
        case (.array(let item), .array(let items)):
            for (index, element) in items.enumerated() {
                if let problem = problem(element, kind: item, at: "\(path)[\(index)]") { return problem }
            }
            return nil
        default:
            return "\(path) must be \(describe(kind))."
        }
    }

    private static func describe(_ kind: Kind) -> String {
        switch kind {
        case .string, .oneOf: "text"
        case .integer: "a whole number"
        case .number: "a number"
        case .boolean: "true or false"
        case .object: "an object"
        case .array: "a list"
        }
    }
}

/// The arguments of one call, already checked against the action's parameters.
public struct ActionInput: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public subscript(name: String) -> JSONValue? {
        guard let value = values[name], value != .null else { return nil }
        return value
    }

    public func string(_ name: String) throws -> String {
        guard let value = self[name]?.stringValue else { throw ControlError.missing(name) }
        return value
    }

    public func optionalString(_ name: String) -> String? {
        self[name]?.stringValue
    }

    public func int(_ name: String) throws -> Int {
        guard let value = self[name]?.intValue else { throw ControlError.missing(name) }
        return value
    }

    public func optionalInt(_ name: String) -> Int? {
        self[name]?.intValue
    }

    public func double(_ name: String) throws -> Double {
        guard let value = self[name]?.doubleValue else { throw ControlError.missing(name) }
        return value
    }

    public func bool(_ name: String, default fallback: Bool? = nil) throws -> Bool {
        if case .bool(let value)? = self[name] { return value }
        if let fallback { return fallback }
        throw ControlError.missing(name)
    }

    public func strings(_ name: String) throws -> [String] {
        guard let items = self[name]?.arrayValue else { throw ControlError.missing(name) }
        return items.compactMap(\.stringValue)
    }

    public func object(_ name: String) throws -> [String: JSONValue] {
        guard let value = self[name]?.objectValue else { throw ControlError.missing(name) }
        return value
    }

    /// Decodes an argument into one of the app's own types.
    public func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let value = self[name] else { throw ControlError.missing(name) }
        return try value.decode(type, name: name)
    }
}

public enum ControlError: Error, Equatable, LocalizedError {
    case missing(String)
    case invalid(String)
    case unknownAction(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) is required."
        case .invalid(let text): text
        case .unknownAction(let name): "There is no action called \(name)."
        case .failed(let text): text
        }
    }
}

extension JSONValue {
    /// Any Encodable value as loose JSON, for action results.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONCoding.encoder().encode(value)
        self = try JSONCoding.decoder().decode(JSONValue.self, from: data)
    }

    public func decode<T: Decodable>(_ type: T.Type, name: String = "value") throws -> T {
        do {
            let data = try JSONCoding.encoder().encode(self)
            return try JSONCoding.decoder().decode(type, from: data)
        } catch {
            throw ControlError.invalid("\(name) has the wrong shape: \(error.localizedDescription)")
        }
    }

    /// Lays `patch` over this object, key by key, recursing into objects. Used for partial updates.
    public func merging(_ patch: [String: JSONValue]) -> JSONValue {
        var base = objectValue ?? [:]
        for (key, value) in patch {
            if case .object(let inner) = value, let existing = base[key], existing.objectValue != nil {
                base[key] = existing.merging(inner)
            } else {
                base[key] = value
            }
        }
        return .object(base)
    }

    /// Applies a partial update to a Codable value: unknown keys are refused, so typos are not lost silently.
    public static func patch<T: Codable>(_ value: T, with patch: [String: JSONValue], name: String) throws -> T {
        let current = try JSONValue(encoding: value)
        let known = Set(current.objectValue?.keys.map { $0 } ?? [])
        let unknown = patch.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty, !known.isEmpty {
            throw ControlError.invalid("\(name) has no \(unknown.joined(separator: ", ")). Known fields: \(known.sorted().joined(separator: ", ")).")
        }
        return try current.merging(patch).decode(T.self, name: name)
    }
}

/// Every action YTA offers, by name.
public final class ActionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [String: ControlAction] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ action: ControlAction) {
        lock.lock()
        defer { lock.unlock() }
        precondition(actions[action.name] == nil, "Action \(action.name) is registered twice")
        precondition(action.name.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil,
                     "Action names are lower_snake_case: \(action.name)")
        actions[action.name] = action
        order.append(action.name)
    }

    public func register(_ list: [ControlAction]) {
        for action in list { register(action) }
    }

    public var all: [ControlAction] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { actions[$0] }
    }

    public func action(_ name: String) -> ControlAction? {
        lock.lock()
        defer { lock.unlock() }
        return actions[name]
    }

    /// Checks the arguments, then runs the action.
    public func call(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let action = action(name) else { throw ControlError.unknownAction(name) }
        let known = Set(action.parameters.map(\.name))
        if let extra = arguments.keys.sorted().first(where: { !known.contains($0) }) {
            throw ControlError.invalid("\(name) takes no \(extra). It takes: \(action.parameters.map(\.name).joined(separator: ", ")).")
        }
        for parameter in action.parameters {
            guard let value = arguments[parameter.name], value != .null else {
                if parameter.required { throw ControlError.missing(parameter.name) }
                continue
            }
            if let problem = parameter.problem(with: value) { throw ControlError.invalid(problem) }
        }
        return try await action.perform(ActionInput(arguments))
    }
}
