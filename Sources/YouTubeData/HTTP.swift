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

/// The one network call the YouTube code needs. Tests swap in canned answers.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public struct URLSessionHTTP: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if error != nil {
                    // The URL can hold the API key, so the system error text is not passed on.
                    continuation.resume(throwing: YTAError(.network, "YouTube could not be reached."))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: HTTPResponse(status: status, data: data ?? Data()))
            }.resume()
        }
    }
}
