import ChannelStore
import Foundation
import Support
import Testing
@testable import YouTubeData

// MARK: Fakes

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(match: String, status: Int, body: String)] = []
    private(set) var requested: [URL] = []

    func answer(_ match: String, status: Int = 200, _ body: String) {
        lock.withLock { answers.append((match, status, body)) }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try lock.withLock {
            requested.append(url)
            let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            guard let hit = answers.last(where: { text.contains($0.match) }) else {
                throw YTAError(.network, "no fake answer for \(text)")
            }
            return HTTPResponse(status: hit.status, data: Data(hit.body.utf8))
        }
    }

    var paths: [String] { lock.withLock { requested.map(\.path) } }
}

final class FakePages: PageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: String] = [:]
    private(set) var loaded: [String] = []

    func page(_ path: String, _ html: String) { lock.withLock { pages[path] = html } }

    func load(_ url: URL) async throws -> PageResult {
        lock.withLock {
            loaded.append(url.path)
            guard let html = pages[url.path] else { return PageResult(status: 404, html: "Not found") }
            return PageResult(status: 200, html: html)
        }
    }
}

final class Clock: @unchecked Sendable {
    var now: Date
    init(_ iso: String) { now = ISO8601DateFormatter().date(from: iso)! }
}

func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("yta-yt-\(UUID().uuidString)").appendingPathComponent(name)
}

/// The YTAError a call throws, or nil. Works with the older swift-testing on Linux.
func caught(_ body: () throws -> Void) -> YTAError? {
    do { try body(); return nil } catch { return error as? YTAError }
}

func caughtAsync(_ body: () async throws -> Void) async -> YTAError? {
    do { try await body(); return nil } catch { return error as? YTAError }
}

// MARK: Fixtures

let apiChannelJSON = """
{"items":[{"id":"UCabcdefghijklmnopqrstuv","snippet":{"title":"Lighthouse Stories","description":"Tales of the sea.",
"customUrl":"@lighthousestories","publishedAt":"2021-03-04T05:06:07Z","country":"US",
"thumbnails":{"default":{"url":"https://yt3/a88"},"high":{"url":"https://yt3/a800"}}},
"statistics":{"viewCount":"123456","subscriberCount":"4500","hiddenSubscriberCount":false,"videoCount":"3"},
"brandingSettings":{"channel":{"keywords":"lighthouses \\"maritime history\\" sea"},"image":{"bannerExternalUrl":"https://yt3/banner"}},
"contentDetails":{"relatedPlaylists":{"uploads":"UUabcdefghijklmnopqrstuv"}}}]}
"""

let apiUploadsJSON = """
{"items":[{"contentDetails":{"videoId":"aaaaaaaaaaa"}},{"contentDetails":{"videoId":"bbbbbbbbbbb"}},{"contentDetails":{"videoId":"ccccccccccc"}}]}
"""

let apiVideosJSON = """
{"items":[
{"id":"aaaaaaaaaaa","snippet":{"title":"The keeper who vanished","description":"d","tags":["lighthouse"],"publishedAt":"2026-01-02T03:04:05Z","channelId":"UCabcdefghijklmnopqrstuv","channelTitle":"Lighthouse Stories"},"statistics":{"viewCount":"1000","likeCount":"50"},"contentDetails":{"duration":"PT12M30S"}},
{"id":"bbbbbbbbbbb","snippet":{"title":"Short one","publishedAt":"2026-01-03T03:04:05Z","channelId":"UCabcdefghijklmnopqrstuv"},"statistics":{"viewCount":"3000"},"contentDetails":{"duration":"PT45S"}},
{"id":"ccccccccccc","snippet":{"title":"Storm night","publishedAt":"2026-01-04T03:04:05Z","channelId":"UCabcdefghijklmnopqrstuv"},"statistics":{"viewCount":"2000"},"contentDetails":{"duration":"PT1H2M3S"}}
]}
"""

