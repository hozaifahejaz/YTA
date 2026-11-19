import ChannelStore
import Engines
import Foundation
import Media
import Support
import Testing
@testable import Workflow
@testable import YouTubeData

/// Commons with one non-commercial and one CC BY-SA result for every search, and a 1920 × 1080 PNG behind every file link.
final class FakeCommons: HTTPClient, @unchecked Sendable {
    static let png: Data = {
        var data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        data += Data([0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38]) + Data(count: 64)
        return data
    }()

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        if url.host == "commons.wikimedia.org" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "gsrsearch" }?.value ?? ""
            let slug = query.split(separator: " ").first.map(String.init) ?? "x"
            return HTTPResponse(status: 200, data: Data(#"""
            {"query":{"pages":{
              "1":{"pageid":1\#(slug.count),"index":1,"title":"File:\#(slug) nc.jpg","imageinfo":[{"url":"https://upload.example/\#(slug)-nc.png","descriptionurl":"https://commons.example/\#(slug)-nc","width":3000,"height":2000,"mime":"image/png","extmetadata":{"Artist":{"value":"Ann"},"LicenseShortName":{"value":"CC BY-NC 2.0"},"LicenseUrl":{"value":"https://creativecommons.org/licenses/by-nc/2.0"}}}]},
              "2":{"pageid":2\#(slug.count),"index":2,"title":"File:\#(slug).png","imageinfo":[{"url":"https://upload.example/\#(slug).png","descriptionurl":"https://commons.example/\#(slug)","thumburl":"https://upload.example/\#(slug)-thumb.png","width":1920,"height":1080,"mime":"image/png","extmetadata":{"Artist":{"value":"<b>Bo</b>"},"LicenseShortName":{"value":"CC BY-SA 4.0"},"LicenseUrl":{"value":"https://creativecommons.org/licenses/by-sa/4.0"}}}]}
            }}}
            """#.utf8))
        }
        return HTTPResponse(status: 200, data: Self.png)
    }
}

@Suite struct MediaRecipeTests {
    func setup() throws -> (ChannelFolder, VideoFile, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-media-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Keel", niche: "Shipwrecks")).folder
        try WorkflowStore(folder: folder).installDefaults(origin: .new, nicheGiven: true)
        let video = try VideoStore(folder: folder).add(title: "Why the Vasa sank")
        let beats = ScriptBeat.make([("The Vasa sailed from Stockholm in August and it was the pride of the navy that summer", "hook"),
                                     ("Then a gust came and she leaned hard", "beat")], rate: 150)
        try folder.writeJSON(beats, to: video.path("script.beats.json"))
        var sources = SourcesConfig()
        sources.mediaOrder = ["commons"]
        try folder.writeJSON(sources, to: ChannelLayout.sources)
        return (folder, video, base)
    }

    func context(_ outputs: [String], base: URL, video: VideoFile, http: HTTPClient) throws -> RunContext {
        let tools = base.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = try fakeClaude(outputs: outputs, in: tools)
        return RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                          makeRunner: { _, _ in EngineRunner(adapter: EngineRegistry.adapter(for: .claude), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                          http: http, video: video)
    }

    func run(_ node: Node, _ context: RunContext, folder: ChannelFolder) async throws -> RunRecord {
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context))
        var record = await driver.start(node)
        if record.stage == .awaitingApproval {
            record = await driver.resume(try RunStore(folder: folder).load(record.id), ownerApproved: true)
        }
        return record
    }

    @Test func shotsAreTimedSplitAndNumbered() async throws {
        let (folder, video, base) = try setup()
        let shots = #"{"shots":[{"beat":0,"from":"The Vasa sailed","see":"The Vasa model","terms":["Vasa ship"],"kind":"photo"},{"beat":0,"from":"it was the pride","see":"Swedish navy 1628","terms":["Swedish navy"],"kind":"photo"},{"beat":1,"from":"Then a gust","see":"Ship heeling","terms":["ship heeling"],"kind":"archiveFootage"}]}"#
        let node = video.row.nodes.first { $0.type == "shots" }!
        let record = try await run(node, try context([claudeResult(shots)], base: base, video: video, http: FakeCommons()), folder: folder)
        #expect(record.stage == .finished, "\(record.error ?? "")")
        let list = try folder.readJSON(ShotList.self, video.path(ShotList.file))
        #expect(list.shots.map(\.id) == ["s001", "s002", "s003"])
        #expect(list.shots[1].text.hasPrefix("it was the pride"))
        #expect(list.shots[0].start == 0 && list.shots[0].end == list.shots[1].start)
        #expect(list.shots.allSatisfy { $0.length <= ShotsRecipe.longest })
        #expect(!list.timedFromNarration)
    }

    @Test func everyChosenAssetHasACompleteLedgerEntryAndNonCommercialIsRejected() async throws {
        let (folder, video, base) = try setup()
        let shots = ShotList(timedFromNarration: false, shots: [
            Shot(id: "s001", beat: 0, text: "The Vasa sailed", see: "The Vasa", terms: ["Vasa ship"], kind: .photo, start: 0, end: 4),
            Shot(id: "s002", beat: 0, text: "1628", see: "The year", terms: ["1628"], kind: .textCard, start: 4, end: 6),
            Shot(id: "s003", beat: 1, text: "Then a gust", see: "Stockholm harbour", terms: ["Stockholm harbour"], kind: .photo, start: 6, end: 10),
        ])
        try folder.writeJSON(shots, to: video.path(ShotList.file))
        let ranking = #"{"picks":[{"shot":"s001","order":[0],"watermarked":[]},{"shot":"s003","order":[0],"watermarked":[]}]}"#
        let node = video.row.nodes.first { $0.type == "media" }!
        let record = try await run(node, try context([claudeResult(ranking)], base: base, video: video, http: FakeCommons()), folder: folder)
        #expect(record.stage == .finished, "\(record.error ?? "")")

        let ledger = try folder.readJSON(Ledger.self, video.path(Ledger.file))
        #expect(ledger.entries.count == 2)
        #expect(ledger.incomplete.isEmpty)
        #expect(ledger.entries.allSatisfy { $0.licence == .ccBySa && $0.shareAlike && $0.creditRequired })
        #expect(ledger.entries.first?.author == "Bo")
        #expect(ledger.entries.first?.sha256 == SHA256.hex(FakeCommons.png))
        #expect(!ledger.entries.contains { $0.licenceName.contains("NC") })

        let rejected = try folder.readJSON([MediaRecipe.Rejection].self, "\(record.folder)/rejected.json")
        #expect(rejected.contains { $0.reason == "Non-commercial licence." })

        let plan = try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file))
        #expect(plan.rankedBy.hasPrefix("Claude"))
        #expect(plan.shots.first { $0.shot == "s002" }?.filler == "textCard")
        #expect(folder.exists(video.path("media/s001.png")))
        #expect(UsedAssets.load(folder).assets[ledger.entries[0].id] == [video.id])
    }

    @Test func shareAlikeCanBeSwitchedOff() async throws {
        let (folder, video, base) = try setup()
        var sources = folder.sources()
        sources.allowShareAlike = false
        try folder.writeJSON(sources, to: ChannelLayout.sources)
        let shots = ShotList(timedFromNarration: false, shots: [
            Shot(id: "s001", beat: 0, text: "The Vasa sailed", see: "The Vasa", terms: ["Vasa ship"], kind: .photo, start: 0, end: 4),
        ])
        try folder.writeJSON(shots, to: video.path(ShotList.file))
        let node = video.row.nodes.first { $0.type == "media" }!
        let record = try await run(node, try context([], base: base, video: video, http: FakeCommons()), folder: folder)
        #expect(record.stage == .finished, "\(record.error ?? "")")
        let plan = try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file))
        #expect(plan.shots[0].assetID == nil && plan.shots[0].filler == "textCard")
        #expect(try folder.readJSON(Ledger.self, video.path(Ledger.file)).entries.isEmpty)
    }
}
