import Foundation
import Support

/// The Model Context Protocol over JSON-RPC 2.0: `initialize`, `ping`, `tools/list` and `tools/call`.
/// Each registered action is one MCP tool.
public struct MCPServer: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let registry: ActionRegistry
    public let name: String
    public let version: String
    public let instructions: String

    public init(registry: ActionRegistry, name: String = "yta", version: String, instructions: String) {
        self.registry = registry
        self.name = name
        self.version = version
        self.instructions = instructions
    }

    /// Handles one HTTP body: a request, a notification, or a batch. Nil means "no response body".
    public func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONCoding.decoder().decode(JSONValue.self, from: body) else {
            return encode(Self.error(id: .null, code: -32700, message: "The body is not JSON."))
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await respond(to: item) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : encode(.array(replies))
        }
        return await respond(to: message).map(encode)
    }

    public func respond(to message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue, let method = object["method"]?.stringValue else {
            // Responses from the client (we never ask it anything) and junk get no reply.
            if message["id"] != nil, message["result"] == nil, message["error"] == nil {
                return Self.error(id: message["id"] ?? .null, code: -32600, message: "Not a JSON-RPC request.")
            }
            return nil
        }
        guard let id = object["id"] else { return nil }  // A notification.
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "title": .string("YTA"), "version": .string(self.version)]),
                "instructions": .string(instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(registry.all.map(Self.describe))])
        case "tools/call":
            guard let tool = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "tools/call needs a name.")
            }
            guard registry.action(tool) != nil else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(tool)")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            do {
                let value = try await registry.call(tool, arguments: arguments)
                var result: [String: JSONValue] = ["content": .array([Self.text(Self.pretty(value))]), "isError": .bool(false)]
                if value.objectValue != nil { result["structuredContent"] = value }
                return Self.result(id: id, result)
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? (error as? YTAError)?.message ?? "\(error)"
                return Self.result(id: id, ["content": .array([Self.text(text)]), "isError": .bool(true)])
            }
        case "resources/list":
            return Self.result(id: id, ["resources": .array([])])
        case "prompts/list":
            return Self.result(id: id, ["prompts": .array([])])
        default:
            return Self.error(id: id, code: -32601, message: "Unknown method: \(method)")
        }
    }

    static func describe(_ action: ControlAction) -> JSONValue {
        .object([
            "name": .string(action.name),
            "description": .string(action.summary),
            "inputSchema": action.inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(action.kind == .read),
                "destructiveHint": .bool(action.kind == .destructive),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    static func text(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    static func pretty(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        guard let data = try? JSONCoding.encoder().encode(value) else { return value.compactString }
        return String(decoding: data, as: UTF8.self)
    }

    static func result(id: JSONValue, _ result: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(result)])
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    private func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
