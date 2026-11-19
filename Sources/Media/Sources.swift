import Foundation
import Support
import YouTubeData

/// A search result from a media source, with its licence as the source states it.
public struct MediaCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, video }

    /// `source:id`, stable across searches.
    public var id: String
    public var source: String
    public var kind: Kind
    public var title: String
    public var pageURL: String
    public var fileURL: String
    public var previewURL: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var author: String?
    public var licenceName: String?
    public var licenceURL: String?
    public var description: String?

    public init(id: String, source: String, kind: Kind, title: String, pageURL: String, fileURL: String, previewURL: String? = nil,
                width: Int? = nil, height: Int? = nil, duration: Double? = nil, author: String? = nil,
                licenceName: String? = nil, licenceURL: String? = nil, description: String? = nil) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.pageURL = pageURL
        self.fileURL = fileURL
        self.previewURL = previewURL
        self.width = width
        self.height = height
        self.duration = duration
        self.author = author
        self.licenceName = licenceName
        self.licenceURL = licenceURL
        self.description = description
    }

    public var fileExtension: String {
        let ext = (URL(string: fileURL)?.pathExtension ?? "").lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "mp4", "mov", "webm", "m4v", "ogv"].contains(ext) { return ext == "jpeg" ? "jpg" : ext }
        return kind == .video ? "mp4" : "jpg"
    }
}

/// One public media service. Every result carries a real link and licence (section 8.4).
public protocol MediaSource: Sendable {
    var id: String { get }
    var title: String { get }
    func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate]
}

/// The source ids, in the shipped order.
public enum MediaSources {
    public static let order = ["commons", "archive", "met", "loc", "nasa", "pexels", "pixabay"]
    public static let titles = ["commons": "Wikimedia Commons", "archive": "Internet Archive", "met": "The Met", "loc": "Library of Congress",
                                "nasa": "NASA", "pexels": "Pexels", "pixabay": "Pixabay"]
    public static let needsKey: Set<String> = ["pexels", "pixabay"]
    /// Sent to every service. Commons asks for a descriptive agent; it names the app only.
    public static let userAgent = "YTA/1.0 (personal video tool; media search)"

    public static func make(_ id: String, http: HTTPClient, key: String?) -> MediaSource? {
        switch id {
        case "commons": CommonsSource(http: http)
        case "archive": ArchiveSource(http: http)
        case "met": MetSource(http: http)
        case "loc": LOCSource(http: http)
        case "nasa": NASASource(http: http)
        case "pexels": key.map { PexelsSource(http: http, key: $0) }
        case "pixabay": key.map { PixabaySource(http: http, key: $0) }
        default: nil
        }
    }
}

func fetchJSON(_ http: HTTPClient, _ url: URL, headers: [String: String] = [:], what: String) async throws -> JSONValue {
    var all = headers
    all["User-Agent"] = MediaSources.userAgent
    all["Accept"] = "application/json"
    let response = try await http.get(url, headers: all)
    guard (200..<300).contains(response.status) else {
        if response.status == 429 { throw YTAError(.usageLimit, "\(what) asked YTA to slow down.") }
        throw YTAError(.network, "\(what) answered with status \(response.status).")
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.data) else {
        throw YTAError(.fileFormat, "\(what) sent an answer YTA could not read.")
    }
    return value
}

func address(_ base: String, _ items: [(String, String)]) -> URL {
    var components = URLComponents(string: base)!
    components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.url!
}

/// Removes HTML tags and entities that Commons puts in its metadata.
func plain(_ html: String?) -> String? {
    guard var text = html else { return nil }
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, value) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
        text = text.replacingOccurrences(of: entity, with: value)
    }
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
}

// MARK: Wikimedia Commons