let quotaErrorJSON = """
{"error":{"code":403,"message":"The request cannot be completed because you have exceeded your quota.","errors":[{"message":"quota","domain":"youtube.quota","reason":"quotaExceeded"}]}}
"""

let badKeyJSON = """
{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","errors":[{"message":"API key not valid.","domain":"global","reason":"badRequest"}],"status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}
"""

/// Shaped like a 2026 channel /videos page: page header view model, rich grid with lockups and a Shorts shelf.
let channelPageData = """
{"metadata":{"channelMetadataRenderer":{"title":"Lighthouse Stories","description":"Tales of the sea. {not json}",
"externalId":"UCabcdefghijklmnopqrstuv","keywords":"lighthouses \\"maritime history\\"",
"vanityChannelUrl":"http://www.youtube.com/@lighthousestories",
"avatar":{"thumbnails":[{"url":"https://yt3/a900","width":900}]}}},
"header":{"pageHeaderRenderer":{"content":{"pageHeaderViewModel":{
"banner":{"imageBannerViewModel":{"image":{"sources":[{"url":"https://yt3/b1060"},{"url":"https://yt3/b2560"}]}}},
"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"@lighthousestories"}}]},
{"metadataParts":[{"text":{"content":"4.5K subscribers"},"accessibilityLabel":"4.5 thousand subscribers"},{"text":{"content":"3 videos"}}]}]}}}}}},
"sidebar":{"note":"Join 12 subscribers"},
"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"richGridRenderer":{"contents":[
{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"runs":[{"text":"The keeper who vanished"}]},
"viewCountText":{"simpleText":"1,000 views"},"publishedTimeText":{"simpleText":"10 months ago"},"lengthText":{"simpleText":"12:30"},
"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/a.jpg"}]}}}}},
{"richItemRenderer":{"content":{"lockupViewModel":{"contentId":"ccccccccccc","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
"contentImage":{"thumbnailViewModel":{"overlays":[{"thumbnailOverlayBadgeViewModel":{"thumbnailBadges":[{"thumbnailBadgeViewModel":{"text":"1:02:03"}}]}}]}},
"metadata":{"lockupMetadataViewModel":{"title":{"content":"Storm night"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"2K views"}},{"text":{"content":"10 months ago"}}]}]}}}}}}}},
{"richItemRenderer":{"content":{"shortsLockupViewModel":{"onTap":{"innertubeCommand":{"reelWatchEndpoint":{"videoId":"bbbbbbbbbbb"}}},
"overlayMetadata":{"primaryText":{"content":"Short one"},"secondaryText":{"content":"3K views"}}}}}}
]}}}}]}}}
"""

func page(with data: String) -> String {
    """
    <html><head><script nonce="x">var ytInitialPlayerResponse = null;</script>
    <script nonce="y">var ytInitialData = \(data);</script></head><body></body></html>
    """
}

// MARK: Tests

@Suite struct QuotaLedgerTests {
    @Test func spendingIsPersistedAndCountsSearches() throws {
        let file = tempFile("quota.json")
        let clock = Clock("2026-11-19T18:00:00Z")
        let ledger = QuotaLedger(file: file, now: { clock.now })
        try ledger.spend(QuotaCost.list)
        try ledger.spend(QuotaCost.search)
        let reopened = QuotaLedger(file: file, now: { clock.now }).usage()
        #expect(reopened.used == 101)
        #expect(reopened.searches == 1)
        #expect(reopened.remaining == 9_899)
        #expect(reopened.searchesLeft == 98)
    }

    @Test func refusesToGoOverTheLimit() throws {
        let clock = Clock("2026-11-19T18:00:00Z")
        let ledger = QuotaLedger(file: tempFile("quota.json"), dailyLimit: 150, now: { clock.now })
        try ledger.spend(QuotaCost.search)
        #expect(!ledger.canFinish(searches: 1, lists: 0))
        #expect(ledger.canFinish(searches: 0, lists: 50))
        let error = caught { try ledger.spend(QuotaCost.search) }
        #expect(error?.kind == .quotaExhausted)
        // 2026-11-20 00:00 in Los Angeles is 08:00 UTC.
        #expect(error?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-20T08:00:00Z"))
        #expect(ledger.usage().used == 100)
    }

