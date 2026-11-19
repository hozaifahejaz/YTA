import Foundation
import Support

/// What YouTube returned for one niche candidate's searches, kept as evidence (section 7.1, stage 4).
public struct NicheSample: Codable, Equatable, Sendable {
    public var queries: [String]
    public var videos: [YouTubeVideo]
    /// Channels behind the videos, as far as they could be read.
    public var channels: [YouTubeChannel]
    public var source: DataSource
    public var fetchedAt: Date
    public var notes: [String]

    public init(queries: [String], videos: [YouTubeVideo], channels: [YouTubeChannel], source: DataSource,
                fetchedAt: Date, notes: [String] = []) {
        self.queries = queries
        self.videos = videos
        self.channels = channels
        self.source = source
        self.fetchedAt = fetchedAt
        self.notes = notes
    }

    /// Age of a video in days, from its date or from the page's "3 weeks ago".
    func ageDays(_ video: YouTubeVideo) -> Int? {
        if let date = video.publishedAt { return max(0, Int(fetchedAt.timeIntervalSince(date) / 86_400)) }
        return video.publishedText.flatMap(Parse.ageDays)
    }
}

/// The app-computed measures of section 7.1. Nil means YouTube did not give enough to say.
public struct NicheMeasures: Codable, Equatable, Sendable {
    /// Median views of videos from the last 12 months.
    public var medianRecentViews: Int?
    public var recentVideoCount: Int
    /// Share of strong videos (at least twice the median) made by channels under 50,000 subscribers.
    public var strongFromSmallShare: Double?
    public var strongVideoCount: Int
    /// Distinct channels with a video in the last 90 days.
    public var activeChannels: Int
    /// Share of all views in the sample that went to the three biggest channels.
    public var topThreeShare: Double?
    /// Channels under a year old already past 10,000 subscribers. Nil when join dates were not available.
    public var newChannelsPast10k: Int?
    /// Median length of long-form videos, in minutes.
    public var typicalMinutes: Double?
    public var shortsShare: Double?
    public var sampleSize: Int
    /// How many of the sample's channels have a known subscriber count.
    public var channelsWithSubscribers: Int

    public static let smallChannel = 50_000
    public static let strongMultiple = 2.0