public struct CommonsSource: MediaSource {
    public let id = "commons"
    public let title = "Wikimedia Commons"
    let http: HTTPClient

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        let filter = kind == .video ? " filetype:video" : kind == .image ? " filetype:bitmap" : ""
        let url = address("https://commons.wikimedia.org/w/api.php", [
            ("action", "query"), ("format", "json"), ("generator", "search"), ("gsrnamespace", "6"),
            ("gsrsearch", query + filter), ("gsrlimit", String(limit)), ("prop", "imageinfo"),
            ("iiprop", "url|size|mime|extmetadata"), ("iiurlwidth", "640"),
        ])
        let value = try await fetchJSON(http, url, what: title)
        guard let pages = value["query"]?["pages"]?.objectValue else { return [] }
        let ordered = pages.values.sorted { ($0["index"]?.intValue ?? 0) < ($1["index"]?.intValue ?? 0) }
        return ordered.compactMap { page in
            guard let info = page["imageinfo"]?.arrayValue?.first, let file = info["url"]?.stringValue,
                  let pageURL = info["descriptionurl"]?.stringValue else { return nil }
            let meta = info["extmetadata"]
            let mime = info["mime"]?.stringValue ?? ""
            let name = (page["title"]?.stringValue ?? "").replacingOccurrences(of: "File:", with: "")
            return MediaCandidate(
                id: "commons:\(page["pageid"]?.intValue ?? 0)", source: title,
                kind: mime.hasPrefix("video") || mime.contains("ogg") && (info["duration"]?.doubleValue ?? 0) > 0 ? .video : .image,
                title: (name as NSString).deletingPathExtension, pageURL: pageURL, fileURL: file,
                previewURL: info["thumburl"]?.stringValue, width: info["width"]?.intValue, height: info["height"]?.intValue,
                duration: info["duration"]?.doubleValue, author: plain(meta?["Artist"]?["value"]?.stringValue),
                licenceName: meta?["LicenseShortName"]?["value"]?.stringValue, licenceURL: meta?["LicenseUrl"]?["value"]?.stringValue,
                description: plain(meta?["ImageDescription"]?["value"]?.stringValue).map { String($0.prefix(300)) })
        }
    }
}

// MARK: Internet Archive

public struct ArchiveSource: MediaSource {
    public let id = "archive"
    public let title = "Internet Archive"
    let http: HTTPClient

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        let media = kind == .image ? "image" : kind == .video ? "movies" : "(movies OR image)"
        let url = address("https://archive.org/advancedsearch.php", [
            ("q", "(\(query)) AND mediatype:\(media) AND licenseurl:*"), ("fl[]", "identifier"), ("fl[]", "title"),
            ("fl[]", "creator"), ("fl[]", "licenseurl"), ("fl[]", "mediatype"), ("rows", String(limit)), ("output", "json"),
        ])
        let value = try await fetchJSON(http, url, what: title)
        let docs = value["response"]?["docs"]?.arrayValue ?? []
        var found: [MediaCandidate] = []
        for doc in docs {
            guard let identifier = doc["identifier"]?.stringValue, let licence = doc["licenseurl"]?.stringValue else { continue }
            guard let item = try? await file(for: identifier, video: doc["mediatype"]?.stringValue == "movies") else { continue }
            let creator = doc["creator"]?.stringValue ?? doc["creator"]?.arrayValue?.first?.stringValue
            found.append(MediaCandidate(
                id: "archive:\(identifier)", source: title, kind: item.video ? .video : .image,
                title: doc["title"]?.stringValue ?? identifier, pageURL: "https://archive.org/details/\(identifier)",
                fileURL: item.url, previewURL: "https://archive.org/services/img/\(identifier)", width: item.width, height: item.height,
                duration: item.length, author: creator ?? "Unknown (Internet Archive)", licenceName: licence, licenceURL: licence))
        }
        return found
    }

    /// The item's main file: an original MP4 or image.
    func file(for identifier: String, video: Bool) async throws -> (url: String, width: Int?, height: Int?, length: Double?, video: Bool)? {
        let value = try await fetchJSON(http, URL(string: "https://archive.org/metadata/\(identifier)")!, what: title)
        let files = value["files"]?.arrayValue ?? []
        let wanted = video ? [".mp4", ".mov", ".ogv"] : [".jpg", ".jpeg", ".png", ".tif"]
        let match = files.first { file in
            let name = file["name"]?.stringValue?.lowercased() ?? ""
            return wanted.contains { name.hasSuffix($0) } && !name.contains("thumb") && !name.contains("_itemimage")
        }
        guard let match, let name = match["name"]?.stringValue else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        func number(_ key: String) -> Double? { match[key]?.doubleValue ?? match[key]?.stringValue.flatMap(Double.init) }
        return ("https://archive.org/download/\(identifier)/\(encoded)", number("width").map(Int.init), number("height").map(Int.init),
                number("length"), video)
    }
}

// MARK: The Met

