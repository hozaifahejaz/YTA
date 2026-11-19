import Foundation
import Support

public struct PageResult: Sendable {
    public let status: Int
    public let html: String

    public init(status: Int, html: String) {
        self.status = status
        self.html = html
    }
}

/// Loads one public YouTube page. The app uses an offscreen web view;
/// the command-line check and tests use plain HTTP.
public protocol PageSource: Sendable {
    func load(_ url: URL) async throws -> PageResult
}

/// Plain HTTP page loads, in English, for the command-line check.
public struct HTTPPageSource: PageSource {
    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTP()) {
        self.http = http
    }

    public func load(_ url: URL) async throws -> PageResult {
        let response = try await http.get(url, headers: [
            "Accept-Language": "en-US,en;q=0.8",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        ])
        return PageResult(status: response.status, html: String(decoding: response.data, as: UTF8.self))
    }
}

/// Lets one page through every few seconds, however many callers ask (section 7.2).
public actor PacedPageSource: PageSource {
    let inner: PageSource
    let interval: Duration
    let clock: ContinuousClock
    private var nextSlot: ContinuousClock.Instant?

    public init(_ inner: PageSource, interval: Duration = .seconds(3)) {
        self.inner = inner
        self.interval = interval
        self.clock = ContinuousClock()
    }

    public func load(_ url: URL) async throws -> PageResult {
        let now = clock.now
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot + interval
        if slot > now { try await clock.sleep(until: slot) }
        return try await inner.load(url)
    }
}

/// The fallback reader: public pages, slow and lower confidence.
public struct PageReader: Sendable {
    let pages: PageSource

    public init(pages: PageSource) {
        self.pages = pages
    }

    static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://www.youtube.com")!
        components.percentEncodedPath = path
        components.queryItems = query + [URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "gl", value: "US")]
        return components.url!
    }

    static func handlePath(_ handle: String) -> String {
        "/@" + (handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)
    }

    /// Nil when the page does not exist.
    func data(at path: String) async throws -> JSONValue? {
        let result = try await pages.load(Self.url(path))
        if result.status == 404 { return nil }
        guard (200..<300).contains(result.status) else {
            throw YTAError(.network, "YouTube answered with status \(result.status).")
        }
        guard let data = PageData.embedded("ytInitialData", in: result.html) else {
            throw YTAError(.fileFormat, "The YouTube page did not hold the data YTA reads.",
                           suggestion: "YouTube may have changed its pages. Add a YouTube Data API key in Settings.")
        }
        return data
    }

    public func channel(handle: String) async throws -> YouTubeChannel? {
        guard let data = try await data(at: Self.handlePath(handle)) else { return nil }
        return PageData.channel(from: data)
    }

    public func channel(id: String) async throws -> YouTubeChannel? {
        guard let data = try await data(at: "/channel/\(id)") else { return nil }
        return PageData.channel(from: data)
    }

    public func channel(legacyName name: String) async throws -> YouTubeChannel? {
        guard let data = try await data(at: "/c/\(name)") else { return nil }
        return PageData.channel(from: data)
    }

    public func channelID(forVideo id: String) async throws -> String? {
        let result = try await pages.load(Self.url("/watch", query: [URLQueryItem(name: "v", value: id)]))
        guard (200..<300).contains(result.status) else { return nil }
        return PageData.channelID(fromWatchPage: result.html)
    }

    /// The latest videos and Shorts the channel's tabs show without scrolling.
    public func recentUploads(of channel: YouTubeChannel) async throws -> [YouTubeVideo] {
        let base = channel.handle.map(Self.handlePath) ?? "/channel/\(channel.id)"
        var videos: [YouTubeVideo] = []
        for tab in ["videos", "shorts"] {
            guard let data = try await data(at: "\(base)/\(tab)") else { continue }
            let found = PageData.videos(from: data, channel: channel)
            videos += found.filter { video in !videos.contains { $0.id == video.id } }
        }
        return videos
    }
}