    public static func compute(_ sample: NicheSample) -> NicheMeasures {
        let videos = sample.videos
        let channelsByID = Dictionary(sample.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let recent = videos.filter { (sample.ageDays($0) ?? .max) <= 365 }
        let recentViews = recent.compactMap(\.viewCount)
        let median = Self.median(recentViews)

        var strongFromSmall: Double?
        var strongCount = 0
        if let median {
            let strong = recent.filter { Double($0.viewCount ?? 0) >= Double(median) * strongMultiple && ($0.viewCount ?? 0) > 0 }
            strongCount = strong.count
            let known = strong.compactMap { video -> Bool? in
                guard let id = video.channelID, let subs = channelsByID[id]?.subscriberCount else { return nil }
                return subs < smallChannel
            }
            if !known.isEmpty { strongFromSmall = Double(known.filter { $0 }.count) / Double(known.count) }
        }

        let active = Set(videos.filter { (sample.ageDays($0) ?? .max) <= 90 }.compactMap(\.channelID)).count

        var viewsByChannel: [String: Int] = [:]
        for video in videos {
            guard let id = video.channelID, let views = video.viewCount else { continue }
            viewsByChannel[id, default: 0] += views
        }
        let total = viewsByChannel.values.reduce(0, +)
        let topThree = viewsByChannel.values.sorted(by: >).prefix(3).reduce(0, +)

        var newChannels: Int?
        let dated = sample.channels.filter { $0.publishedAt != nil }
        if !dated.isEmpty {
            newChannels = dated.filter { channel in
                guard let date = channel.publishedAt, let subs = channel.subscriberCount else { return false }
                return sample.fetchedAt.timeIntervalSince(date) <= 365 * 86_400 && subs >= 10_000
            }.count
        }

        let timed = videos.filter { $0.durationSeconds != nil }
        let long = timed.filter { $0.isShort == false }.compactMap(\.durationSeconds)
        return NicheMeasures(
            medianRecentViews: median, recentVideoCount: recent.count,
            strongFromSmallShare: strongFromSmall, strongVideoCount: strongCount,
            activeChannels: active,
            topThreeShare: total > 0 ? Double(topThree) / Double(total) : nil,
            newChannelsPast10k: newChannels,
            typicalMinutes: Self.median(long).map { Double($0) / 60 },
            shortsShare: timed.isEmpty ? nil : Double(timed.filter { $0.isShort == true }.count) / Double(timed.count),
            sampleSize: videos.count,
            channelsWithSubscribers: sample.channels.filter { $0.subscriberCount != nil }.count
        )
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Every measure as a plain line with its key, for prompts and for evidence checks.
    public var lines: [(key: String, text: String)] {
        func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown" }
        return [
            ("medianRecentViews", "Median views of videos from the last 12 months: \(medianRecentViews.map(String.init) ?? "unknown") (\(recentVideoCount) videos)"),
            ("strongFromSmallShare", "Strong videos (2× median or more) made by channels under 50,000 subscribers: \(percent(strongFromSmallShare)) of \(strongVideoCount)"),
            ("activeChannels", "Channels with a video in the last 90 days: \(activeChannels)"),
            ("topThreeShare", "Share of views going to the three biggest channels: \(percent(topThreeShare))"),
            ("newChannelsPast10k", "Channels under a year old past 10,000 subscribers: \(newChannelsPast10k.map(String.init) ?? "unknown (join dates need the API)")"),
            ("typicalMinutes", "Typical long-form length: \(typicalMinutes.map { String(format: "%.0f minutes", $0) } ?? "unknown")"),
            ("shortsShare", "Share of Shorts in results: \(percent(shortsShare))"),
        ]
    }

    public static let keys = ["medianRecentViews", "strongFromSmallShare", "activeChannels", "topThreeShare",
                              "newChannelsPast10k", "typicalMinutes", "shortsShare"]
}

extension YouTubeService {
    /// Units an API sample needs: one search and one video list per query, plus channel lists.
    public static func sampleCost(queries: Int) -> (searches: Int, lists: Int) {
        (queries, queries + 1)
    }

    /// Whether today's API quota can finish a research run. True when no key is set, because pages are used then.
    public func canSample(queries: Int) -> Bool {
        guard let key = key(), !key.isEmpty else { return true }
        let cost = Self.sampleCost(queries: queries)
        return ledger.canFinish(searches: cost.searches, lists: cost.lists)
    }

    /// Searches YouTube for each query and reads the channels behind the results.
    public func sample(queries: [String], region: String?, language: String?, perQuery: Int = 25,
                       pageChannelLimit: Int = 12) async throws -> NicheSample {
        let cost = Self.sampleCost(queries: queries.count)
        if let api = api(units: cost.searches * QuotaCost.search + cost.lists) {
            do {
                var videos: [YouTubeVideo] = []
                for query in queries {
                    var options = DataAPIClient.SearchOptions()
                    options.kind = .video
                    options.regionCode = region
                    options.language = language
                    options.maxResults = perQuery
                    let hits = try await api.search(query, options: options)
                    let found = try await api.videos(ids: hits.map(\.id).filter { id in !videos.contains { $0.id == id } })
                    videos += found
                }
                let ids = Array(Set(videos.compactMap(\.channelID))).sorted()
                var channels: [YouTubeChannel] = []
                for start in stride(from: 0, to: ids.count, by: 50) {
                    channels += try await api.channels(ids: Array(ids[start..<min(ids.count, start + 50)]))
                }
                return NicheSample(queries: queries, videos: videos, channels: channels, source: .api, fetchedAt: now())
            } catch let error as YTAError where error.kind == .quotaExhausted {
                // Fall through to pages.
            }
        }
        var videos: [YouTubeVideo] = []
        for query in queries {
            let found = try await reader.searchVideos(query)
            videos += found.filter { video in !videos.contains { $0.id == video.id } }
        }
        // Pages give subscriber counts one channel at a time, so only the channels with the most views are read.
        var viewsByChannel: [String: Int] = [:]
        for video in videos { if let id = video.channelID { viewsByChannel[id, default: 0] += video.viewCount ?? 0 } }
        let top = viewsByChannel.sorted { $0.value > $1.value }.prefix(pageChannelLimit).map(\.key)
        var channels: [YouTubeChannel] = []
        for id in top {
            if let channel = try await reader.channel(id: id) { channels.append(channel) }
        }
        return NicheSample(queries: queries, videos: videos, channels: channels, source: .page, fetchedAt: now(),
                           notes: ["Read from public pages: subscriber counts for the \(channels.count) channels with the most views; join dates are not shown."])
    }
}

extension PageReader {
    /// Videos on the search page, with the video filter on.
    public func searchVideos(_ query: String) async throws -> [YouTubeVideo] {
        guard let data = try await data(at: "/results", query: [
            URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "sp", value: "EgIQAQ=="),
        ]) else { return [] }
        return PageData.videos(from: data)
    }
}
