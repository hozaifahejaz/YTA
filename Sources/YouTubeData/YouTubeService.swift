import ChannelStore
import Foundation
import Support

/// One entry point for YouTube data. Uses the Data API when a key is set and quota
/// remains, and public pages otherwise (section 7.2). Results say which was used.
public struct YouTubeService: Sendable {
    let key: @Sendable () -> String?
    public let ledger: QuotaLedger
    let http: HTTPClient
    let reader: PageReader
    let now: @Sendable () -> Date

    public init(key: @escaping @Sendable () -> String?, ledger: QuotaLedger, http: HTTPClient = URLSessionHTTP(),
                pages: PageSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.key = key
        self.ledger = ledger
        self.http = http
        self.reader = PageReader(pages: pages)
        self.now = now
    }

    /// The API client, or nil when there is no key or today's quota is gone.
    func api(units: Int = QuotaCost.list) -> DataAPIClient? {
        guard let key = key(), !key.isEmpty, ledger.usage().remaining >= units else { return nil }
        return DataAPIClient(key: key, http: http, ledger: ledger)
    }

    public var willUseAPI: Bool { api() != nil }

    // MARK: Handle check

    public func checkHandle(_ raw: String) async throws -> HandleCheck {
        guard let handle = ChannelLink.normalisedHandle(raw) else {
            throw YTAError(.checkFailed, "\"\(raw)\" is not a valid handle.",
                           suggestion: "Handles are 3 to 30 letters, digits, underscores, hyphens or periods.")
        }
        if let api = api() {
            do {
                let channel = try await api.channel(handle: handle)
                return HandleCheck(handle: handle, status: channel == nil ? .looksFree : .taken,
                                   channel: channel, source: .api, checkedAt: now())
            } catch let error as YTAError where error.kind == .quotaExhausted {
                // Fall through to the page.
            }
        }
        let channel = try await reader.channel(handle: handle)
        return HandleCheck(handle: handle, status: channel == nil ? .looksFree : .taken,
                           channel: channel, source: .page, checkedAt: now())
    }

    // MARK: Same-name channels

    /// Channels whose name is close to `name`, with size and last upload (section 7.3, step 3).
    /// The API path costs about 100 units plus 1 per match; it is used only when that much is left.
    public func searchChannels(_ name: String, limit: Int = 5) async throws -> [ChannelMatch] {
        if let api = api(units: QuotaCost.search + 1 + limit) {
            do {
                var options = DataAPIClient.SearchOptions()
                options.kind = .channel
                options.maxResults = limit
                let hits = try await api.search(name, options: options)
                let channels = try await api.channels(ids: hits.map(\.id))
                var matches: [ChannelMatch] = []
                for channel in channels {
                    var days: Int?
                    if let uploads = channel.uploadsPlaylistID, (channel.videoCount ?? 1) > 0,
                       let date = try await api.newestUploadDate(playlist: uploads) {
                        days = max(0, Int(now().timeIntervalSince(date) / 86_400))
                    }
                    matches.append(ChannelMatch(id: channel.id, title: channel.title, handle: channel.handle,
                                                subscriberCount: channel.subscribersHidden ? nil : channel.subscriberCount,
                                                lastUploadDays: days, source: .api))
                }
                return matches
            } catch let error as YTAError where error.kind == .quotaExhausted {
                // Fall through to pages.
            }
        }
        var matches = Array(try await reader.searchChannels(name).prefix(limit))
        for index in matches.indices {
            matches[index].lastUploadDays = try await reader.newestUploadDays(channelID: matches[index].id)
        }
        return matches
    }

    // MARK: Resolve a link

    public func resolve(_ input: String) async throws -> (channel: YouTubeChannel, source: DataSource) {
        guard let link = ChannelLink.parse(input) else {
            throw YTAError(.checkFailed, "That does not look like a YouTube handle or link.",
                           suggestion: "Paste a handle like @name, a channel link or a video link.")
        }
        if let api = api() {
            do {
                if let channel = try await resolveWithAPI(link, api) { return (channel, .api) }
                throw YTAError(.notFound, "No YouTube channel matches \(input).")
            } catch let error as YTAError where error.kind == .quotaExhausted {
                // Fall through to the page.
            }
        }
        if let channel = try await resolveWithPages(link) { return (channel, .page) }
        throw YTAError(.notFound, "No YouTube channel matches \(input).")
    }