public struct MetSource: MediaSource {
    public let id = "met"
    public let title = "The Met"
    let http: HTTPClient

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        if kind == .video { return [] }
        let base = "https://collectionapi.metmuseum.org/public/collection/v1"
        let value = try await fetchJSON(http, address("\(base)/search", [("hasImages", "true"), ("q", query)]), what: title)
        let ids = (value["objectIDs"]?.arrayValue ?? []).compactMap(\.intValue).prefix(limit * 2)
        var found: [MediaCandidate] = []
        for id in ids where found.count < limit {
            guard let object = try? await fetchJSON(http, URL(string: "\(base)/objects/\(id)")!, what: title),
                  object["isPublicDomain"] == .bool(true), let image = object["primaryImage"]?.stringValue, !image.isEmpty else { continue }
            let artist = object["artistDisplayName"]?.stringValue
            found.append(MediaCandidate(
                id: "met:\(id)", source: title, kind: .image, title: object["title"]?.stringValue ?? "Object \(id)",
                pageURL: object["objectURL"]?.stringValue ?? "https://www.metmuseum.org/art/collection/search/\(id)",
                fileURL: image, previewURL: object["primaryImageSmall"]?.stringValue,
                author: (artist?.isEmpty == false ? artist : nil) ?? "The Metropolitan Museum of Art",
                licenceName: "CC0", licenceURL: LicenceKind.cc0.defaultURL))
        }
        return found
    }
}

// MARK: Library of Congress

public struct LOCSource: MediaSource {
    public let id = "loc"
    public let title = "Library of Congress"
    let http: HTTPClient

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        if kind == .video { return [] }
        let value = try await fetchJSON(http, address("https://www.loc.gov/photos/", [("q", query), ("fo", "json"), ("c", String(limit))]), what: title)
        return (value["results"]?.arrayValue ?? []).compactMap { item in
            guard let page = item["url"]?.stringValue ?? item["id"]?.stringValue,
                  let images = item["image_url"]?.arrayValue?.compactMap(\.stringValue), let largest = images.last else { return nil }
            let rights = item["rights_advisory"]?.arrayValue?.first?.stringValue ?? item["rights_advisory"]?.stringValue
                ?? item["item"]?["rights_advisory"]?.arrayValue?.first?.stringValue
            let file = largest.components(separatedBy: "#").first ?? largest
            return MediaCandidate(
                id: "loc:\(page.split(separator: "/").last.map(String.init) ?? page)", source: title, kind: .image,
                title: item["title"]?.stringValue ?? "Untitled", pageURL: page, fileURL: file.hasPrefix("//") ? "https:" + file : file,
                previewURL: images.first.map { $0.hasPrefix("//") ? "https:" + $0 : $0 },
                author: item["contributor"]?.arrayValue?.first?.stringValue ?? "Library of Congress",
                licenceName: rights, licenceURL: "https://www.loc.gov/legal/")
        }
    }
}

// MARK: NASA

public struct NASASource: MediaSource {
    public let id = "nasa"
    public let title = "NASA"
    let http: HTTPClient

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        let types = kind == .video ? "video" : kind == .image ? "image" : "image,video"
        let value = try await fetchJSON(http, address("https://images-api.nasa.gov/search", [("q", query), ("media_type", types), ("page_size", String(limit))]), what: title)
        var found: [MediaCandidate] = []
        for item in (value["collection"]?["items"]?.arrayValue ?? []).prefix(limit) {
            guard let data = item["data"]?.arrayValue?.first, let id = data["nasa_id"]?.stringValue else { continue }
            let video = data["media_type"]?.stringValue == "video"
            guard let assets = try? await fetchJSON(http, URL(string: "https://images-api.nasa.gov/asset/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!, what: title) else { continue }
            let links = (assets["collection"]?["items"]?.arrayValue ?? []).compactMap { $0["href"]?.stringValue }
            let file = video ? links.first { $0.contains("~orig.mp4") } ?? links.first { $0.hasSuffix(".mp4") }
                             : links.first { $0.contains("~orig.") } ?? links.first { $0.hasSuffix(".jpg") }
            guard let file else { continue }
            found.append(MediaCandidate(
                id: "nasa:\(id)", source: title, kind: video ? .video : .image, title: data["title"]?.stringValue ?? id,
                pageURL: "https://images.nasa.gov/details/\(id)", fileURL: file.replacingOccurrences(of: "http://", with: "https://"),
                previewURL: item["links"]?.arrayValue?.first?["href"]?.stringValue,
                author: data["photographer"]?.stringValue ?? data["center"].flatMap { $0.stringValue.map { "NASA \($0)" } } ?? "NASA",
                licenceName: "Public domain (NASA media)", licenceURL: "https://www.nasa.gov/nasa-brand-center/images-and-media/",
                description: data["description"]?.stringValue.map { String($0.prefix(300)) }))
        }
        return found
    }
}

// MARK: Pexels and Pixabay

public struct PexelsSource: MediaSource {
    public let id = "pexels"
    public let title = "Pexels"
    let http: HTTPClient
    let key: String

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        let headers = ["Authorization": key]
        if kind == .video {
            let value = try await fetchJSON(http, address("https://api.pexels.com/videos/search", [("query", query), ("per_page", String(limit))]), headers: headers, what: title)
            return (value["videos"]?.arrayValue ?? []).compactMap { video in
                let files = (video["video_files"]?.arrayValue ?? []).filter { $0["file_type"]?.stringValue == "video/mp4" }
                guard let best = files.max(by: { ($0["width"]?.intValue ?? 0) < ($1["width"]?.intValue ?? 0) }),
                      let link = best["link"]?.stringValue, let page = video["url"]?.stringValue else { return nil }
                return MediaCandidate(id: "pexels:v\(video["id"]?.intValue ?? 0)", source: title, kind: .video, title: Self.title(from: page),
                                      pageURL: page, fileURL: link, previewURL: video["image"]?.stringValue,
                                      width: best["width"]?.intValue, height: best["height"]?.intValue, duration: video["duration"]?.doubleValue,
                                      author: video["user"]?["name"]?.stringValue, licenceName: "Pexels License", licenceURL: LicenceKind.pexels.defaultURL)
            }
        }
        let value = try await fetchJSON(http, address("https://api.pexels.com/v1/search", [("query", query), ("per_page", String(limit))]), headers: headers, what: title)
        return (value["photos"]?.arrayValue ?? []).compactMap { photo in
            guard let page = photo["url"]?.stringValue, let file = photo["src"]?["original"]?.stringValue else { return nil }
            return MediaCandidate(id: "pexels:\(photo["id"]?.intValue ?? 0)", source: title, kind: .image,
                                  title: photo["alt"]?.stringValue ?? Self.title(from: page), pageURL: page, fileURL: file,
                                  previewURL: photo["src"]?["medium"]?.stringValue, width: photo["width"]?.intValue, height: photo["height"]?.intValue,
                                  author: photo["photographer"]?.stringValue, licenceName: "Pexels License", licenceURL: LicenceKind.pexels.defaultURL)
        }
    }

