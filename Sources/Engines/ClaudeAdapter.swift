import Foundation
import Support

/// Claude Code, headless: `claude -p --output-format stream-json` (section 5.3).
///
/// Flags checked against Claude Code 2.1.328 on the owner's Mac. Every behaviour flag is
/// set explicitly. `--bare` is never used, because it ignores the subscription login.
public struct ClaudeAdapter: EngineAdapter {
    public init() {}

    public var id: EngineID { .claude }

    public var capabilities: EngineCapabilities {
        EngineCapabilities(schemaOutput: true, effort: true, webSearch: true, skillsFolder: ".claude/skills")
    }

    public func arguments(for request: RunRequest) throws -> [String] {
        var tools = ["Read", "Glob", "Grep"]
        var allowed = ["Read(./**)", "Glob", "Grep"]
        if request.policy.web {
            tools += ["WebSearch", "WebFetch"]
            allowed += ["WebSearch", "WebFetch"]
        }
        if request.policy.writeScratch {
            tools += ["Write", "Edit"]
            allowed += ["Write(./\(request.scratchFolder)/**)", "Edit(./\(request.scratchFolder)/**)"]
        }
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            // Confines file tools to the working directory and ignores user, project and local settings.
            "--restricted",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            "--tools", tools.joined(separator: ","),
            "--allowedTools", allowed.joined(separator: " "),
        ]
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort { args += ["--effort", effort.rawValue] }
        if let schema = request.schema { args += ["--json-schema", schema.compactString] }
        if request.allowAPIKey, let budget = request.maxBudgetUSD {
            args += ["--max-budget-usd", String(format: "%.2f", budget)]
        }
        return args
    }

    public func makeParser(for request: RunRequest) -> any EventParser {
        ClaudeParser()
    }
}

final class ClaudeParser: EventParser {
    private var gotResult = false
    private var lastText = ""

    func parse(line: String) -> [RunEvent] {
        guard let event = JSONValue.parse(line), let type = event["type"]?.stringValue else { return [] }
        switch type {
        case "system":
            if event["subtype"]?.stringValue == "init" {
                let model = event["model"]?.stringValue.map { " (\($0))" } ?? ""
                return [.progress("Claude Code started\(model)")]
            }
            return []
        case "assistant":
            guard case .array(let content)? = event["message"]?["content"] else { return [] }
            var events: [RunEvent] = []
            for part in content {
                switch part["type"]?.stringValue {
                case "tool_use":
                    let name = part["name"]?.stringValue ?? "a tool"
                    let input = part["input"]
                    let detail = input?["query"]?.stringValue ?? input?["url"]?.stringValue ?? input?["file_path"]?.stringValue ?? input?["pattern"]?.stringValue
                    events.append(.progress(ProgressText.forTool(name, detail: detail)))
                case "text":
                    if let text = part["text"]?.stringValue { lastText = text }
                default:
                    break
                }
            }
            return events
        case "result":
            gotResult = true
            let text = event["result"]?.stringValue ?? lastText
            let usage = RunUsage(
                inputTokens: event["usage"]?["input_tokens"]?.intValue,
                outputTokens: event["usage"]?["output_tokens"]?.intValue,
                costUSD: { if case .number(let n)? = event["total_cost_usd"] { return n } else { return nil } }()
            )
            let isError = event["is_error"] == .bool(true) || (event["subtype"]?.stringValue ?? "success") != "success"
            if isError {
                let message = text.isEmpty ? (event["subtype"]?.stringValue ?? "error") : text
                return [.failure(ToolMessages.classify(message) ?? YTAError(.checkFailed, "Claude Code stopped: \(message.prefix(300))"))]
            }
            let structured = event["structured_output"].flatMap { $0 == .null ? nil : $0 }
            return [.result(text: text, structured: structured, usage: usage)]
        default:
            return []
        }
    }

    func finish(status: Int32, stderr: String) -> [RunEvent] {
        guard !gotResult else { return [] }
        if let typed = ToolMessages.classify(stderr) { return [.failure(typed)] }
        return [.failure(YTAError(.checkFailed, "Claude Code ended without a result (exit \(status)). \(stderr.suffix(300))"))]
    }
}