    func resolveWithAPI(_ link: ChannelLink, _ api: DataAPIClient) async throws -> YouTubeChannel? {
        switch link {
        case .handle(let handle): return try await api.channel(handle: handle)
        case .channelID(let id): return try await api.channel(id: id)
        case .video(let id):
            guard let owner = try await api.videos(ids: [id]).first?.channelID else { return nil }
            return try await api.channel(id: owner)
        case .legacyName(let name):
            // The API cannot look these up; the page knows the channel id.
            guard let id = try await reader.channel(legacyName: name)?.id else { return nil }
            return try await api.channel(id: id)
        }
    }

    func resolveWithPages(_ link: ChannelLink) async throws -> YouTubeChannel? {
        switch link {
        case .handle(let handle): return try await reader.channel(handle: handle)
        case .channelID(let id): return try await reader.channel(id: id)
        case .legacyName(let name): return try await reader.channel(legacyName: name)
        case .video(let id):
            guard let owner = try await reader.channelID(forVideo: id) else { return nil }
            return try await reader.channel(id: owner)
        }
    }

    // MARK: Snapshot

    /// Units a full API snapshot needs: the channel, uploads and video pages, and playlists.
    public static func snapshotCost(videoCount: Int) -> Int {
        let pages = max(1, (videoCount + 49) / 50)
        return 1 + pages * 2 + 1
    }

    /// The channel's public record (section 7.8, step 2).
    public func snapshot(_ input: String, maxVideos: Int = 5_000) async throws -> ChannelSnapshot {
        let (channel, source) = try await resolve(input)
        var notes: [String] = []

        if source == .api, let api = api(units: Self.snapshotCost(videoCount: min(channel.videoCount ?? 0, maxVideos))) {
            do {
                var videos: [YouTubeVideo] = []
                var complete = true
                if let uploads = channel.uploadsPlaylistID {
                    let listed = try await api.uploadIDs(playlist: uploads, limit: maxVideos)
                    videos = try await api.videos(ids: listed.ids)
                    complete = listed.complete
                }
                let playlists = try await api.playlists(channel: channel.id)
                if !complete { notes.append("Stopped at the newest \(maxVideos) uploads.") }
                return ChannelSnapshot(takenAt: now(), source: .api, channel: channel, playlists: playlists,
                                       videos: videos, complete: complete, notes: notes)
            } catch let error as YTAError where error.kind == .quotaExhausted {
                notes.append("The API quota ran out part way, so the uploads were read from public pages.")
            }
        } else if source == .api {
            notes.append("Not enough API quota left today for every upload, so they were read from public pages.")
        }

        let videos = try await reader.recentUploads(of: channel)
        if videos.count < (channel.videoCount ?? 0) {
            notes.append("Public pages show only the latest \(videos.count) of \(channel.videoCount ?? 0) uploads.")
        }
        notes.append("Upload dates, likes, tags and descriptions are not on public listing pages.")
        return ChannelSnapshot(takenAt: now(), source: source == .api ? .api : .page, channel: channel,
                               videos: videos, complete: videos.count >= (channel.videoCount ?? Int.max), notes: notes)
    }
}

/// Dated snapshots kept in the channel's research folder ("Dated and kept", section 7.8).
public struct SnapshotStore {
    public static let folder = "\(ChannelLayout.research)/snapshots"
    let channel: ChannelFolder

    public init(channel: ChannelFolder) {
        self.channel = channel
    }

    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return "\(formatter.string(from: date)).json"
    }

    @discardableResult
    public func save(_ snapshot: ChannelSnapshot) throws -> String {
        let path = "\(Self.folder)/\(Self.fileName(for: snapshot.takenAt))"
        try channel.writeJSON(snapshot, to: path, source: "snapshot")
        return path
    }

    /// Newest first.
    public func all() -> [ChannelSnapshot] {
        guard let url = try? channel.url(Self.folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted(by: >)
            .compactMap { try? channel.readJSON(ChannelSnapshot.self, "\(Self.folder)/\($0)") }
    }

    public func latest() -> ChannelSnapshot? { all().first }
}
