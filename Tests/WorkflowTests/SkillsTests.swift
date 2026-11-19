import ChannelStore
import Engines
import Foundation
import Support
import Testing
@testable import Workflow
@testable import YouTubeData

/// GitHub with one skill folder: a SKILL.md, a reference file and a script.
struct FakeGitHub: HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let text: String
        switch url.absoluteString {
        case "https://api.github.com/repos/acme/skills/contents/research/fact-check":
            text = #"[{"name":"SKILL.md","path":"research/fact-check/SKILL.md","type":"file","size":40,"download_url":"https://raw.example/SKILL.md"},{"name":"scripts","path":"research/fact-check/scripts","type":"dir"}]"#
        case "https://api.github.com/repos/acme/skills/contents/research/fact-check/scripts":
            text = #"[{"name":"check.py","path":"research/fact-check/scripts/check.py","type":"file","size":20,"download_url":"https://raw.example/check.py"}]"#
        case "https://raw.example/SKILL.md": text = "---\nname: fact-check\n---\nCheck facts."
        case "https://raw.example/check.py": text = "print('hi')"
        default: return HTTPResponse(status: 404, data: Data())
        }
        return HTTPResponse(status: 200, data: Data(text.utf8))
    }
}

@Suite struct SkillsTests {
    @Test func shippedSkillsAreCopiedIntoTheChannel() throws {
        #expect(SkillLibrary.shipped().map(\.name) == ["niche-research", "script-review", "thumbnail-concepts", "topic-research"])
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-skills-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base).createChannel(NewChannelRequest(workingName: "Skills")).folder
        try SkillLibrary.installShipped(into: folder)
        #expect(try folder.readText(".agents/skills/niche-research/SKILL.md").contains("name: niche-research"))
        #expect(try folder.readText(".claude/skills/script-review/SKILL.md").contains("name: script-review"))
    }

    @Test func proposedSkillsInstallOnlyWhenTheOwnerSaysSo() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-skillrun-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Skills", niche: "History")).folder
        let tools = base.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let answer = #"{"candidates":[{"name":"Fact Check","repo":"acme/skills","path":"research/fact-check","adds":"Checks claims","why":"History needs it"},{"name":"Ghost","repo":"acme/skills","path":"nowhere","adds":"x","why":"y"}]}"#
        let tool = try fakeClaude(outputs: [claudeResult(answer)], in: tools)
        let context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 makeRunner: { _, _ in EngineRunner(adapter: EngineRegistry.adapter(for: .claude), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                                 http: FakeGitHub())
        let node = Node(NodeRegistry.type("skills")!)
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context))
        let waiting = await driver.start(node)
        #expect(waiting.stage == .awaitingApproval, "\(waiting.error ?? "")")
        let review = try #require(SkillsRecipe.pending(in: waiting, folder: folder))
        #expect(review.candidates.count == 2)
        let good = review.candidates[0]
        #expect(good.name == "fact-check")
        #expect(good.hasScripts)
        #expect(good.files.map(\.path) == ["SKILL.md", "scripts/check.py"])
        #expect(good.preview?.contains("Check facts.") == true)
        #expect(review.candidates[1].problem != nil)
        var refused = false
        do { try await SkillsRecipe.decide("ghost", install: true, in: waiting, folder: folder, http: FakeGitHub()) } catch { refused = true }
        #expect(refused)

        try await SkillsRecipe.decide("fact-check", install: true, in: waiting, folder: folder, http: FakeGitHub())
        try await SkillsRecipe.decide("ghost", install: false, in: waiting, folder: folder, http: FakeGitHub())
        // Nothing is in the channel until the run is approved.
        #expect(!folder.exists(".agents/skills/fact-check/SKILL.md"))
        let done = await driver.resume(try RunStore(folder: folder).load(waiting.id), ownerApproved: true)
        #expect(done.stage == .finished, "\(done.error ?? "")")
        #expect(try folder.readText(".agents/skills/fact-check/SKILL.md").contains("Check facts."))
        #expect(try folder.readText(".claude/skills/fact-check/scripts/check.py") == "print('hi')")
        let saved = try folder.readJSON(SkillReview.self, SkillsRecipe.output)
        #expect(saved.candidates.map(\.decision) == [.install, .skip])
    }
}
