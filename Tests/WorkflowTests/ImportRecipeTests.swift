import ChannelStore
import Engines
import Foundation
import Naming
import Support
import Testing
@testable import Workflow
@testable import YouTubeData

/// One public channel with six long videos, one far above the median.
struct ImportPages: PageSource {
    func load(_ url: URL) async throws -> PageResult {
        let channel = #"{"metadata":{"channelMetadataRenderer":{"externalId":"UCkeel0123456789abcdefgh","title":"Keel Stories","vanityChannelUrl":"http://www.youtube.com/@keel","description":"Shipwreck stories","keywords":"ships wrecks"}},"header":{"count":{"simpleText":"42K subscribers"}}}"#
        switch url.path {
        case "/@keel", "/channel/UCkeel0123456789abcdefgh":
            return PageResult(status: 200, html: NichePages.page(channel))
        case "/@keel/videos":
            let views = [10_000, 12_000, 9_000, 11_000, 95_000, 10_500]
            let items = views.enumerated().map { index, count in
                #"{"videoRenderer":{"videoId":"k\#(index)","title":{"runs":[{"text":"Wreck \#(index)"}]},"lengthText":{"simpleText":"15:00"},"viewCountText":{"simpleText":"\#(count) views"},"publishedTimeText":{"simpleText":"\#(index + 1) weeks ago"}}}"#
            }.joined(separator: ",")
            return PageResult(status: 200, html: NichePages.page(#"{"contents":[\#(items)]}"#))
        default:
            return PageResult(status: 404, html: "")
        }
    }
}

@Suite struct ImportRecipeTests {
    @Test func aPublicChannelBecomesAProfileFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-import-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "keel", origin: .imported, importLink: "@keel")).folder
        let tools = base.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let long = String(repeating: "Grounded in the snapshot. ", count: 6)
        let analysis = #"{"niche":"\#(long)","audience":"\#(long)","pillars":"\#(long)","titlePatterns":"The X that Y","rhythm":"Weekly","whatWins":"\#(long)","winners":[{"id":"k4","why":"A famous wreck"},{"id":"nope","why":"made up"}],"name":"Keel Stories"}"#
        let tool = try fakeClaude(outputs: [claudeResult(analysis)], in: tools)
        let youtube = YouTubeService(key: { nil }, ledger: QuotaLedger(file: base.appendingPathComponent("quota.json")),
                                     http: NoWeb(), pages: ImportPages())
        let context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 makeRunner: { _, _ in EngineRunner(adapter: EngineRegistry.adapter(for: .claude), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                                 youtube: youtube, http: NoWeb())

        func run(_ type: String, note: String? = nil) async throws -> RunRecord {
            let node = Node(NodeRegistry.type(type)!)
            let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context, note: note))
            var record = await driver.start(node)
            if record.stage == .awaitingApproval {
                record = await driver.resume(try RunStore(folder: folder).load(record.id), ownerApproved: true)
            }
            return record
        }

        #expect(try await run("importLink").stage == .finished)
        #expect(try folder.manifest().name == "Keel Stories")
        #expect(try folder.manifest().handle == "keel")

        let snap = try await run("snapshot")
        #expect(snap.stage == .finished, "\(snap.error ?? "")")
        let snapshot = try folder.readJSON(ChannelSnapshot.self, SnapshotRecipe.output)
        #expect(snapshot.videos.count == 6)
        #expect(SnapshotStore(channel: folder).all().count == 1)

        let stats = ChannelStats.compute(snapshot)
        #expect(stats.longMedianViews == 10_750)
        #expect(stats.winners.map(\.id) == ["k4"])
        #expect(stats.uploadsByMonth.reduce(0, +) == 6)

        let analysed = try await run("analysis")
        #expect(analysed.stage == .finished, "\(analysed.error ?? "")")
        #expect(try folder.readText("\(analysed.folder)/prompt.md").contains("k4: \"Wreck 4\", 95000 views"))
        let report = try folder.readText(AnalysisRecipe.report)
        #expect(report.contains("A famous wreck"))
        #expect(!report.contains("made up"))
        #expect(try folder.readText("profile/pillars.md").contains("Grounded"))
        #expect(try folder.readJSON(NameFile.self, NameRecipe.output).chosen == "Keel Stories")

        let answers = ["More wreck mysteries", "", "History fans", "", "One a week", ""]
        let note = String(decoding: try JSONEncoder().encode(answers), as: UTF8.self)
        #expect(try await run("interview", note: note).stage == .finished)
        #expect(InterviewRecipe.answers(in: folder) == answers)
        #expect(try folder.readText("AGENTS.md").contains("Grounded"))
    }
}
