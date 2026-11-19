import ChannelStore
import Engines
import Foundation
import Support
import Testing
@testable import Workflow
@testable import YouTubeData

/// Search pages list four videos from three channels; channel pages give subscriber counts.
struct NichePages: PageSource {
    static let videos: [(id: String, views: Int, length: String, age: String, channel: String)] = [
        ("v1", 900_000, "14:05", "2 months ago", "UCsmall"),
        ("v2", 40_000, "11:10", "3 weeks ago", "UCbig"),
        ("v3", 60_000, "0:45", "5 days ago", "UCbig"),
        ("v4", 50_000, "18:00", "2 years ago", "UCmid"),
    ]
    static let subscribers = ["UCsmall": "8.2K subscribers", "UCbig": "1.4M subscribers", "UCmid": "120K subscribers"]

    func load(_ url: URL) async throws -> PageResult {
        if url.path == "/results" {
            let items = Self.videos.map { video in
                #"{"videoRenderer":{"videoId":"\#(video.id)","title":{"runs":[{"text":"Video \#(video.id)"}]},"lengthText":{"simpleText":"\#(video.length)"},"viewCountText":{"simpleText":"\#(video.views) views"},"publishedTimeText":{"simpleText":"\#(video.age)"},"ownerText":{"runs":[{"text":"\#(video.channel)","navigationEndpoint":{"browseEndpoint":{"browseId":"\#(video.channel)"}}}]}}}"#
            }.joined(separator: ",")
            return PageResult(status: 200, html: Self.page(#"{"contents":[\#(items)]}"#))
        }
        let id = String(url.path.split(separator: "/").last ?? "")
        guard let subs = Self.subscribers[id] else { return PageResult(status: 404, html: "") }
        return PageResult(status: 200, html: Self.page(#"{"metadata":{"channelMetadataRenderer":{"externalId":"\#(id)","title":"\#(id)"}},"header":{"count":{"simpleText":"\#(subs)"}}}"#))
    }

    static func page(_ data: String) -> String {
        #"<html><head><script nonce="y">var ytInitialData = \#(data);</script></head><body></body></html>"#
    }
}

@Suite struct NicheRecipeTests {
    static func discover() -> String {
        let considered = (1...25).map { "\"Idea \($0)\"" }.joined(separator: ",")
        let screened = (0..<12).map { index in
            #"{"niche":"Niche \#(index)","angle":"Angle \#(index)","why":"Fits","queries":["q\#(index) a","q\#(index) b","q\#(index) c"],"sources":["https://example.com/\#(index)"]}"#
        }.joined(separator: ",")
        return #"{"considered":[\#(considered)],"screened":[\#(screened)]}"#
    }

    static func scores(evidence: String) -> String {
        let candidates = (0..<12).map { index in
            let dims = NicheBrief.dimensions.map { #"{"key":"\#($0.key)","score":\#(index == 3 ? 9 : 5),"note":"n","evidence":["\#(evidence)"]}"# }
                .joined(separator: ",")
            return #"{"index":\#(index),"scores":[\#(dims)],"audience":"Curious adults","rpmLow":4,"rpmHigh":9,"ideas":["a","b","c","d","e"],"risk":"Saturation"}"#
        }.joined(separator: ",")
        return #"{"candidates":[\#(candidates)]}"#
    }

    @Test func aStandardRunMeasuresScoresChallengesAndShortlists() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-niche-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Research", niche: "History")).folder
        let tools = base.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let challenge = #"{"challenges":[{"index":0,"argument":"Too narrow","severity":"fatal"},{"index":1,"argument":"Fine","severity":"minor"}]}"#
        let tool = try fakeClaude(outputs: [claudeResult(Self.discover()), claudeResult(Self.scores(evidence: "my hunch")),
                                            claudeResult(Self.scores(evidence: "medianRecentViews")), claudeResult(challenge)], in: tools)
        let youtube = YouTubeService(key: { nil }, ledger: QuotaLedger(file: base.appendingPathComponent("quota.json")),
                                     http: NoWeb(), pages: NichePages())
        let context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 makeRunner: { _, _ in EngineRunner(adapter: EngineRegistry.adapter(for: .claude), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                                 youtube: youtube, http: NoWeb())
        let brief = NicheBrief(interests: "History", depth: .standard)
        let note = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
        let node = Node(NodeRegistry.type("niche")!)
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context, note: note))

        let waiting = await driver.start(node)
        #expect(waiting.stage == .awaitingApproval, "\(waiting.error ?? "")")
        let list = try #require(NicheRecipe.pending(in: waiting, folder: folder))
        #expect(list.considered.count == 25)
        #expect((3...5).contains(list.cards.count))
        #expect(list.cards.count + list.runnersUp.count == 12)
        // Candidate 3 scored highest but the challenge called it fatal, so it drops below the rest.
        #expect(list.cards.first?.niche != "Niche 3")
        #expect(list.runnersUp.last?.niche == "Niche 3")
        #expect(list.runnersUp.last?.challenge?.severity == "fatal")

        let card = try #require(list.cards.first)
        #expect(card.measuredWith == .page)
        #expect(card.measures.medianRecentViews == 60_000)
        #expect(card.measures.strongFromSmallShare == 1)
        #expect(card.measures.shortsShare == 0.25)
        #expect(card.channels.first?.title == "UCbig")
        #expect(card.outliers.first?.id == "v1")
        #expect(card.earningsLow == 60_000 * 8 * 4 / 1000)
        #expect(card.scores.allSatisfy { $0.evidence == ["medianRecentViews"] })
        // Each sample is saved with the shortlist, so every number traces to what YouTube returned.
        let samplePath = card.evidenceFile
        #expect(RunStore(folder: folder).draft(for: waiting)?.files[samplePath] != nil)

        try NicheRecipe.choose(0, in: waiting, folder: folder)
        let done = await driver.resume(try RunStore(folder: folder).load(waiting.id), ownerApproved: true)
        #expect(done.stage == .finished, "\(done.error ?? "")")
        #expect(try folder.readText("profile/niche.md").contains(card.niche))
        #expect(try folder.readText("profile/audience.md").contains("Curious adults"))
        #expect(try folder.readJSON(NicheSample.self, samplePath).videos.count == 4)
        #expect(try folder.readJSON([YouTubeChannel].self, NicheRecipe.competitors).count == 3)
    }

    @Test func scoresWithoutEvidenceAreRejected() {
        #expect(NicheRecipe.evidenceProblem(JSONValue.parse(Self.scores(evidence: "vibes"))!, count: 12, sources: []) != nil)
        #expect(NicheRecipe.evidenceProblem(JSONValue.parse(Self.scores(evidence: "https://example.com/1"))!, count: 12,
                                            sources: ["https://example.com/1"]) == nil)
        #expect(NicheRecipe.evidenceProblem(JSONValue.parse(Self.scores(evidence: "medianRecentViews"))!, count: 13, sources: []) != nil)
    }
}
