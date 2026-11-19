import Foundation
import Support

/// YouTube Data API v3 with the owner's key (section 7.2). Every call is charged
/// to the quota ledger before it is sent. The key is never logged or put in errors.
public struct DataAPIClient: Sendable {
    public static let base = URL(string: "https://www.googleapis.com/youtube/v3/")!

    let key: String
    let http: HTTPClient
    let ledger: QuotaLedger

    public init(key: String, http: HTTPClient, ledger: QuotaLedger) {
        self.key = key
        self.http = http
        self.ledger = ledger
    }

    // MARK: Calls

    /// One unit. Nil when no channel answers to the handle.
    public func channel(handle: String) async throws -> YouTubeChannel? {
        let response: ListResponse<APIChannel> = try await get("channels", [
            "part": "snippet,statistics,brandingSettings,contentDetails",
            "forHandle": "@\(handle)",
        ], cost: QuotaCost.list)
        return response.items?.first.map(\.record)
    }

    /// One unit.
    public func channel(id: String) async throws -> YouTubeChannel? {
        let response: ListResponse<APIChannel> = try await get("channels", [
            "part": "snippet,statistics,brandingSettings,contentDetails",
            "id": id,
        ], cost: QuotaCost.list)
        return response.items?.first.map(\.record)
    }

    /// One unit per 50 videos. Returns ids newest first.
    public func uploadIDs(playlist: String, limit: Int = .max) async throws -> (ids: [String], complete: Bool) {
        var ids: [String] = []
        var token: String?
        repeat {
            var params = ["part": "contentDetails", "playlistId": playlist, "maxResults": "50"]
            if let token { params["pageToken"] = token }
            let page: ListResponse<APIPlaylistItem> = try await get("playlistItems", params, cost: QuotaCost.list)
            ids += (page.items ?? []).map(\.contentDetails.videoId)
            token = page.nextPageToken
        } while token != nil && ids.count < limit
        return (Array(ids.prefix(limit)), token == nil)
    }

    /// One unit per 50 ids.
    public func videos(ids: [String]) async throws -> [YouTubeVideo] {
        var records: [YouTubeVideo] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = ids[start..<min(start + 50, ids.count)]
            let page: ListResponse<APIVideo> = try await get("videos", [
                "part": "snippet,statistics,contentDetails",
                "id": batch.joined(separator: ","),
                "maxResults": "50",
            ], cost: QuotaCost.list)
            records += (page.items ?? []).map(\.record)
        }
        return records
    }

    /// One unit per 50 playlists.
    public func playlists(channel: String) async throws -> [YouTubePlaylist] {
        var records: [YouTubePlaylist] = []
        var token: String?
        repeat {
            var params = ["part": "snippet,contentDetails", "channelId": channel, "maxResults": "50"]
            if let token { params["pageToken"] = token }
            let page: ListResponse<APIPlaylist> = try await get("playlists", params, cost: QuotaCost.list)
            records += (page.items ?? []).map {
                YouTubePlaylist(id: $0.id, title: $0.snippet.title, itemCount: $0.contentDetails?.itemCount)
            }
            token = page.nextPageToken
        } while token != nil
        return records
    }

    public struct SearchOptions: Sendable {
        public var kind: SearchHit.Kind = .video
        public var order = "relevance"
        public var publishedAfter: Date?
        public var regionCode: String?
        public var language: String?
        public var maxResults = 50

        public init() {}
    }

    /// One hundred units.
    public func search(_ query: String, options: SearchOptions = SearchOptions()) async throws -> [SearchHit] {
        var params = [
            "part": "snippet", "q": query, "type": options.kind.rawValue,
            "order": options.order, "maxResults": String(min(50, options.maxResults)),
        ]
        if let date = options.publishedAfter { params["publishedAfter"] = Parse.isoDate.string(from: date) }
        if let region = options.regionCode { params["regionCode"] = region }
        if let language = options.language { params["relevanceLanguage"] = language }
        let page: ListResponse<APISearchResult> = try await get("search", params, cost: QuotaCost.search)
        return (page.items ?? []).compactMap(\.hit)
    }

    // MARK: Transport

    func get<T: Decodable>(_ endpoint: String, _ params: [String: String], cost: Int) async throws -> T {
        try ledger.spend(cost)
        var components = URLComponents(url: Self.base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "key", value: key)]
        let response = try await http.get(components.url!, headers: ["Accept": "application/json"])
        guard (200..<300).contains(response.status) else {
            throw mapError(response)
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw YTAError(.fileFormat, "YouTube sent an answer YTA could not read.", suggestion: "Retry. If it keeps happening, YTA will use public pages instead.")
        }
    }

    func mapError(_ response: HTTPResponse) -> YTAError {
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: response.data)
        let reasons = Set((body?.error.errors ?? []).map(\.reason) + (body?.error.details ?? []).compactMap(\.reason))
        if !reasons.isDisjoint(with: ["quotaExceeded", "dailyLimitExceeded"]) {
            ledger.markExhausted()
            return ledger.exhaustedError()
        }
        if !reasons.isDisjoint(with: ["rateLimitExceeded", "RATE_LIMIT_EXCEEDED", "userRateLimitExceeded"]) {
            return YTAError(.network, "YouTube asked YTA to slow down.", suggestion: "Wait a minute and retry.")
        }
        if !reasons.isDisjoint(with: ["keyInvalid", "API_KEY_INVALID", "accessNotConfigured", "SERVICE_DISABLED", "forbidden", "API_KEY_SERVICE_BLOCKED"])
            || response.status == 401 {
            return YTAError(.notSignedIn, "The YouTube Data API key was refused.",
                            suggestion: "Check the key in Settings and that the YouTube Data API v3 is enabled for its Google Cloud project.")
        }
        if response.status == 404 {
            return YTAError(.notFound, "YouTube has no such channel or video.")
        }
        return YTAError(.network, "YouTube answered with status \(response.status).")
    }
}

