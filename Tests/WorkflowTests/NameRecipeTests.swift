import ChannelStore
import Engines
import Foundation
import Naming
import Support
import Testing
@testable import Workflow
@testable import YouTubeData

/// No page exists, so every handle looks free and no channel shares a name.
struct EmptyYouTube: PageSource {
    func load(_ url: URL) async throws -> PageResult { PageResult(status: 404, html: "") }
}

struct NoWeb: HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { HTTPResponse(status: 404, data: Data()) }
}

@Suite struct NameRecipeTests {
    @Test func nameStepChecksWaitsForAPickAndSetsTheHandle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-namerun-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Ships", niche: "Shipwrecks")).folder
        let tools = base.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)

        let words = ["Keel", "Brine", "Salt", "Tide", "Wreck", "Hull", "Mast", "Fathom", "Shoal", "Reef",
                     "Gale", "Helm", "Anchor", "Drift", "Swell", "Harbor", "Beacon", "Current", "Depth", "Wake",
                     "Spar", "Rigging", "Lantern", "Compass", "Ballast", "Bow", "Stern", "Galley", "Cove", "Squall"]
        let names = words.map { #"{"name":"\#($0) Notes","handle":"\#($0.lowercased())notes","why":"fits"}"# }.joined(separator: ",")
        let tool = try fakeClaude(outputs: [claudeResult(#"{"names":[\#(names)]}"#)], in: tools)

        let ledger = QuotaLedger(file: base.appendingPathComponent("quota.json"))
        let youtube = YouTubeService(key: { nil }, ledger: ledger, http: NoWeb(), pages: EmptyYouTube())
        let context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 makeRunner: { id, _ in EngineRunner(adapter: EngineRegistry.adapter(for: id), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                                 youtube: youtube, http: NoWeb())
        let node = Node(NodeRegistry.type("name")!)
        #expect(NodeRunExecutor.canRun(node))
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context, note: "Short and salty"))

        let waiting = await driver.start(node)
        #expect(waiting.stage == .awaitingApproval)
        let pending = try #require(NameRecipe.pending(in: waiting, folder: folder))
        #expect(pending.candidates.count == 30)
        #expect(pending.cards.count == 8)
        #expect(pending.note == "Short and salty")
        #expect(pending.cards.allSatisfy { $0.label == .clear && $0.domain == .looksFree })
        #expect(try folder.readText("\(waiting.folder)/prompt.md").contains("Short and salty"))

        try NameRecipe.choose("Brine Notes", fallbacks: ["thebrinenotes", "brinenoteshq"], in: waiting, folder: folder)
        let done = await driver.resume(try RunStore(folder: folder).load(waiting.id), ownerApproved: true)
        #expect(done.stage == .finished)
        let file = try folder.readJSON(NameFile.self, NameRecipe.output)
        #expect(file.chosen == "Brine Notes")
        #expect(file.fallbackHandles == ["thebrinenotes", "brinenoteshq"])
        #expect(try folder.manifest().handle == "brinenotes")

        // A second round is told what was already suggested.
        let again = NodeRunExecutor(node: node, context: context)
        #expect(try NameRecipe().task(node: node, folder: folder).contains("Keel Notes"))
        _ = again
    }
}
