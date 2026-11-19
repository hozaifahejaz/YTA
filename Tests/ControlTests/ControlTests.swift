import Foundation
import Support
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Control

@Suite struct ControlTests {
    static func registry() -> ActionRegistry {
        let registry = ActionRegistry()
        registry.register([
            ControlAction("echo", "Says it back.", kind: .read, parameters: [
                Parameter("text", .string, "What to say"),
                .optional("times", .integer, "How often"),
            ]) { input in
                .string(String(repeating: try input.string("text"), count: input.optionalInt("times") ?? 1))
            },
            ControlAction("set_status", "Sets a status.", parameters: [Parameter("status", .oneOf(["queued", "done"]), "The status")]) { input in
                .object(["status": .string(try input.string("status"))])
            },
            ControlAction("fail", "Always fails.", kind: .destructive) { _ in throw ControlError.failed("Nope.") },
        ])
        return registry
    }

    static func server() -> MCPServer {
        MCPServer(registry: registry(), version: "1.0", instructions: "Test server")
    }

    static func call(_ server: MCPServer, _ json: String) async -> JSONValue? {
        guard let data = await server.handle(Data(json.utf8)) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func argumentsAreCheckedBeforeAnActionRuns() async throws {
        let registry = Self.registry()
        #expect(try await registry.call("echo", arguments: ["text": .string("hi"), "times": .number(2)]) == .string("hihi"))
        await #expect(throws: ControlError.missing("text")) { try await registry.call("echo") }
        await #expect(throws: ControlError.self) { try await registry.call("echo", arguments: ["text": .string("a"), "nope": .bool(true)]) }
        await #expect(throws: ControlError.self) { try await registry.call("echo", arguments: ["text": .number(3)]) }
        await #expect(throws: ControlError.self) { try await registry.call("echo", arguments: ["text": .string("a"), "times": .number(1.5)]) }
        await #expect(throws: ControlError.self) { try await registry.call("set_status", arguments: ["status": .string("lost")]) }
        await #expect(throws: ControlError.unknownAction("missing")) { try await registry.call("missing") }
    }

    @Test func schemasListEveryParameter() throws {
        let schema = try #require(Self.registry().action("echo")?.inputSchema)
        #expect(schema["required"] == .array([.string("text")]))
        #expect(schema["properties"]?["times"]?["type"] == .string("integer"))
        #expect(schema["additionalProperties"] == .bool(false))
        let status = try #require(Self.registry().action("set_status")?.inputSchema)
        #expect(status["properties"]?["status"]?["enum"] == .array([.string("queued"), .string("done")]))
    }

    @Test func mcpInitializeListAndCall() async throws {
        let server = Self.server()
        let hello = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        #expect(hello["result"]?["protocolVersion"] == .string("2025-03-26"))
        #expect(hello["result"]?["capabilities"]?["tools"] != nil)
        #expect(hello["id"] == .number(1))

        let unknownVersion = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(unknownVersion["result"]?["protocolVersion"] == .string(MCPServer.supportedVersions[0]))
        #expect(unknownVersion["id"] == .string("a"))

        #expect(await Self.call(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require(list["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["echo", "set_status", "fail"])
        #expect(tools[0]["annotations"]?["readOnlyHint"] == .bool(true))
        #expect(tools[2]["annotations"]?["destructiveHint"] == .bool(true))

        let echo = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"yo"}}}"#))
        #expect(echo["result"]?["isError"] == .bool(false))
        #expect(echo["result"]?["content"]?.arrayValue?.first?["text"] == .string("yo"))

        let status = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_status","arguments":{"status":"done"}}}"#))
        #expect(status["result"]?["structuredContent"]?["status"] == .string("done"))

        let failed = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fail"}}"#))
        #expect(failed["result"]?["isError"] == .bool(true))
        #expect(failed["result"]?["content"]?.arrayValue?.first?["text"] == .string("Nope."))

        let missing = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#))
        #expect(missing["result"]?["isError"] == .bool(true))

        let unknown = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope"}}"#))
        #expect(unknown["error"]?["code"] == .number(-32602))

        let method = try #require(await Self.call(server, #"{"jsonrpc":"2.0","id":8,"method":"sampling/whatever"}"#))
        #expect(method["error"]?["code"] == .number(-32601))

        let garbage = try #require(await Self.call(server, "not json"))
        #expect(garbage["error"]?["code"] == .number(-32700))

        let batch = try #require(await Self.call(server, #"[{"jsonrpc":"2.0","id":9,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#))
        #expect(batch.arrayValue?.count == 1)
    }

    @Test func patchesMergeAndRefuseUnknownFields() throws {
        struct Settings: Codable, Equatable {
            var name: String
            var inner: Inner
            struct Inner: Codable, Equatable { var a: Int; var b: Int }
        }
        let start = Settings(name: "x", inner: .init(a: 1, b: 2))
        let patched = try JSONValue.patch(start, with: ["inner": .object(["b": .number(5)])], name: "settings")
        #expect(patched == Settings(name: "x", inner: .init(a: 1, b: 5)))
        #expect(throws: ControlError.self) { try JSONValue.patch(start, with: ["nmae": .string("y")], name: "settings") }
        #expect(throws: ControlError.self) { try JSONValue.patch(start, with: ["name": .number(3)], name: "settings") }
    }

    @Test func httpNeedsTheTokenAndRefusesWebPages() async throws {
        let server = Self.server()
        let token = ControlHTTPServer.makeToken()
        #expect(token.count == 64)
        let http = ControlHTTPServer(token: token) { await server.handle($0) }
        try http.start(port: 0)
        defer { http.stop() }
        let port = http.port
        #expect(port > 0)

        func post(_ body: String, auth: String? = "Bearer \(token)", origin: String? = nil, path: String = "/mcp") async throws -> (Int, Data) {
            var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nConnection: close\r\n"
            if let auth { head += "Authorization: \(auth)\r\n" }
            if let origin { head += "Origin: \(origin)\r\n" }
            head += "Content-Length: \(body.utf8.count)\r\n\r\n"
            return try RawHTTP.send(Data(head.utf8) + Data(body.utf8), port: port)
        }

        let ping = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"over http"}}}"#
        let (status, data) = try await post(ping)
        #expect(status == 200)
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"] == .string("over http"))

        #expect(try await post(ping, auth: nil).0 == 401)
        #expect(try await post(ping, auth: "Bearer wrong").0 == 401)
        #expect(try await post(ping, origin: "https://evil.example").0 == 403)
        #expect(try await post(ping, origin: "http://localhost:3000").0 == 200)
        #expect(try await post(ping, path: "/other").0 == 404)
        #expect(try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0 == 202)

        // A second request on a fresh connection still works, and a big body arrives whole.
        let big = String(repeating: "a", count: 300_000)
        let (bigStatus, bigData) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"\#(big)"}}}"#)
        #expect(bigStatus == 200)
        let bigReply = try JSONDecoder().decode(JSONValue.self, from: bigData)
        #expect(bigReply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.count == 300_000)
    }

    @Test func onlyLocalOriginsCount() {
        #expect(ControlHTTPServer.isLocal(origin: "http://127.0.0.1:5000"))
        #expect(ControlHTTPServer.isLocal(origin: "http://localhost"))
        #expect(!ControlHTTPServer.isLocal(origin: "https://localhost.evil.com"))
        #expect(!ControlHTTPServer.isLocal(origin: "null"))
        #expect(ControlHTTPServer.matches("Bearer abc", token: "abc"))
        #expect(ControlHTTPServer.matches("bearer abc", token: "abc"))
        #expect(!ControlHTTPServer.matches("Bearer abcd", token: "abc"))
        #expect(!ControlHTTPServer.matches(nil, token: "abc"))
    }
}

/// A bare HTTP/1.1 client, so the test does not depend on URLSession or the machine's proxy settings.
enum RawHTTP {
    static func send(_ request: Data, port: UInt16) throws -> (Int, Data) {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw ControlError.failed("connect failed") }
        _ = request.withUnsafeBytes { raw in
            var sent = 0
            while sent < request.count {
                let count = Foundation.send(fd, raw.baseAddress! + sent, request.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
        }
        guard let end = response.range(of: Data("\r\n\r\n".utf8)) else { throw ControlError.failed("no response") }
        let head = String(decoding: response[..<end.lowerBound], as: UTF8.self)
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, Data(response[end.upperBound...]))
    }
}
