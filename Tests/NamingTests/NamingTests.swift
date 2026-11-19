import Foundation
import Support
import Testing
@testable import Naming
@testable import YouTubeData

/// Public pages keyed by path. Unknown paths are 404, like YouTube for a free handle.
final class Pages: PageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: String] = [:]
    private(set) var loaded: [String] = []

    func set(_ path: String, _ html: String) { lock.withLock { pages[path] = html } }

    func load(_ url: URL) async throws -> PageResult {
        lock.withLock {
            let key = url.path == "/results"
                ? "/results?" + (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search_query" }?.value ?? "")
                : url.path
            loaded.append(key)
            guard let html = pages[key] else { return PageResult(status: 404, html: "") }
            return PageResult(status: 200, html: html)
        }
    }
}

/// HTTP answers keyed by host and path.
final class Web: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (Int, String)] = [:]

    func set(_ hostAndPath: String, _ status: Int, _ body: String = "") { lock.withLock { answers[hostAndPath] = (status, body) } }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.withLock {
            let (status, body) = answers["\(url.host ?? "")\(url.path)"] ?? (404, "")
            return HTTPResponse(status: status, data: Data(body.utf8))
        }
    }
}

func channelPage(id: String, title: String, handle: String) -> String {
    #"<script>var ytInitialData = {"metadata":{"channelMetadataRenderer":{"title":"\#(title)","externalId":"\#(id)","vanityChannelUrl":"http://www.youtube.com/@\#(handle)"}}};</script>"#
}

func searchPage(_ channels: [(id: String, title: String, subscribers: String)]) -> String {
    let items = channels.map {
        #"{"channelRenderer":{"channelId":"\#($0.id)","title":{"simpleText":"\#($0.title)"},"subscriberCountText":{"simpleText":"@x"},"videoCountText":{"simpleText":"\#($0.subscribers) subscribers"}}}"#
    }.joined(separator: ",")
    return #"<script>var ytInitialData = {"contents":[\#(items)]};</script>"#
}

func videosPage(ago: String) -> String {
    #"<script>var ytInitialData = {"contents":[{"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"v"},"publishedTimeText":{"simpleText":"\#(ago)"}}}]};</script>"#
}

func service(_ pages: Pages) -> YouTubeService {
    let ledger = QuotaLedger(file: FileManager.default.temporaryDirectory.appendingPathComponent("yta-name-\(UUID().uuidString)/quota.json"))
    return YouTubeService(key: { nil }, ledger: ledger, http: Web(), pages: pages)
}

@Suite struct NameRuleTests {
    @Test func ideasThatBreakTheRulesAreDropped() {
        #expect(NameRules.problem(with: NameIdea(name: "Tidewatch", handle: "tidewatch")) == nil)
        #expect(NameRules.problem(with: NameIdea(name: "Deep Tide", handle: "deeptide")) == nil)
        #expect(NameRules.problem(with: NameIdea(name: "The Deep Blue Sea", handle: "deepbluesea")) != nil)
        #expect(NameRules.problem(with: NameIdea(name: "Tide 9", handle: "tide9")) != nil)
        #expect(NameRules.problem(with: NameIdea(name: "Tide-Watch", handle: "tidewatch")) != nil)
        #expect(NameRules.problem(with: NameIdea(name: "Tidewatch", handle: "tide-watch")) != nil)
        #expect(NameRules.problem(with: NameIdea(name: "Tidewatch", handle: "x")) != nil)
    }

    @Test func nearNamesAreOneLetterApart() {
        #expect(NameRules.isNear("Tide Watch", "tidewatch"))
        #expect(NameRules.isNear("Tidewatch", "Tidewatcj"))
        #expect(!NameRules.isNear("Tide", "Tidy"))
        #expect(!NameRules.isNear("Tidewatch", "Seawatch"))
        #expect(NameRules.domainLabel("Café Noir") == "cafenoir")
    }

    @Test func labelsFollowTheThresholds() {
        let thresholds = NameOverlapThresholds()
        var candidate = NameCandidate(idea: NameIdea(name: "Tidewatch", handle: "tidewatch"))
        candidate.handleStatus = .looksFree
        candidate.matches = [ChannelMatch(id: "UC1", title: "Ocean facts", subscriberCount: 90_000, lastUploadDays: 2, source: .page)]
        #expect(NameRules.label(candidate, thresholds: thresholds) == .clear)

        candidate.matches = [ChannelMatch(id: "UC2", title: "Tide Watch", subscriberCount: 300, lastUploadDays: 800, source: .page)]
        #expect(NameRules.label(candidate, thresholds: thresholds) == .smallOverlap)

        candidate.matches = [ChannelMatch(id: "UC3", title: "Tide Watch", subscriberCount: 300, lastUploadDays: 20, source: .page)]
        #expect(NameRules.label(candidate, thresholds: thresholds) == .taken)

        candidate.matches = [ChannelMatch(id: "UC4", title: "TideWatch", subscriberCount: 5_000, lastUploadDays: 800, source: .page)]
        #expect(NameRules.label(candidate, thresholds: thresholds) == .taken)
        #expect(NameRules.label(candidate, thresholds: NameOverlapThresholds(maxSubscribers: 10_000)) == .smallOverlap)

        candidate.handleStatus = .taken
        candidate.matches = []
        #expect(NameRules.label(candidate, thresholds: thresholds) == .taken)
    }

