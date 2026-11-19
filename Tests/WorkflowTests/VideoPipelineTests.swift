import ChannelStore
import Engines
import Foundation
import Support
import Testing
@testable import Workflow
@testable import YouTubeData

@Suite struct VideoPipelineTests {
    func channel() throws -> (ChannelFolder, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-video-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Keel", niche: "Shipwrecks")).folder
        try WorkflowStore(folder: folder).installDefaults(origin: .new, nicheGiven: true)
        return (folder, base)
    }

    func context(_ outputs: [String], base: URL, folder: ChannelFolder, video: VideoFile?, pages: PageSource = EmptyYouTube()) throws -> RunContext {
        let tools = base.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = try fakeClaude(outputs: outputs, in: tools)
        let youtube = YouTubeService(key: { nil }, ledger: QuotaLedger(file: base.appendingPathComponent("quota.json")), http: NoWeb(), pages: pages)
        return RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                          makeRunner: { _, _ in EngineRunner(adapter: EngineRegistry.adapter(for: .claude), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                          youtube: youtube, http: NoWeb(), video: video)
    }

    func run(_ node: Node, _ context: RunContext, folder: ChannelFolder, note: String? = nil) async throws -> RunRecord {
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context, note: note))
        var record = await driver.start(node)
        if record.stage == .awaitingApproval {
            record = await driver.resume(try RunStore(folder: folder).load(record.id), ownerApproved: true)
        }
        return record
    }

    static func words(_ count: Int, start: String) -> String {
        ([start] + Array(repeating: "wreck", count: count - 1)).joined(separator: " ")
    }

    static func beats(_ texts: [String]) -> String {
        #"{"beats":["# + texts.map { #"{"text":"\#($0)","purpose":"beat"}"# }.joined(separator: ",") + "]}"
    }

    @Test func theQueueAddsOrdersAndRenamesVideos() throws {
        let (folder, _) = try channel()
        let store = VideoStore(folder: folder)
        #expect(VideoStore.titles(fromList: "1. The Lost Fleet\n- Why ships sink\n\n• Titanic: the last hour", csv: false)
            == ["The Lost Fleet", "Why ships sink", "Titanic: the last hour"])
        #expect(VideoStore.titles(fromList: "title,notes\n\"Ships, sunk\",x\nPlain,y", csv: true) == ["Ships, sunk", "Plain"])

        let added = try store.addMany(["The Lost Fleet", "Titanic: the last hour", "The Lost Fleet"])
        #expect(added[1].folderName == "Titanic - the last hour")
        #expect(added[2].folderName == "The Lost Fleet 2")
        #expect(!added[0].row.nodes.contains { $0.type == "topic" })
        #expect(added[0].row.nodes.first { $0.type == "script" }?.engine?.tool == .codex)

        let own = try store.add(title: "My own", script: "# My own\n\nFirst part.\n\nSecond part.")
        #expect(own.ownScript && !own.settings.researchNotes)
        #expect(own.row.nodes.map(\.type).prefix(3) == ["brief", "ownScript", "review"])

        try store.move(own.id, to: 0)
        #expect(store.all().first?.id == own.id)
        try store.setStatus(own.id, .paused)
        #expect(store.next()?.id == added[0].id)

        let renamed = try store.retitle(added[0].id, to: "The Fleet That Vanished")
        #expect(renamed.folderName == "The Fleet That Vanished")
        #expect(renamed.previousFolderNames == ["The Lost Fleet"])
        #expect(folder.exists("videos/The Fleet That Vanished/Working files/video.json"))
        #expect(store.video(added[0].id)?.titleHistory == ["The Lost Fleet", "The Fleet That Vanished"])
    }

    @Test func aTitleBecomesAReviewedScriptWithinTolerance() async throws {
        let (folder, base) = try channel()
        let video = try VideoStore(folder: folder).add(title: "Why the Vasa sank", settings: VideoSettings(words: 60))
        func node(_ type: String) -> Node { video.row.nodes.first { $0.type == type }! }

        #expect(try await run(node("brief"), try context([], base: base, folder: folder, video: video), folder: folder).stage == .finished)
        #expect(try folder.readText(video.path("brief.md")).contains("60 words"))

        let research = #"{"notes":"\#(String(repeating: "The Vasa sank in 1628 [1]. ", count: 10))","sources":[{"title":"Vasa Museum","url":"https://www.vasamuseet.se","supports":["1628"]}]}"#
        #expect(try await run(node("researchNotes"), try context([claudeResult(research)], base: base, folder: folder, video: video), folder: folder).stage == .finished)
        #expect(folder.exists(video.path("sources.json")))

        let prompt = #"{"prompt":"\#(String(repeating: "Write about the Vasa. ", count: 20))"}"#
        let prompted = try await run(node("prompt"), try context([claudeResult(prompt)], base: base, folder: folder, video: video), folder: folder)
        #expect(prompted.stage == .finished)
        #expect(try folder.readText("\(prompted.folder)/prompt.md").contains("delve"))

        // First draft: too long and uses a banned phrase. The revision fixes both.
        let first = Self.beats([Self.words(30, start: "Let's delve"), Self.words(30, start: "Then"), Self.words(30, start: "Finally")])
        let second = Self.beats([Self.words(20, start: "Sweden's"), Self.words(20, start: "Then"), Self.words(20, start: "Finally")])
        let okReview = #"{"scores":[{"beat":0,"retention":8,"human":8,"note":"ok"}],"mustFix":[],"cuttable":[],"overall":"Good"}"#
        let scripted = try await run(node("script"), try context([claudeResult(first), claudeResult(okReview), claudeResult(second), claudeResult(okReview)],
                                                                 base: base, folder: folder, video: video), folder: folder)
        #expect(scripted.stage == .finished, "\(scripted.error ?? "")")
        let review = try folder.readJSON(ScriptReview.self, video.path("review.json"))
        #expect(review.rounds == 1)
        #expect(review.passed)
        #expect(review.checks.words == 60)
        let beats = try folder.readJSON([ScriptBeat].self, video.path("script.beats.json"))
        #expect(beats.count == 3 && beats[1].start == 8)
        #expect(try folder.readText(video.path("script.md")).hasPrefix("# Why the Vasa sank\n\nSweden's"))
        #expect(try folder.readText("\(scripted.folder)/revision-1-prompt.md").contains("banned phrase \"delve\""))
        #expect(UsedPhrases.load(folder).contains("Sweden's wreck wreck wreck wreck wreck wreck wreck"))
        #expect(VideoStore(folder: folder).video(video.id)?.status == .queued)
    }

    @Test func checksFailAfterTwoRevisionsAndSayWhy() {
        let beats = ScriptBeat.make([(text: "In today's video we delve deep", purpose: "")], rate: 150)
        let check = ScriptCheck.run(beats, target: 100, tolerance: 0.05, banned: ["delve", "in today's video", "dive"], used: [])
        #expect(check.banned.map(\.phrase) == ["delve", "in today's video"])
        #expect(!check.lengthOK)
        #expect(check.notes.first?.contains("Add about 94 words") == true)
    }

    @Test func theOwnersScriptIsCheckedButNeverChanged() async throws {
        let (folder, base) = try channel()
        let script = "# Mine\n\nIt's important to note this wreck.\n\nAnd that one."
        let video = try VideoStore(folder: folder).add(title: "Mine", script: script, settings: VideoSettings(words: 8))
        let node = video.row.nodes.first { $0.type == "ownScript" }!
        let done = try await run(node, try context([], base: base, folder: folder, video: video), folder: folder)
        #expect(done.stage == .finished)
        #expect(try folder.readText(video.path("script.md")) == script)
        let review = try folder.readJSON(ScriptReview.self, video.path("review.json"))
        #expect(review.checks.banned.map(\.phrase) == ["it's important to note"])
        #expect(review.checks.words == 9)
    }

    @Test func topicResearchFindsOutliersAndQueuesPicks() async throws {
        let (folder, base) = try channel()
        try folder.writeJSON([YouTubeChannel(id: "UCkeel0123456789abcdefgh", title: "Keel Stories", subscriberCount: 42_000)],
                             to: NicheRecipe.competitors)
        let topics = (0..<10).map { index in
            #"{"topic":"Topic \#(index)","why":"Outlier","evidence":["k4"],"demand":\#(index % 10 + 1),"fit":5,"freshness":5,"crowding":5,"titles":["A \#(index)","B \#(index)","C","D","E"]}"#
        }.joined(separator: ",")
        let context = try context([claudeResult(#"{"topics":[\#(topics)]}"#)], base: base, folder: folder, video: nil, pages: ImportPages())
        let node = WorkflowStore(folder: folder).setupRow()!.nodes.first { $0.type == "topicResearch" }!
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context))
        let waiting = await driver.start(node)
        #expect(waiting.stage == .awaitingApproval, "\(waiting.error ?? "")")
        let file = try #require(TopicRecipe.pending(in: waiting, folder: folder))
        #expect(file.outliers.map(\.id) == ["k4"])
        #expect(file.outliers.first?.multiple == 8.8)
        #expect(file.topics.count == 10 && file.topics.first?.topic == "Topic 9")

        try TopicRecipe.pick([TopicFile.Pick(topic: 0, title: "A 9"), TopicFile.Pick(topic: 3, title: "B 6")], in: waiting, folder: folder)
        #expect(await driver.resume(try RunStore(folder: folder).load(waiting.id), ownerApproved: true).stage == .finished)
        let queued = VideoStore(folder: folder).all()
        #expect(queued.map(\.title) == ["A 9", "B 6"])
        #expect(queued.first?.topic?.hasPrefix("Topic 9") == true)
    }
}
