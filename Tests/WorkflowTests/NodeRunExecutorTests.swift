import ChannelStore
import Engines
import Foundation
import Support
import Testing
@testable import Workflow

/// A fake LLM tool: prints the n-th fixture on its n-th call (the last one repeats).
func fakeClaude(outputs: [String], extraCommand: String = "", in folder: URL) throws -> URL {
    var cases = ""
    for (index, output) in outputs.enumerated() {
        let file = folder.appendingPathComponent("out\(index + 1).jsonl")
        try output.write(to: file, atomically: true, encoding: .utf8)
        cases += "\(index + 1)) cat \"\(file.path)\" ;;\n"
    }
    let counter = folder.appendingPathComponent("count")
    let script = folder.appendingPathComponent("claude")
    try """
    #!/bin/sh
    cat > /dev/null
    n=$(cat "\(counter.path)" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "\(counter.path)"
    \(extraCommand)
    case $n in
    \(cases)*) cat "\(folder.appendingPathComponent("out\(outputs.count).jsonl").path)" ;;
    esac
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

func claudeResult(_ structured: String) -> String {
    #"{"type":"result","subtype":"success","is_error":false,"result":"ok","structured_output":"# + structured + "}"
}

@Suite struct NodeRunExecutorTests {
    func setup(automation: AutomationLevel = .approveEvery) throws -> (ChannelFolder, Node, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-exec-\(UUID().uuidString)")
        let record = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Exec", niche: "Shipwrecks"))
        let node = Node(
            type: NodeType.custom.id, title: "Tagline", engine: EngineChoice(tool: .claude),
            promptTemplate: "Write a tagline.", inputs: ["profile/niche.md"], outputs: ["profile/tagline.md"], approval: .always
        )
        let tools = base.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        return (record.folder, node, tools)
    }

    func context(_ tool: URL, automation: AutomationLevel = .approveEvery) -> RunContext {
        RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: automation,
                   makeRunner: { id, _ in EngineRunner(adapter: EngineRegistry.adapter(for: id), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) })
    }

    @Test func customNodeRunsWaitsForApprovalThenWrites() async throws {
        let (folder, node, tools) = try setup()
        let tool = try fakeClaude(outputs: [claudeResult(#"{"content":"Every wreck has a story.","summary":"One-line tagline"}"#)], in: tools)
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context(tool)))
        let waiting = await driver.start(node)
        #expect(waiting.stage == .awaitingApproval)
        #expect(!folder.exists("profile/tagline.md"))
        #expect(RunStore(folder: folder).draft(for: waiting)?.files["profile/tagline.md"] == "Every wreck has a story.")
        #expect(try folder.readText("\(waiting.folder)/prompt.md").contains("Shipwrecks"))

        let done = await driver.resume(waiting, ownerApproved: true)
        #expect(done.stage == .finished)
        #expect(try folder.readText("profile/tagline.md") == "Every wreck has a story.\n")
        #expect(folder.history(for: "profile/tagline.md").first?.source == "Tagline")
    }

    @Test func straightThroughDialSkipsApprovalForDialNodes() async throws {
        var (folder, node, tools) = try setup()
        node.approval = .byDial
        let tool = try fakeClaude(outputs: [claudeResult(#"{"content":"x","summary":"y"}"#)], in: tools)
        let done = await RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context(tool, automation: .straightThrough))).start(node)
        #expect(done.stage == .finished)
    }

    @Test func malformedResultIsRepairedOnce() async throws {
        let (folder, node, tools) = try setup()
        let tool = try fakeClaude(outputs: [
            claudeResult(#"{"text":"wrong field"}"#),
            claudeResult(#"{"content":"Fixed","summary":"ok"}"#),
        ], in: tools)
        let result = await RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context(tool))).start(node)
        #expect(result.stage == .awaitingApproval)
        #expect(try String(contentsOf: tools.appendingPathComponent("count"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        #expect(try folder.readText("\(result.folder)/prompt.md").isEmpty == false)
    }

    @Test func fileCreatedOutsideTheRunFolderFailsTheRun() async throws {
        let (folder, node, tools) = try setup()
        let tool = try fakeClaude(
            outputs: [claudeResult(#"{"content":"x","summary":"y"}"#)],
            extraCommand: "echo sneaky > \"\(folder.root.path)/profile/sneaky.md\"",
            in: tools
        )
        let result = await RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context(tool))).start(node)
        #expect(result.stage == .failed)
        #expect(try RunStore(folder: folder).load(result.id).unexpectedFiles == ["profile/sneaky.md"])
    }

    @Test func builtInNodesAreNotRunnableYet() async throws {
        let (folder, _, tools) = try setup()
        let node = Node(NodeRegistry.type("name")!)
        let tool = try fakeClaude(outputs: [claudeResult(#"{"content":"x","summary":"y"}"#)], in: tools)
        let result = await RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context(tool))).start(node)
        #expect(result.stage == .failed)
    }
}