    static func title(from page: String) -> String {
        let slug = page.split(separator: "/").last.map(String.init) ?? page
        return slug.split(separator: "-").filter { Int($0) == nil }.joined(separator: " ").capitalized
    }
}

public struct PixabaySource: MediaSource {
    public let id = "pixabay"
    public let title = "Pixabay"
    let http: HTTPClient
    let key: String

    public func search(_ query: String, kind: MediaCandidate.Kind?, limit: Int) async throws -> [MediaCandidate] {
        let count = String(max(3, min(limit, 200)))
        if kind == .video {
            let value = try await fetchJSON(http, address("https://pixabay.com/api/videos/", [("key", key), ("q", query), ("per_page", count), ("safesearch", "true")]), what: title)
            return (value["hits"]?.arrayValue ?? []).compactMap { hit in
                guard let large = hit["videos"]?["large"], let link = large["url"]?.stringValue, !link.isEmpty,
                      let page = hit["pageURL"]?.stringValue else { return nil }
                return MediaCandidate(id: "pixabay:v\(hit["id"]?.intValue ?? 0)", source: title, kind: .video,
                                      title: hit["tags"]?.stringValue ?? "Video", pageURL: page, fileURL: link,
                                      previewURL: hit["videos"]?["tiny"]?["thumbnail"]?.stringValue,
                                      width: large["width"]?.intValue, height: large["height"]?.intValue, duration: hit["duration"]?.doubleValue,
                                      author: hit["user"]?.stringValue, licenceName: "Pixabay Content License", licenceURL: LicenceKind.pixabay.defaultURL)
            }
        }
        let value = try await fetchJSON(http, address("https://pixabay.com/api/", [("key", key), ("q", query), ("per_page", count), ("image_type", "photo"), ("safesearch", "true")]), what: title)
        return (value["hits"]?.arrayValue ?? []).compactMap { hit in
            guard let page = hit["pageURL"]?.stringValue, let file = hit["largeImageURL"]?.stringValue else { return nil }
            return MediaCandidate(id: "pixabay:\(hit["id"]?.intValue ?? 0)", source: title, kind: .image,
                                  title: hit["tags"]?.stringValue ?? "Photo", pageURL: page, fileURL: file,
                                  previewURL: hit["webformatURL"]?.stringValue, width: hit["imageWidth"]?.intValue, height: hit["imageHeight"]?.intValue,
                                  author: hit["user"]?.stringValue, licenceName: "Pixabay Content License", licenceURL: LicenceKind.pixabay.defaultURL)
        }
    }
}
