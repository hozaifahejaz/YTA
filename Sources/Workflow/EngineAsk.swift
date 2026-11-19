import ChannelStore
import Engines
import Foundation
import Support

/// One extra engine call inside a recipe, for steps with several LLM stages (niche research's
/// score and challenge). Each call keeps its prompt and answer in the run folder, so a resumed
/// run reuses an answer it already has.
public struct EngineAsk: Sendable {
    public var tool: EngineID
    public var model: String?
    public var effort: Effort?
    public var kind: StepKind
    public var policy: ToolPolicy = .readOnly

    public init(tool: EngineID, model: String? = nil, effort: Effort? = nil, kind: StepKind, policy: ToolPolicy = .readOnly) {
        self.tool = tool
        self.model = model
        self.effort = effort
        self.kind = kind
        self.policy = policy
    }

    /// Asks once, and once more with the problem if the answer is malformed or fails `check`.
    public func run(label: String, title: String, prompt: String, schema: JSONValue, run: RunRecord, folder: ChannelFolder,
                    context: RunContext, check: (JSONValue) -> String? = { _ in nil }) async throws -> JSONValue {
        let answerPath = "\(run.folder)/\(label)-answer.json"
        if let saved = try? folder.readJSON(JSONValue.self, answerPath) { return saved }

        let settings = context.settings.engine(tool)
        guard settings.enabled else { throw YTAError(.toolMissing, "\(tool.displayName) is switched off in Settings.") }
        let plan = context.planDefaults.choice(engine: tool, plan: settings.plan, kind: kind)
        let runner = try await context.makeRunner(tool, settings.allowAPIKey)
        var text = prompt
        var lastProblem = ""
        for attempt in 1...2 {
            if attempt == 2 {
                text = prompt + "\n\nYour previous answer could not be used: \(lastProblem) Return exactly the JSON described above."
            }
            try folder.writeText(text, to: "\(run.folder)/\(label)-prompt.md")
            let request = RunRequest(runID: run.id, prompt: text, workingDirectory: folder.root, runFolder: run.folder,
                                     model: model ?? settings.modelOverride ?? plan.model, effort: effort ?? plan.effort,
                                     schema: schema, policy: policy, maxBudgetUSD: 2, allowAPIKey: settings.allowAPIKey)
            context.onProgress("\(title): asking \(tool.displayName)")
            let report = context.onProgress
            let before = folder.fileInventory()
            let outcome = try await runner.run(request) { report("\(title): \($0)") }
            UsageLog.append(outcome.usage, run: run, folder: folder)
            let unexpected = UnexpectedFiles.since(before, folder: folder)
            if !unexpected.isEmpty { throw UnexpectedFiles.error(unexpected) }
            do {
                guard let value = try ResultCheck.structured(outcome, schema: schema) else {
                    throw YTAError(.schemaMismatch, "The result was empty.")
                }
                if let problem = check(value) { throw YTAError(.schemaMismatch, problem) }
                try folder.writeJSON(value, to: answerPath)
                return value
            } catch let error as YTAError where error.kind == .schemaMismatch {
                lastProblem = error.message
                if attempt == 2 { throw error }
            }
        }
        throw YTAError(.schemaMismatch, lastProblem)
    }
}
