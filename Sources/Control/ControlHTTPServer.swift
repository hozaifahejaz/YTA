import Foundation
import Support
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// MCP's Streamable HTTP transport on 127.0.0.1 only, answering with plain JSON.
///
/// Every request needs `Authorization: Bearer <token>`; the token lives in the Keychain.
/// Requests from web pages (an `Origin` that is not this Mac) are refused, so a browser tab cannot drive YTA.
public final class ControlHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data?

    public let path = "/mcp"
    private let token: String
    private let handler: Handler
    private let maxBody = 16 * 1024 * 1024
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var boundPort: UInt16 = 0

    public init(token: String, handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    deinit { stop() }

    /// The port in use, once started.
    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener >= 0
    }

    /// Listens on 127.0.0.1. Port 0 picks a free one.
    public func start(port: UInt16) throws {
        stop()
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw YTAError(.network, "YTA could not open a socket for MCP.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw YTAError(.network, "Port \(port) is in use, so the MCP server could not start.", suggestion: "Pick another port in Settings, MCP.")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        lock.lock()
        listener = fd
        boundPort = UInt16(bigEndian: actual.sin_port)
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "YTA MCP"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    // MARK: One connection

    private func serve(_ client: Int32) {
        // Keep-alive: answer requests on this connection until the client closes it.
        var buffer = Data()
        while let request = readRequest(client, buffer: &buffer) {
            let response = respond(to: request)
            guard write(client, response.serialized) else { return }
            if request.headers["connection"]?.lowercased() == "close" { return }
        }
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var reason: String
        var headers: [String: String] = [:]
        var body = Data()

        var serialized: Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            var all = headers
            all["Content-Length"] = String(body.count)
            if all["Content-Type"] == nil, !body.isEmpty { all["Content-Type"] = "application/json" }
            for (key, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
            head += "\r\n"
            return Data(head.utf8) + body
        }
    }

    private func readRequest(_ client: Int32, buffer: inout Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.range(of: separator) == nil {
            guard buffer.count < 64 * 1024 else { return nil }
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
        guard let end = buffer.range(of: separator) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBody else { return nil }
        var body = Data(buffer[end.upperBound...])
        while body.count < length {
            let count = recv(client, &chunk, min(chunk.count, length - body.count), 0)
            guard count > 0 else { return nil }
            body.append(contentsOf: chunk[0..<count])
        }
        buffer = Data(body.dropFirst(length))
        body = Data(body.prefix(length))
        let target = String(first[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return Request(method: String(first[0]), path: path, headers: headers, body: body)
    }

    private func write(_ client: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < data.count {
                #if canImport(Glibc)
                let count = send(client, base + sent, data.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let count = send(client, base + sent, data.count - sent, 0)
                #endif
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    func respond(to request: Request) -> Response {
        if let origin = request.headers["origin"], !Self.isLocal(origin: origin) {
            return Response(status: 403, reason: "Forbidden", body: Data(#"{"error":"Requests from web pages are refused."}"#.utf8))
        }
        guard request.path == path else { return Response(status: 404, reason: "Not Found") }
        guard Self.matches(request.headers["authorization"], token: token) else {
            return Response(status: 401, reason: "Unauthorized", headers: ["WWW-Authenticate": "Bearer"],
                            body: Data(#"{"error":"Missing or wrong YTA token. Copy the setup command from YTA Settings, MCP."}"#.utf8))
        }
        switch request.method {
        case "POST":
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            let handler = self.handler
            let body = request.body
            Task.detached {
                box.value = await handler(body)
                semaphore.signal()
            }
            semaphore.wait()
            guard let reply = box.value else { return Response(status: 202, reason: "Accepted") }
            return Response(status: 200, reason: "OK", body: reply)
        case "GET", "DELETE":
            // No server-sent events and no sessions: every answer comes back on its POST.
            return Response(status: 405, reason: "Method Not Allowed", headers: ["Allow": "POST"])
        default:
            return Response(status: 405, reason: "Method Not Allowed", headers: ["Allow": "POST"])
        }
    }

    static func isLocal(origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    static func matches(_ header: String?, token: String) -> Bool {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let given = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count, !expected.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= given[index] ^ expected[index] }
        return difference == 0
    }

    /// A new random token: 32 bytes as hex.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Data?
}