// MARK: Response shapes

struct ListResponse<Item: Decodable>: Decodable {
    let items: [Item]?
    let nextPageToken: String?
}

struct APIErrorBody: Decodable {
    struct Inner: Decodable {
        struct Reason: Decodable { let reason: String }
        struct Detail: Decodable { let reason: String? }
        let errors: [Reason]?
        let details: [Detail]?
    }
    let error: Inner
}

struct APIThumbnails: Decodable {
    struct Image: Decodable { let url: String }
    let `default`: Image?
    let medium: Image?
    let high: Image?
    let maxres: Image?

    var best: String? { (maxres ?? high ?? medium ?? `default`)?.url }
}

struct APIChannel: Decodable {
    struct Snippet: Decodable {
        let title: String
        let description: String?
        let customUrl: String?
        let publishedAt: String?
        let country: String?
        let thumbnails: APIThumbnails?
    }
    struct Statistics: Decodable {
        let viewCount: String?
        let subscriberCount: String?
        let hiddenSubscriberCount: Bool?
        let videoCount: String?
    }
    struct Branding: Decodable {
        struct Channel: Decodable { let keywords: String? }
        struct Image: Decodable { let bannerExternalUrl: String? }
        let channel: Channel?
        let image: Image?
    }
    struct Content: Decodable {
        struct Related: Decodable { let uploads: String? }
        let relatedPlaylists: Related?
    }

    let id: String
    let snippet: Snippet
    let statistics: Statistics?
    let brandingSettings: Branding?
    let contentDetails: Content?

    var record: YouTubeChannel {
        var handle = snippet.customUrl
        if handle?.hasPrefix("@") == true { handle?.removeFirst() }
        return YouTubeChannel(
            id: id, handle: handle, title: snippet.title, description: snippet.description ?? "",
            keywords: Parse.keywords(brandingSettings?.channel?.keywords), country: snippet.country,
            publishedAt: Parse.date(snippet.publishedAt), subscriberCount: Parse.int(statistics?.subscriberCount),
            subscribersHidden: statistics?.hiddenSubscriberCount ?? false, viewCount: Parse.int(statistics?.viewCount),
            videoCount: Parse.int(statistics?.videoCount), avatarURL: snippet.thumbnails?.best,
            bannerURL: brandingSettings?.image?.bannerExternalUrl,
            uploadsPlaylistID: contentDetails?.relatedPlaylists?.uploads)
    }
}

struct APIPlaylistItem: Decodable {
    struct Content: Decodable { let videoId: String }
    let contentDetails: Content
}

struct APIPlaylist: Decodable {
    struct Snippet: Decodable { let title: String }
    struct Content: Decodable { let itemCount: Int? }
    let id: String
    let snippet: Snippet
    let contentDetails: Content?
}

struct APIVideo: Decodable {
    struct Snippet: Decodable {
        let title: String
        let description: String?
        let tags: [String]?
        let publishedAt: String?
        let channelId: String?
        let channelTitle: String?
        let thumbnails: APIThumbnails?
    }
    struct Statistics: Decodable {
        let viewCount: String?
        let likeCount: String?
        let commentCount: String?
    }
    struct Content: Decodable { let duration: String? }

    let id: String
    let snippet: Snippet
    let statistics: Statistics?
    let contentDetails: Content?

    var record: YouTubeVideo {
        YouTubeVideo(
            id: id, title: snippet.title, description: snippet.description ?? "", tags: snippet.tags ?? [],
            durationSeconds: contentDetails?.duration.flatMap(Parse.duration), viewCount: Parse.int(statistics?.viewCount),
            likeCount: Parse.int(statistics?.likeCount), commentCount: Parse.int(statistics?.commentCount),
            publishedAt: Parse.date(snippet.publishedAt), channelID: snippet.channelId,
            channelTitle: snippet.channelTitle, thumbnailURL: snippet.thumbnails?.best)
    }
}

struct APISearchResult: Decodable {
    struct ID: Decodable {
        let kind: String
        let videoId: String?
        let channelId: String?
    }
    struct Snippet: Decodable {
        let title: String
        let channelId: String?
        let channelTitle: String?
        let publishedAt: String?
    }
    let id: ID
    let snippet: Snippet

    var hit: SearchHit? {
        if let video = id.videoId {
            return SearchHit(kind: .video, id: video, title: snippet.title, channelID: snippet.channelId,
                             channelTitle: snippet.channelTitle, publishedAt: Parse.date(snippet.publishedAt))
        }
        if let channel = id.channelId {
            return SearchHit(kind: .channel, id: channel, title: snippet.title, channelID: channel,
                             channelTitle: snippet.channelTitle, publishedAt: Parse.date(snippet.publishedAt))
        }
        return nil
    }
}