    @Test func socialPagesAreReadAsHints() {
        #expect(WebPresence.read(.instagram, handle: "tidewatch", status: 404, html: "") == .looksFree)
        #expect(WebPresence.read(.instagram, handle: "tidewatch", status: 200, html: "<title>Tide (@tidewatch) • Instagram</title>") == .looksTaken)
        #expect(WebPresence.read(.instagram, handle: "tidewatch", status: 200, html: "<title>Instagram</title>") == .unknown)
        #expect(WebPresence.read(.tiktok, handle: "tidewatch", status: 200, html: #"{"uniqueId":"tidewatch"}"#) == .looksTaken)
        #expect(WebPresence.read(.tiktok, handle: "tidewatch", status: 200, html: #"{"statusCode":10221}"#) == .looksFree)
        #expect(WebPresence.read(.x, handle: "tidewatch", status: 200, html: "anything") == .unknown)
    }

    @Test func dotComFromRDAP() async {
        let web = Web()
        web.set("rdap.verisign.com/com/v1/domain/tidewatch.com", 200, "{}")
        let presence = WebPresence(http: web)
        #expect(await presence.dotCom("Tidewatch") == .looksTaken)
        #expect(await presence.dotCom("Brinefold") == .looksFree)
    }
}

@Suite struct NameCheckerTests {
    @Test func checksHandlesSearchesTheBestAndShortlistsClearFirst() async throws {
        let pages = Pages()
        // @tidewatch is taken; Brinefold has a small quiet namesake; the rest are clear.
        pages.set("/@tidewatch", channelPage(id: "UCtide", title: "Tide Watch", handle: "tidewatch"))
        pages.set("/results?Brinefold", searchPage([(id: "UCbrine", title: "Brine Fold", subscribers: "120")]))
        pages.set("/channel/UCbrine/videos", videosPage(ago: "3 years ago"))
        pages.set("/results?Saltlight", searchPage([(id: "UCsalt", title: "Saltlight", subscribers: "2.1M")]))
        pages.set("/channel/UCsalt/videos", videosPage(ago: "2 days ago"))

        let ideas = [
            NameIdea(name: "Tidewatch", handle: "tidewatch"),
            NameIdea(name: "Brinefold", handle: "brinefold"),
            NameIdea(name: "Saltlight", handle: "saltlight"),
            NameIdea(name: "Keel Notes", handle: "keelnotes"),
            NameIdea(name: "Bad 1", handle: "bad1"),
            NameIdea(name: "Keel Notes Again", handle: "keelnotes"),
        ]
        var checker = NameChecker(youtube: service(pages), presence: WebPresence(http: Web()), thresholds: NameOverlapThresholds())
        checker.searched = 3
        let result = try await checker.check(ideas)

        #expect(result.candidates.map(\.idea.name) == ["Tidewatch", "Brinefold", "Saltlight", "Keel Notes"])
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.idea.name, $0) })
        #expect(byName["Tidewatch"]?.label == .taken)
        #expect(byName["Tidewatch"]?.handleOwner == "Tide Watch")
        #expect(byName["Tidewatch"]?.matches == nil)
        #expect(byName["Brinefold"]?.label == .smallOverlap)
        #expect(byName["Saltlight"]?.label == .taken)
        #expect(byName["Keel Notes"]?.label == .clear)
        #expect(result.shortlist == ["Keel Notes", "Brinefold"])
        // Hints only for the cards.
        #expect(byName["Keel Notes"]?.domain == .looksFree)
        #expect(byName["Saltlight"]?.domain == .unknown)
    }

    @Test func choosingKeepsFallbacks() async throws {
        let pages = Pages()
        pages.set("/@keelnotestv", channelPage(id: "UCk", title: "Keel TV", handle: "keelnotestv"))
        let checker = NameChecker(youtube: service(pages), presence: WebPresence(http: Web()), thresholds: NameOverlapThresholds())
        let fallbacks = await checker.fallbacks(for: "keelnotes")
        #expect(fallbacks == ["thekeelnotes", "keelnoteshq"])

        var card = NameCandidate(idea: NameIdea(name: "Keel Notes", handle: "keelnotes"))
        card.label = .clear
        let file = NameFile(round: 1, note: nil, generatedAt: Date(), candidates: [card], shortlist: ["Keel Notes"],
                            thresholds: NameOverlapThresholds())
        let chosen = try file.choosing("Keel Notes", fallbacks: fallbacks)
        #expect(chosen.chosen == "Keel Notes")
        #expect(chosen.handle == "keelnotes")
        #expect(chosen.fallbackHandles == ["thekeelnotes", "keelnoteshq"])
        #expect(throws: YTAError.self) { try file.choosing("Nope", fallbacks: []) }
        #expect(NameFile.trademarkSearchURL("Keel Notes").absoluteString.contains("query=Keel%20Notes"))
    }
}
