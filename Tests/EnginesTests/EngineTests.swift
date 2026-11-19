import Foundation
import Testing
@testable import Engines
import Support

func scratchFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yta-eng-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a fake tool: a shell script that swallows stdin, records its arguments and prints `output`.
func fakeTool(printing output: String, exit status: Int32 = 0, sleep seconds: Int = 0, in folder: URL) throws -> URL {
    let fixture = folder.appendingPathComponent("fixture.jsonl")
    try output.write(to: fixture, atomically: true, encoding: .utf8)
    let script = folder.appendingPathComponent("fake-tool")
    let body = """
    #!/bin/sh
    cat > "\(folder.path)/stdin.txt"
    printf '%s\\n' "$@" > "\(folder.path)/args.txt"
    env > "\(folder.path)/env.txt"
    sleep \(seconds)
    cat "\(fixture.path)"
    exit \(status)
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

let nameSchema = JSONValue.parse(#"{"type":"object","required":["names"],"properties":{"names":{"type":"array","minItems":2,"items":{"type":"string"}}}}"#)!

func request(in folder: URL, policy: ToolPolicy = .readOnly, schema: JSONValue? = nameSchema) -> RunRequest {
    RunRequest(runID: "run_1", prompt: "Write names", workingDirectory: folder, runFolder: "runs/run_1",
               model: "sonnet", effort: .high, schema: schema, policy: policy, timeout: 20)
}

@Suite struct ClaudeAdapterTests {
    @Test func setsEveryIsolationFlag() throws {
        let args = try ClaudeAdapter().arguments(for: request(in: scratchFolder()))
        for flag in ["-p", "--restricted", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] {
            #expect(args.contains(flag), "\(flag)")
        }
        #expect(!args.contains("--bare"))
        #expect(args.contains("dontAsk"))
        #expect(args[args.firstIndex(of: "--permission-prompts")! + 1] == "none")
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "Read,Glob,Grep")
        #expect(args[args.firstIndex(of: "--model")! + 1] == "sonnet")
        #expect(args[args.firstIndex(of: "--effort")! + 1] == "high")
        #expect(args.contains("--json-schema"))
        #expect(!args.contains("--max-budget-usd"))
    }

    @Test func webOnlyForResearchAndWritesOnlyToScratch() throws {
        var req = request(in: scratchFolder(), policy: ToolPolicy(web: true, writeScratch: true))
        let args = try ClaudeAdapter().arguments(for: req)
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
        #expect(allowed.contains("WebSearch"))
        #expect(allowed.contains("Write(./runs/run_1/scratch/**)"))
        #expect(!allowed.contains("Bash"))
        req.policy = .readOnly
        #expect(!(try ClaudeAdapter().arguments(for: req)).joined(separator: " ").contains("Web"))
    }

    @Test func parsesAStreamIntoProgressAndStructuredResult() {
        let parser = ClaudeParser()
        var events: [RunEvent] = []
        for line in [
            #"{"type":"system","subtype":"init","model":"claude-sonnet"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"maritime mysteries channels"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Done","structured_output":{"names":["Abyss","Driftline"]},"total_cost_usd":0.02,"usage":{"input_tokens":100,"output_tokens":20}}"#,
        ] { events += parser.parse(line: line) }
        #expect(events.first == .progress("Claude Code started (claude-sonnet)"))
        #expect(events.contains(.progress("Searching the web: maritime mysteries channels")))
        guard case .result(_, let structured, let usage)? = events.last else { Issue.record("no result"); return }
        #expect(structured?["names"] == .array([.string("Abyss"), .string("Driftline")]))
        #expect(usage?.outputTokens == 20)
    }

    @Test func usageLimitBecomesATypedError() {
        let events = ClaudeParser().parse(line: #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1763575200"}"#)
        guard case .failure(let error)? = events.first else { Issue.record("no failure"); return }
        #expect(error.kind == .usageLimit)
        #expect(error.resetsAt == nil || error.resetsAt! > Date(timeIntervalSince1970: 0))
    }
}

@Suite struct CodexAdapterTests {
    @Test func argumentsAndSchemaFile() throws {
        let folder = scratchFolder()
        let args = try CodexAdapter().arguments(for: request(in: folder))
        #expect(args.first == "exec")
        #expect(args.contains("--json"))
        #expect(args[args.firstIndex(of: "-s")! + 1] == "read-only")
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("model_reasoning_effort=\"high\""))
        #expect(args.last == "-")
        let schemaPath = args[args.firstIndex(of: "--output-schema")! + 1]
        #expect(FileManager.default.fileExists(atPath: schemaPath))
        #expect(!args.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test func maxEffortMapsToXHigh() {
        #expect(CodexAdapter.effort(.max) == "xhigh")
    }

    @Test func parsesFinalMessage() {
        let parser = CodexParser(lastMessageFile: scratchFolder().appendingPathComponent("none.txt"))
        var events: [RunEvent] = []
        for line in [
            #"{"type":"thread.started","thread_id":"t1"}"#,
            #"{"type":"item.started","item":{"id":"i1","type":"web_search","query":"tide"}}"#,
            #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"{\"names\":[\"A\",\"B\"]}"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}"#,
        ] { events += parser.parse(line: line) }
        events += parser.finish(status: 0, stderr: "")
        #expect(events.contains(.progress("Searching the web: tide")))
        guard case .result(let text, _, let usage)? = events.last else { Issue.record("no result"); return }
        #expect(text == #"{"names":["A","B"]}"#)
        #expect(usage?.inputTokens == 10)
    }

    @Test func failedTurnIsReported() {
        let events = CodexParser(lastMessageFile: scratchFolder()).parse(line: #"{"type":"turn.failed","error":{"message":"You've hit your usage limit. Try again later."}}"#)
        guard case .failure(let error)? = events.first else { Issue.record("no failure"); return }
        #expect(error.kind == .usageLimit)
    }
}

@Suite struct OpenCodeAdapterTests {
    @Test func usesReadOnlyAgentAndPutsSchemaInPrompt() throws {
        let args = try OpenCodeAdapter().arguments(for: request(in: scratchFolder()))
        #expect(args.prefix(3) == ["run", "--format", "json"])
        #expect(args[args.firstIndex(of: "--agent")! + 1] == "plan")
        #expect(!args.contains("--auto"))
        #expect(args.last!.contains("JSON Schema"))
    }

    @Test func collectsTextParts() {
        let parser = OpenCodeParser()
        _ = parser.parse(line: #"{"type":"text","part":{"text":"{\"names\":"}}"#)
        _ = parser.parse(line: #"{"type":"text","part":{"text":"[\"A\",\"B\"]}"}}"#)
        guard case .result(let text, _, _)? = parser.finish(status: 0, stderr: "").first else { Issue.record("no result"); return }
        #expect(JSONValue.parse(text)?["names"] == .array([.string("A"), .string("B")]))
    }
}

@Suite struct EnvironmentTests {
    @Test func dropsEveryKeyByDefault() {
        let source = ["HOME": "/Users/h", "PATH": "/bin", "ANTHROPIC_API_KEY": "sk-1", "OPENAI_API_KEY": "sk-2", "YTA_AI33": "x", "GITHUB_TOKEN": "t"]
        let env = CleanEnvironment.make(for: .claude, from: source, path: "/opt/bin:/bin")
        #expect(env["HOME"] == "/Users/h")
        #expect(env["PATH"] == "/opt/bin:/bin")
        #expect(env.keys.allSatisfy { !CleanEnvironment.looksSecret($0) })
        #expect(env["YTA_AI33"] == nil)
    }

    @Test func passesOnlyThatToolsKeyWhenAllowed() {
        let source = ["ANTHROPIC_API_KEY": "sk-1", "OPENAI_API_KEY": "sk-2"]
        let env = CleanEnvironment.make(for: .claude, from: source, allowAPIKey: true)
        #expect(env["ANTHROPIC_API_KEY"] == "sk-1")
        #expect(env["OPENAI_API_KEY"] == nil)
    }
}

@Suite struct EngineRunnerTests {
    let claudeStream = """
    {"type":"system","subtype":"init","model":"claude-sonnet"}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"profile/niche.md"}}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"ok","structured_output":{"names":["Abyss","Driftline"]}}
    """

    @Test func runsAFakeToolEndToEnd() async throws {
        let folder = scratchFolder()
        let tool = try fakeTool(printing: claudeStream, in: folder)
        let redactor = Redactor()
        redactor.register("secret-key-123456")
        var runner = EngineRunner(adapter: ClaudeAdapter(), executable: tool, environment: ["PATH": "/usr/bin:/bin"])
        runner.redactor = redactor
        let progress = ProgressBox()
        let outcome = try await runner.run(request(in: folder)) { progress.add($0) }
        let structured = try ResultCheck.structured(outcome, schema: nameSchema)
        #expect(structured?["names"] == .array([.string("Abyss"), .string("Driftline")]))
        #expect(progress.lines.contains("Reading profile/niche.md"))
        #expect(try String(contentsOf: folder.appendingPathComponent("stdin.txt"), encoding: .utf8) == "Write names")
        let log = try String(contentsOf: folder.appendingPathComponent("runs/run_1/events.jsonl"), encoding: .utf8)
        #expect(log.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 3)
        let env = try String(contentsOf: folder.appendingPathComponent("env.txt"), encoding: .utf8)
        #expect(!env.contains("API_KEY"))
    }

    @Test func malformedResultIsASchemaMismatch() async throws {
        let folder = scratchFolder()
        let stream = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"names\":[\"OnlyOne\"]}"}"#
        let tool = try fakeTool(printing: stream, in: folder)
        let outcome = try await EngineRunner(adapter: ClaudeAdapter(), executable: tool, environment: [:]).run(request(in: folder))
        #expect(throws: YTAError.self) { try ResultCheck.structured(outcome, schema: nameSchema) }
        do {
            _ = try ResultCheck.structured(outcome, schema: nameSchema)
        } catch let error as YTAError {
            #expect(error.kind == .schemaMismatch)
        }
    }

    @Test func toolWithoutResultFails() async throws {
        let folder = scratchFolder()
        let tool = try fakeTool(printing: "not json", exit: 1, in: folder)
        await #expect(throws: YTAError.self) {
            _ = try await EngineRunner(adapter: ClaudeAdapter(), executable: tool, environment: [:]).run(request(in: folder))
        }
    }

    @Test func toolThatIgnoresItsPromptDoesNotCrashTheApp() async throws {
        let folder = scratchFolder()
        let script = folder.appendingPathComponent("quits-early")
        try "#!/bin/sh\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var big = request(in: folder)
        big.prompt = String(repeating: "x", count: 1_000_000)
        await #expect(throws: YTAError.self) {
            _ = try await EngineRunner(adapter: ClaudeAdapter(), executable: script, environment: [:]).run(big)
        }
    }

    @Test func cancellingStopsTheTool() async throws {
        let folder = scratchFolder()
        let tool = try fakeTool(printing: claudeStream, sleep: 30, in: folder)
        let runner = EngineRunner(adapter: ClaudeAdapter(), executable: tool, environment: ["PATH": "/usr/bin:/bin"])
        let started = Date()
        let task = Task { try await runner.run(request(in: folder)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite struct SchemaCheckTests {
    @Test func reportsMissingAndWrongTypes() {
        let schema = JSONValue.parse(#"{"type":"object","required":["a","b"],"additionalProperties":false,"properties":{"a":{"type":"string","maxLength":3},"b":{"type":"integer","minimum":1}}}"#)!
        #expect(JSONSchemaCheck.problems(in: .parse(#"{"a":"abc","b":2}"#)!, against: schema).isEmpty)
        #expect(JSONSchemaCheck.problems(in: .parse(#"{"a":"abcd","b":0,"c":1}"#)!, against: schema).count == 3)
        #expect(JSONSchemaCheck.problems(in: .parse(#"{"a":"x"}"#)!, against: schema) == ["$.b is missing"])
    }

    @Test func extractsJSONFromProse() {
        let text = "Here you go:\n```json\n{\"names\":[\"A\"]}\n```\nThanks"
        #expect(JSONSchemaCheck.extractJSON(from: text)?["names"] == .array([.string("A")]))
        #expect(JSONSchemaCheck.extractJSON(from: "Result: {\"x\":1} done")?["x"] == .number(1))
    }
}
