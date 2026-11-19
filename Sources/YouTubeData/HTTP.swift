import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Support

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data

    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }
}

/// The network calls the app's clients need. Tests swap in canned answers.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse
}

extension HTTPClient {
    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        throw YTAError(.network, "This client cannot send.")
    }
}

/// `multipart/form-data` for services that take form fields.
public struct FormData: Sendable {
    public let boundary = "YTA-" + UUID().uuidString
    public var fields: [(String, String)] = []

    public init(_ fields: [(String, String)]) {
        self.fields = fields
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public var body: Data {
        var text = ""
        for (name, value) in fields {
            text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }
}

public struct URLSessionHTTP: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await send(URLRequest(url: url, timeoutInterval: 30), headers: headers)
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        return try await send(request, headers: headers)
    }

    func send(_ request: URLRequest, headers: [String: String]) async throws -> HTTPResponse {
        var request = request
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let host = request.url?.host ?? "The service"
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if error != nil {
                    // The URL can hold an API key, so the system error text is not passed on.
                    continuation.resume(throwing: YTAError(.network, "\(host) could not be reached."))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: HTTPResponse(status: status, data: data ?? Data()))
            }.resume()
        }
    }
}
