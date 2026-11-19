import Foundation
import Support

/// OpenCode, headless: `opencode run --format json` (section 5.3).
///
/// Checked against OpenCode 2.2.5: there is no schema flag, so YTA checks the result
/// itself. The read-only `plan` agent is used and `--auto` is never passed, so nothing
/// is approved without the owner. [VERIFY] the JSON event shapes against a real run.
public struct OpenCodeAdapter: EngineAdapter {
    public init() {}

    public var id: EngineID { .opencode }

    public var capabilities: EngineCapabilities {
        EngineCapabilities(schemaOutput: false, effort: false, webSearch: true, skillsFolder: ".agents/skills")
    }

    public func arguments(for request: RunRequest) throws -> [String] {
        var args = ["run", "--format", "json", "--agent", "plan", "--title", "YTA \(request.runID)"]
        if let model = request.model, !model.isEmpty { args += ["-m", model] }
        var prompt = request.prompt
        if let schema = request.schema {
            prompt += "\n\nReturn only a JSON value that matches this JSON Schema, with no other text:\n\(schema.compactString)\n"
        }
        args.append(prompt)
        return args
    }

    public func standardInput(for request: RunRequest) -> String? { nil }

    public func makeParser(for request: RunRequest) -> any EventParser {
        OpenCodeParser()
    }
}

final class OpenCodeParser: EventParser {
    private var text = ""
    private var failed = false
    private var usage: RunUsage?

    func parse(line: String) -> [RunEvent] {
        guard let event = JSONValue.parse(line) else { return [] }
        let type = event["type"]?.stringValue ?? ""
        let part = event["part"] ?? event
        switch type {
        case "text":
            if let chunk = part["text"]?.stringValue { text += chunk }
            return []
        case "tool_use", "tool":
            let name = part["tool"]?.stringValue ?? part["name"]?.stringValue ?? "a tool"
            return [.progress(ProgressText.forTool(name, detail: nil))]
        case "step_finish":
            usage = RunUsage(
                inputTokens: part["tokens"]?["input"]?.intValue,
                outputTokens: part["tokens"]?["output"]?.intValue,
                costUSD: { if case .number(let n)? = part["cost"] { return n } else { return nil } }()
            )
            return []
        case "error":
            failed = true
            let message = event["error"]?["data"]?["message"]?.stringValue ?? event["error"]?["message"]?.stringValue ?? event["message"]?.stringValue ?? "unknown error"
            return [.failure(ToolMessages.classify(message) ?? YTAError(.checkFailed, "OpenCode stopped: \(message.prefix(300))"))]
        default:
            return []
        }
    }

    func finish(status: Int32, stderr: String) -> [RunEvent] {
        guard !failed else { return [] }
        if status == 0, !text.isEmpty {
            return [.result(text: text, structured: nil, usage: usage)]
        }
        if let typed = ToolMessages.classify(stderr) { return [.failure(typed)] }
        return [.failure(YTAError(.checkFailed, "OpenCode ended without a result (exit \(status)). \(stderr.suffix(300))"))]
    }
}
