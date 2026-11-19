import Foundation
import Support

/// Reads the data YouTube embeds in its public pages (`ytInitialData`,
/// `ytInitialPlayerResponse`). The layout changes often, so lookups search the
/// whole tree for known renderer names instead of following one fixed path.
public enum PageData {
    /// Finds `<name> = {...}` in a page and parses the object.
    public static func embedded(_ name: String, in html: String) -> JSONValue? {
        var searchStart = html.startIndex
        while let found = html.range(of: name, range: searchStart..<html.endIndex) {
            searchStart = found.upperBound
            var index = found.upperBound
            // Allow `ytInitialData = {`, `"ytInitialData"] = {` and `ytInitialData":{`.
            while index < html.endIndex, " \"']=:".contains(html[index]) { index = html.index(after: index) }
            guard index < html.endIndex, html[index] == "{",
                  let end = matchingBrace(in: html, from: index) else { continue }
            if let value = parse(String(html[index...end])) { return value }
        }
        return nil
    }

    static func matchingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// JSONSerialization is much faster than Codable on multi-megabyte pages.
    static func parse(_ text: String) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return convert(object)
    }

    static func convert(_ object: Any) -> JSONValue {
        switch object {
        case let string as String: return .string(string)
        case let number as NSNumber: return .number(number.doubleValue)
        case let array as [Any]: return .array(array.map(convert))
        case let dictionary as [String: Any]: return .object(dictionary.mapValues(convert))
        default: return .null
        }
    }

    // MARK: Tree helpers

    /// Every value stored under `key`, anywhere in the tree, in document order.
    static func all(_ key: String, in value: JSONValue) -> [JSONValue] {
        var found: [JSONValue] = []
        func walk(_ value: JSONValue) {
            switch value {
            case .object(let object):
                for name in object.keys.sorted() {
                    if name == key { found.append(object[name]!) }
                    walk(object[name]!)
                }
            case .array(let array): array.forEach(walk)
            default: break
            }
        }
        walk(value)
        return found
    }

    static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let string): return [string]
        case .object(let object): return object.keys.sorted().flatMap { strings(in: object[$0]!) }
        case .array(let array): return array.flatMap(strings)
        default: return []
        }
    }

    /// The visible text of a YouTube text object: `simpleText`, `runs` or `content`.
    static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return string }
        if let simple = value["simpleText"]?.stringValue { return simple }
        if let content = value["content"]?.stringValue { return content }
        if case .array(let runs)? = value["runs"] {
            let joined = runs.compactMap { $0["text"]?.stringValue }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    static func lastURL(_ value: JSONValue?) -> String? {
        guard case .array(let images)? = value else { return nil }
        guard var url = images.last?["url"]?.stringValue else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }

    // MARK: Channel pages

    public static func channel(from data: JSONValue) -> YouTubeChannel? {
        guard let meta = all("channelMetadataRenderer", in: data).first,
              let id = meta["externalId"]?.stringValue,
              let title = meta["title"]?.stringValue else { return nil }

        var handle: String?
        if let vanity = meta["vanityChannelUrl"]?.stringValue,
           let last = vanity.split(separator: "/").last, last.hasPrefix("@") {
            handle = String(last.dropFirst()).removingPercentEncoding
        }

        var subscribers: Int?
        var videos: Int?
        for string in strings(in: data) {
            let lowered = string.lowercased()
            if lowered.hasSuffix(" subscribers") || lowered.hasSuffix(" subscriber") {
                // The header holds both "47M subscribers" and a spoken label; other text can
                // mention subscribers too. The channel's own count is the largest.
                if let count = Parse.count(string) { subscribers = max(subscribers ?? 0, count) }
            } else if videos == nil, lowered.hasSuffix(" videos") || lowered.hasSuffix(" video"),
                      Parse.count(string) != nil, string.split(separator: " ").count == 2 {
                videos = Parse.count(string)
            }
        }

        let banner = all("imageBannerViewModel", in: data).first.flatMap { lastURL($0["image"]?["sources"]) }
            ?? all("c4TabbedHeaderRenderer", in: data).first.flatMap { lastURL($0["banner"]?["thumbnails"]) }

        return YouTubeChannel(
            id: id, handle: handle, title: title, description: meta["description"]?.stringValue ?? "",
            keywords: Parse.keywords(meta["keywords"]?.stringValue), subscriberCount: subscribers,
            subscribersHidden: subscribers == nil, videoCount: videos,
            avatarURL: lastURL(meta["avatar"]?["thumbnails"]), bannerURL: banner,
            uploadsPlaylistID: "UU" + id.dropFirst(2))
    }

    /// Videos and Shorts listed on a channel or search page.
    public static func videos(from data: JSONValue, channel: YouTubeChannel? = nil) -> [YouTubeVideo] {
        var records: [YouTubeVideo] = []
        var seen = Set<String>()
        func add(_ record: YouTubeVideo) {
            guard !record.id.isEmpty, seen.insert(record.id).inserted else { return }
            var record = record
            if record.channelID == nil { record.channelID = channel?.id }
            if record.channelTitle == nil { record.channelTitle = channel?.title }
            records.append(record)
        }

        for renderer in all("videoRenderer", in: data) + all("gridVideoRenderer", in: data) {
            guard let id = renderer["videoId"]?.stringValue else { continue }
            add(YouTubeVideo(
                id: id, title: text(renderer["title"]) ?? "",
                durationSeconds: text(renderer["lengthText"]).flatMap(Parse.clock),
                viewCount: text(renderer["viewCountText"]).flatMap(Parse.count),
                publishedText: text(renderer["publishedTimeText"]),
                channelID: renderer["ownerText"]?["runs"].flatMap { all("browseId", in: $0).first?.stringValue },
                channelTitle: text(renderer["ownerText"]),
                thumbnailURL: lastURL(renderer["thumbnail"]?["thumbnails"])))
        }

        for lockup in all("lockupViewModel", in: data) {
            guard let id = lockup["contentId"]?.stringValue,
                  lockup["contentType"]?.stringValue?.contains("VIDEO") ?? true else { continue }
            let meta = lockup["metadata"]?["lockupMetadataViewModel"]
            let parts = meta.map { all("metadataParts", in: $0).flatMap { strings(in: $0) } } ?? []
            let badge = all("thumbnailBadgeViewModel", in: lockup).first?["text"]?.stringValue
            add(YouTubeVideo(
                id: id, title: text(meta?["title"]) ?? "",
                durationSeconds: badge.flatMap(Parse.clock),
                viewCount: parts.first { $0.lowercased().hasSuffix(" views") || $0.lowercased() == "no views" }
                    .flatMap(Parse.count),
                publishedText: parts.first { $0.hasSuffix(" ago") }))
        }

        for short in all("shortsLockupViewModel", in: data) {
            guard let id = all("reelWatchEndpoint", in: short).first?["videoId"]?.stringValue else { continue }
            let overlay = short["overlayMetadata"]
            add(YouTubeVideo(
                id: id, title: text(overlay?["primaryText"]) ?? "", durationSeconds: nil,
                viewCount: text(overlay?["secondaryText"]).flatMap(Parse.count)))
        }

        for reel in all("reelItemRenderer", in: data) {
            guard let id = reel["videoId"]?.stringValue else { continue }
            add(YouTubeVideo(id: id, title: text(reel["headline"]) ?? "",
                            viewCount: text(reel["viewCountText"]).flatMap(Parse.count)))
        }
        return records
    }

    /// The channel that owns the video on a watch page.
    public static func channelID(fromWatchPage html: String) -> String? {
        if let player = embedded("ytInitialPlayerResponse", in: html),
           let id = player["videoDetails"]?["channelId"]?.stringValue { return id }
        if let data = embedded("ytInitialData", in: html) {
            return all("videoOwnerRenderer", in: data).first
                .flatMap { all("browseId", in: $0).first?.stringValue }
        }
        return nil
    }
}
