import Foundation

/// Where a piece of YouTube data came from. Page data is labelled lower confidence (section 7.2).
public enum DataSource: String, Codable, Sendable {
    case api
    case page

    public var confidenceLabel: String {
        switch self {
        case .api: "From the YouTube Data API"
        case .page: "Read from public pages, lower confidence"
        }
    }
}

public struct YouTubeChannel: Codable, Equatable, Sendable {
    public var id: String
    public var handle: String?
    public var title: String
    public var description: String
    public var keywords: [String]
    public var country: String?
    public var publishedAt: Date?
    public var subscriberCount: Int?
    public var subscribersHidden: Bool
    public var viewCount: Int?
    public var videoCount: Int?
    public var avatarURL: String?
    public var bannerURL: String?
    public var uploadsPlaylistID: String?

    public init(id: String, handle: String? = nil, title: String, description: String = "", keywords: [String] = [],
                country: String? = nil, publishedAt: Date? = nil, subscriberCount: Int? = nil,
                subscribersHidden: Bool = false, viewCount: Int? = nil, videoCount: Int? = nil,
                avatarURL: String? = nil, bannerURL: String? = nil, uploadsPlaylistID: String? = nil) {
        self.id = id
        self.handle = handle
        self.title = title
        self.description = description
        self.keywords = keywords
        self.country = country
        self.publishedAt = publishedAt
        self.subscriberCount = subscriberCount
        self.subscribersHidden = subscribersHidden
        self.viewCount = viewCount
        self.videoCount = videoCount
        self.avatarURL = avatarURL
        self.bannerURL = bannerURL
        self.uploadsPlaylistID = uploadsPlaylistID
    }
}

public struct YouTubeVideo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String
    public var tags: [String]
    public var durationSeconds: Int?
    public var viewCount: Int?
    public var likeCount: Int?
    public var commentCount: Int?
    public var publishedAt: Date?
    /// Page data gives only "3 weeks ago"; kept as written.
    public var publishedText: String?
    public var channelID: String?
    public var channelTitle: String?
    public var thumbnailURL: String?

    public init(id: String, title: String, description: String = "", tags: [String] = [], durationSeconds: Int? = nil,
                viewCount: Int? = nil, likeCount: Int? = nil, commentCount: Int? = nil, publishedAt: Date? = nil,
                publishedText: String? = nil, channelID: String? = nil, channelTitle: String? = nil,
                thumbnailURL: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.tags = tags
        self.durationSeconds = durationSeconds
        self.viewCount = viewCount
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.publishedAt = publishedAt
        self.publishedText = publishedText
        self.channelID = channelID
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
    }

    /// Shorts are three minutes or less.
    public var isShort: Bool? { durationSeconds.map { $0 <= 180 } }
}

public struct YouTubePlaylist: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var itemCount: Int?

    public init(id: String, title: String, itemCount: Int? = nil) {
        self.id = id
        self.title = title
        self.itemCount = itemCount
    }
}

/// The dated public record of a channel (section 7.8, step 2).
public struct ChannelSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var takenAt: Date
    public var source: DataSource
    public var channel: YouTubeChannel
    public var playlists: [YouTubePlaylist]
    public var videos: [YouTubeVideo]
    /// False when only part of the upload list could be read (page data shows the latest few dozen).
    public var complete: Bool
    public var notes: [String]

    public init(takenAt: Date, source: DataSource, channel: YouTubeChannel, playlists: [YouTubePlaylist] = [],
                videos: [YouTubeVideo], complete: Bool, notes: [String] = []) {
        self.takenAt = takenAt
        self.source = source
        self.channel = channel
        self.playlists = playlists
        self.videos = videos
        self.complete = complete
        self.notes = notes
    }

    public var medianViews: Int? {
        let views = videos.compactMap(\.viewCount).sorted()
        guard !views.isEmpty else { return nil }
        let middle = views.count / 2
        return views.count.isMultiple(of: 2) ? (views[middle - 1] + views[middle]) / 2 : views[middle]
    }
}

/// Result of checking whether a handle is free (section 7.3, step 2).
public struct HandleCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// No channel answers to it. A handle is only confirmed when claimed.
        case looksFree
        case taken
    }

    public var handle: String
    public var status: Status
    public var channel: YouTubeChannel?
    public var source: DataSource
    public var checkedAt: Date

    public init(handle: String, status: Status, channel: YouTubeChannel? = nil, source: DataSource, checkedAt: Date) {
        self.handle = handle
        self.status = status
        self.channel = channel
        self.source = source
        self.checkedAt = checkedAt
    }
}

public struct SearchHit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, channel }
    public var kind: Kind
    public var id: String
    public var title: String
    public var channelID: String?
    public var channelTitle: String?
    public var publishedAt: Date?
}

/// A channel found by searching for a name (section 7.3, step 3).
public struct ChannelMatch: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var handle: String?
    public var subscriberCount: Int?
    /// Days since the newest upload. Nil when unknown or when there are no uploads.
    public var lastUploadDays: Int?
    public var source: DataSource

    public init(id: String, title: String, handle: String? = nil, subscriberCount: Int? = nil,
                lastUploadDays: Int? = nil, source: DataSource) {
        self.id = id
        self.title = title
        self.handle = handle
        self.subscriberCount = subscriberCount
        self.lastUploadDays = lastUploadDays
        self.source = source
    }
}