    @Test func resetsAtMidnightPacificNotUTC() throws {
        let file = tempFile("quota.json")
        let clock = Clock("2026-11-20T07:59:00Z") // 23:59 on the 19th in Los Angeles
        let ledger = QuotaLedger(file: file, now: { clock.now })
        try ledger.spend(500)
        ledger.markExhausted()
        #expect(ledger.usage().remaining == 0)
        clock.now = ISO8601DateFormatter().date(from: "2026-11-20T08:01:00Z")!
        #expect(ledger.usage().used == 0)
        #expect(!ledger.usage().exhausted)
        #expect(QuotaLedger.dayKey(for: clock.now) == "2026-11-20")
    }

    @Test func dayKeyFollowsDaylightSaving() {
        // In July Los Angeles is UTC-7, so midnight is 07:00 UTC.
        let summer = ISO8601DateFormatter().date(from: "2026-07-01T06:30:00Z")!
        #expect(QuotaLedger.dayKey(for: summer) == "2026-06-30")
        #expect(QuotaLedger.nextReset(after: summer) == ISO8601DateFormatter().date(from: "2026-07-01T07:00:00Z"))
    }
}

@Suite struct ParsingTests {
    @Test func linksResolveToTheRightKind() {
        #expect(ChannelLink.parse("@Lighthouse.Stories") == .handle("Lighthouse.Stories"))
        #expect(ChannelLink.parse("lighthousestories") == .handle("lighthousestories"))
        #expect(ChannelLink.parse("https://www.youtube.com/@lighthousestories/videos") == .handle("lighthousestories"))
        #expect(ChannelLink.parse("youtube.com/channel/UCabcdefghijklmnopqrstuv") == .channelID("UCabcdefghijklmnopqrstuv"))
        #expect(ChannelLink.parse("https://www.youtube.com/watch?v=aaaaaaaaaaa&t=3") == .video("aaaaaaaaaaa"))
        #expect(ChannelLink.parse("https://youtu.be/aaaaaaaaaaa") == .video("aaaaaaaaaaa"))
        #expect(ChannelLink.parse("https://m.youtube.com/shorts/bbbbbbbbbbb") == .video("bbbbbbbbbbb"))
        #expect(ChannelLink.parse("https://www.youtube.com/c/OldName") == .legacyName("OldName"))
        #expect(ChannelLink.parse("https://example.com/@x") == nil)
        #expect(ChannelLink.parse("a b") == nil)
        #expect(ChannelLink.parse("@ab") == nil)
    }

    @Test func numbersAsYouTubeWritesThem() {
        #expect(Parse.duration("PT12M30S") == 750)
        #expect(Parse.duration("PT1H2M3S") == 3723)
        #expect(Parse.duration("P1DT1S") == 86_401)
        #expect(Parse.duration("PT") == 0)
        #expect(Parse.duration("12:30") == nil)
        #expect(Parse.clock("1:02:03") == 3723)
        #expect(Parse.clock("0:45") == 45)
        #expect(Parse.count("1,234 views") == 1234)
        #expect(Parse.count("4.5K subscribers") == 4500)
        #expect(Parse.count("1.25M") == 1_250_000)
        #expect(Parse.count("No views") == 0)
        #expect(Parse.count("47 million subscribers") == 47_000_000)
        #expect(Parse.count("20.1 thousand views") == 20_100)
        #expect(Parse.count("views") == nil)
        #expect(Parse.keywords(#"lighthouses "maritime history" sea"#) == ["lighthouses", "maritime history", "sea"])
    }
}

