import Foundation
import Support

/// Codex, headless: `codex exec --json` (section 5.3).
///
/// Flags checked against codex-cli 0.170.0 on the owner's Mac. The sandbox is read-only;
/// the final message is the result. User config and rules are not loaded, so only the
/// channel's AGENTS.md applies. Auth still comes from the owner's Codex login.
public struct CodexAdapter: EngineAdapter {
    public init() {}

    public var id: EngineID { .codex }

    public var capabilities: EngineCapabilities {
        EngineCapabilities(schemaOutput: true, effort: true, webSearch: true, skillsFolder: ".agents/skills")
    }

    public func arguments(for request: RunRequest) throws -> [String] {
        let root = request.workingDirectory
        var args = [
            "exec",
            "--json",
            "--color", "never",
            "-C", root.path,
            "-s", "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "-o", root.appendingPathComponent("\(request.runFolder)/last-message.txt").path,
        ]
        if let model = request.model, !model.isEmpty { args += ["-m", model] }
        if let effort = request.effort { args += ["-c", "model_reasoning_effort=\"\(Self.effort(effort))\""] }
        if request.policy.web {
            // [VERIFY] exec has no --search flag; the config key enables the web search tool.
            args += ["-c", "tools.web_search=true"]
        }
        if let schema = request.schema {
            let url = root.appendingPathComponent("\(request.runFolder)/schema.json")
            try AtomicFile.write(Data(schema.compactString.utf8), to: url)
            args += ["--output-schema", url.path]
        }
        args.append("-")
        return args
    }

    static func effort(_ effort: Effort) -> String {
        switch effort {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh, .max: "xhigh"
        }
    }

    public func makeParser(for request: RunRequest) -> any EventParser {
        CodexParser(lastMessageFile: request.workingDirectory.appendingPathComponent("\(request.runFolder)/last-message.txt"))
    }
}

final class CodexParser: EventParser {
    private let lastMessageFile: URL
    private var lastMessage: String?
    private var usage: RunUsage?
    private var done = false

    init(lastMessageFile: URL) {
        self.lastMessageFile = lastMessageFile
    }

    func parse(line: String) -> [RunEvent] {
        guard let event = JSONValue.parse(line), let type = event["type"]?.stringValue else { return [] }
        switch type {
        case "thread.started":
            return [.progress("Codex started")]
        case "item.started", "item.completed":
            guard let item = event["item"], let kind = item["type"]?.stringValue else { return [] }
            switch kind {
            case "agent_message":
                if type == "item.completed", let text = item["text"]?.stringValue { lastMessage = text }
                return []
            case "web_search":
                return type == "item.started" ? [.progress(ProgressText.forTool("web_search", detail: item["query"]?.stringValue))] : []
            case "command_execution":
                return type == "item.started" ? [.progress("Looking through the channel folder")] : []
            case "reasoning":
                return type == "item.started" ? [.progress("Thinking")] : []
            default:
                return []
            }
        case "turn.completed":
            usage = RunUsage(
                inputTokens: event["usage"]?["input_tokens"]?.intValue,
                outputTokens: event["usage"]?["output_tokens"]?.intValue
            )
            return []
        case "turn.failed", "error":
            done = true
            let message = event["error"]?["message"]?.stringValue ?? event["message"]?.stringValue ?? "unknown error"
            return [.failure(ToolMessages.classify(message) ?? YTAError(.checkFailed, "Codex stopped: \(message.prefix(300))"))]
        default:
            return []
        }
    }

    func finish(status: Int32, stderr: String) -> [RunEvent] {
        guard !done else { return [] }
        let text = lastMessage ?? (try? String(contentsOf: lastMessageFile, encoding: .utf8))
        if let text, !text.isEmpty, status == 0 {
            return [.result(text: text, structured: nil, usage: usage)]
        }
        if let typed = ToolMessages.classify(stderr) { return [.failure(typed)] }
        return [.failure(YTAError(.checkFailed, "Codex ended without a result (exit \(status)). \(stderr.suffix(300))"))]
    }
}