@Suite struct DataAPIClientTests {
    func client(_ http: FakeHTTP, limit: Int = 10_000) -> (DataAPIClient, QuotaLedger) {
        let ledger = QuotaLedger(file: tempFile("quota.json"), dailyLimit: limit)
        return (DataAPIClient(key: "SECRET-KEY-123", http: http, ledger: ledger), ledger)
    }

    @Test func channelByHandleCostsOneUnit() async throws {
        let http = FakeHTTP()
        http.answer("forHandle=@lighthousestories", apiChannelJSON)
        let (api, ledger) = client(http)
        let channel = try #require(try await api.channel(handle: "lighthousestories"))
        #expect(channel.title == "Lighthouse Stories")
        #expect(channel.handle == "lighthousestories")
        #expect(channel.subscriberCount == 4500)
        #expect(channel.keywords == ["lighthouses", "maritime history", "sea"])
        #expect(channel.avatarURL == "https://yt3/a800")
        #expect(channel.uploadsPlaylistID == "UUabcdefghijklmnopqrstuv")
        #expect(ledger.usage().used == 1)
    }

    @Test func unknownHandleIsNil() async throws {
        let http = FakeHTTP()
        http.answer("forHandle", #"{"kind":"youtube#channelListResponse","pageInfo":{"totalResults":0}}"#)
        #expect(try await client(http).0.channel(handle: "nobodyhere") == nil)
    }

    @Test func searchCostsAHundred() async throws {
        let http = FakeHTTP()
        http.answer("/search", #"{"items":[{"id":{"kind":"youtube#video","videoId":"aaaaaaaaaaa"},"snippet":{"title":"t","channelId":"UCx","channelTitle":"c","publishedAt":"2026-01-01T00:00:00Z"}}]}"#)
        let (api, ledger) = client(http)
        let hits = try await api.search("lighthouse")
        #expect(hits.first?.id == "aaaaaaaaaaa")
        #expect(ledger.usage().used == 100)
        #expect(ledger.usage().searches == 1)
    }

    @Test func quotaExceededLocksTheLedgerUntilReset() async throws {
        let http = FakeHTTP()
        http.answer("forHandle", status: 403, quotaErrorJSON)
        let (api, ledger) = client(http)
        let error = await caughtAsync { _ = try await api.channel(handle: "abc") }
        #expect(error?.kind == .quotaExhausted)
        #expect(ledger.usage().exhausted)
        // Nothing more is sent.
        await #expect(throws: YTAError.self) { try await api.channel(handle: "abc") }
        #expect(http.requested.count == 1)
    }

    @Test func refusedKeyIsReportedWithoutTheKey() async throws {
        let http = FakeHTTP()
        http.answer("forHandle", status: 400, badKeyJSON)
        let error = await caughtAsync { _ = try await client(http).0.channel(handle: "abc") }
        #expect(error?.kind == .notSignedIn)
        #expect(!(error?.description.contains("SECRET-KEY-123") ?? true))
    }

    @Test func uploadsAreReadInPagesOfFifty() async throws {
        let http = FakeHTTP()
        let first = (0..<50).map { #"{"contentDetails":{"videoId":"v\#(String(format: "%010d", $0))"}}"# }.joined(separator: ",")
        http.answer("playlistItems", #"{"items":[\#(first)],"nextPageToken":"NEXT"}"#)
        http.answer("pageToken=NEXT", #"{"items":[{"contentDetails":{"videoId":"zzzzzzzzzzz"}}]}"#)
        let (api, ledger) = client(http)
        let result = try await api.uploadIDs(playlist: "UUx")
        #expect(result.ids.count == 51)
        #expect(result.complete)
        #expect(ledger.usage().used == 2)
    }
}

@Suite struct PageDataTests {
    @Test func embeddedDataIsFoundDespiteBracesInStrings() throws {
        let data = try #require(PageData.embedded("ytInitialData", in: page(with: channelPageData)))
        #expect(data["metadata"]?["channelMetadataRenderer"]?["title"]?.stringValue == "Lighthouse Stories")
        #expect(PageData.embedded("ytInitialData", in: "<html>nothing</html>") == nil)
        // The window["..."] form.
        let other = #"<script>window["ytInitialData"] = {"a":"}"};</script>"#
        #expect(PageData.embedded("ytInitialData", in: other)?["a"]?.stringValue == "}")
    }

    @Test func channelHeaderIsRead() throws {
        let data = try #require(PageData.embedded("ytInitialData", in: page(with: channelPageData)))
        let channel = try #require(PageData.channel(from: data))
        #expect(channel.id == "UCabcdefghijklmnopqrstuv")
        #expect(channel.handle == "lighthousestories")
        #expect(channel.subscriberCount == 4500)
        #expect(channel.videoCount == 3)
        #expect(channel.bannerURL == "https://yt3/b2560")
        #expect(channel.avatarURL == "https://yt3/a900")
        #expect(channel.keywords == ["lighthouses", "maritime history"])
        #expect(channel.uploadsPlaylistID == "UUabcdefghijklmnopqrstuv")
    }

    @Test func videosLockupsAndShortsAreRead() throws {
        let data = try #require(PageData.embedded("ytInitialData", in: page(with: channelPageData)))
        let videos = PageData.videos(from: data)
        #expect(videos.map(\.id).sorted() == ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        #expect(byID["aaaaaaaaaaa"]?.durationSeconds == 750)
        #expect(byID["aaaaaaaaaaa"]?.viewCount == 1000)
        #expect(byID["aaaaaaaaaaa"]?.publishedText == "10 months ago")
        #expect(byID["ccccccccccc"]?.title == "Storm night")
        #expect(byID["ccccccccccc"]?.durationSeconds == 3723)
        #expect(byID["ccccccccccc"]?.viewCount == 2000)
        #expect(byID["bbbbbbbbbbb"]?.viewCount == 3000)
    }

    @Test func watchPageNamesItsChannel() {
        let html = #"<script>var ytInitialPlayerResponse = {"videoDetails":{"videoId":"aaaaaaaaaaa","channelId":"UCabcdefghijklmnopqrstuv"}};</script>"#
        #expect(PageData.channelID(fromWatchPage: html) == "UCabcdefghijklmnopqrstuv")
    }
}

@Suite struct YouTubeServiceTests {
    func service(key: String?, http: FakeHTTP = FakeHTTP(), pages: FakePages, limit: Int = 10_000) -> YouTubeService {
        YouTubeService(key: { key }, ledger: QuotaLedger(file: tempFile("quota.json"), dailyLimit: limit),
                       http: http, pages: pages)
    }

    func pagesWithChannel() -> FakePages {
        let pages = FakePages()
        let html = page(with: channelPageData)
        pages.page("/@lighthousestories", html)
        pages.page("/@lighthousestories/videos", html)
        pages.page("/channel/UCabcdefghijklmnopqrstuv", html)
        return pages
    }

    @Test func handleCheckWithoutAKeyReadsPages() async throws {
        let pages = pagesWithChannel()
        let yt = service(key: nil, pages: pages)
        #expect(!yt.willUseAPI)
        let taken = try await yt.checkHandle("@lighthousestories")
        #expect(taken.status == .taken)
        #expect(taken.source == .page)
        #expect(taken.channel?.title == "Lighthouse Stories")
        let free = try await yt.checkHandle("brandnewname")
        #expect(free.status == .looksFree)
        #expect(free.source == .page)
    }

    @Test func handleCheckWithAKeyUsesTheAPI() async throws {
        let http = FakeHTTP()
        http.answer("forHandle=@lighthousestories", apiChannelJSON)
        http.answer("forHandle=@brandnewname", #"{"items":[]}"#)
        let pages = FakePages()
        let yt = service(key: "k", http: http, pages: pages)
        #expect(try await yt.checkHandle("lighthousestories").status == .taken)
        let free = try await yt.checkHandle("brandnewname")
        #expect(free.status == .looksFree)
        #expect(free.source == .api)
        #expect(pages.loaded.isEmpty)
    }

    @Test func exhaustedQuotaFallsBackToPages() async throws {
        let http = FakeHTTP()
        http.answer("forHandle", status: 403, quotaErrorJSON)
        let yt = service(key: "k", http: http, pages: pagesWithChannel())
        let result = try await yt.checkHandle("lighthousestories")
        #expect(result.source == .page)
        #expect(result.status == .taken)
        // The next call skips the API entirely.
        _ = try await yt.checkHandle("lighthousestories")
        #expect(http.requested.count == 1)
    }

    @Test func invalidHandleIsRefusedBeforeAnyCall() async {
        let pages = FakePages()
        await #expect(throws: YTAError.self) { try await service(key: nil, pages: pages).checkHandle("a b") }
        #expect(pages.loaded.isEmpty)
    }

    @Test func apiSnapshotHasEveryUploadAndIsSaved() async throws {
        let http = FakeHTTP()
        http.answer("/channels", apiChannelJSON)
        http.answer("/playlistItems", apiUploadsJSON)
        http.answer("/videos", apiVideosJSON)
        http.answer("/playlists", #"{"items":[{"id":"PL1","snippet":{"title":"Storms"},"contentDetails":{"itemCount":2}}]}"#)
        let yt = service(key: "k", http: http, pages: FakePages())
        let snapshot = try await yt.snapshot("https://www.youtube.com/@lighthousestories")
        #expect(snapshot.source == .api)
        #expect(snapshot.complete)
        #expect(snapshot.videos.count == 3)
        #expect(snapshot.videos.filter { $0.isShort == true }.map(\.id) == ["bbbbbbbbbbb"])
        #expect(snapshot.medianViews == 2000)
        #expect(snapshot.playlists.first?.title == "Storms")
        #expect(yt.ledger.usage().used == 4)

        let channels = ChannelStore(channelsFolder: tempFile("Channels"))
        let folder = try channels.createChannel(NewChannelRequest(workingName: "Import")).folder
        let store = SnapshotStore(channel: folder)
        let path = try store.save(snapshot)
        #expect(path.hasPrefix("research/snapshots/"))
        let saved = try #require(store.latest())
        #expect(saved.channel == snapshot.channel)
        #expect(saved.videos == snapshot.videos)
        #expect(abs(saved.takenAt.timeIntervalSince(snapshot.takenAt)) < 1)
    }

    @Test func pageSnapshotIsLabelledAndExplainsWhatIsMissing() async throws {
        let yt = service(key: nil, pages: pagesWithChannel())
        let snapshot = try await yt.snapshot("@lighthousestories")
        #expect(snapshot.source == .page)
        #expect(snapshot.videos.count == 3)
        #expect(snapshot.complete)
        #expect(snapshot.notes.contains { $0.contains("not on public listing pages") })
    }

    @Test func videoLinkResolvesThroughItsWatchPage() async throws {
        let pages = pagesWithChannel()
        pages.page("/watch", #"<script>var ytInitialPlayerResponse = {"videoDetails":{"channelId":"UCabcdefghijklmnopqrstuv"}};</script>"#)
        let (channel, source) = try await service(key: nil, pages: pages).resolve("https://youtu.be/aaaaaaaaaaa")
        #expect(channel.title == "Lighthouse Stories")
        #expect(source == .page)
    }

    @Test func pagesArePacedApart() async throws {
        let paced = PacedPageSource(pagesWithChannel(), interval: .milliseconds(200))
        let started = ContinuousClock.now
        async let first = paced.load(URL(string: "https://www.youtube.com/@lighthousestories")!)
        async let second = paced.load(URL(string: "https://www.youtube.com/@lighthousestories")!)
        _ = try await (first, second)
        #expect(ContinuousClock.now - started >= .milliseconds(200))
    }
}
