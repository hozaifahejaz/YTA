import ChannelStore
import Engines
import Foundation
import Support

/// Everything a node run needs from outside the workflow: settings and how to reach an engine.
public struct RunContext: Sendable {
    public var settings: AppSettings
    public var tools: ToolsFile?
    public var planDefaults: PlanDefaults
    public var automation: AutomationLevel
    /// Builds a runner for a tool. Tests replace it with a fake tool.
    public var makeRunner: @Sendable (EngineID, Bool) async throws -> EngineRunner
    /// Plain-language progress for the activity strip.
    public var onProgress: @Sendable (String) -> Void

    public init(
        settings: AppSettings,
        tools: ToolsFile?,
        planDefaults: PlanDefaults,
        automation: AutomationLevel,
        makeRunner: (@Sendable (EngineID, Bool) async throws -> EngineRunner)? = nil,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.tools = tools
        self.planDefaults = planDefaults
        self.automation = automation
        self.makeRunner = makeRunner ?? { id, allowKey in try await EngineRegistry.runner(for: id, tools: tools, allowAPIKey: allowKey) }
        self.onProgress = onProgress
    }
}

/// The draft a run produced, waiting for approval or already written.
public struct RunDraft: Codable, Sendable, Equatable {
    /// Relative path to content, for each file the run will write.
    public var files: [String: String]
    public var summary: String?
}

/// Runs one node through the stages of section 5.2 using an LLM tool.
/// Custom nodes are runnable now. Built-in nodes get their own executors in later milestones.
public struct NodeRunExecutor: StageExecutor {
    public let node: Node
    public let context: RunContext

    public init(node: Node, context: RunContext) {
        self.node = node
        self.context = context
    }

    public static func canRun(_ node: Node) -> Bool {
        node.isCustom && node.engine != nil && !node.outputs.isEmpty
    }

    /// The result format for a custom node: the file's full text and a one-line summary.
    public static let customSchema = JSONValue.parse(#"""
    {"type":"object","required":["content","summary"],"additionalProperties":false,
     "properties":{"content":{"type":"string","minLength":1},"summary":{"type":"string","maxLength":160}}}
    """#)!

    public func perform(_ stage: RunStage, run: RunRecord, folder: ChannelFolder) async throws -> StageOutcome {
        switch stage {
        case .preparing:
            try prepare(run, folder)
        case .executing:
            try await execute(run, folder)
        case .validating:
            try validate(run, folder)
        case .awaitingApproval:
            if needsApproval { return .waitForOwner }
        case .writing:
            try write(run, folder)
        case .finished, .failed, .cancelled:
            break
        }
        return .proceed
    }

    var needsApproval: Bool {
        switch node.approval {
        case .always: true
        case .never: false
        case .byDial: context.automation == .approveEvery
        }
    }

    // MARK: Stages

    private func prepare(_ run: RunRecord, _ folder: ChannelFolder) throws {
        guard Self.canRun(node) else {
            throw YTAError(.checkFailed, "\(node.title) is not runnable yet.", suggestion: "Built-in steps arrive in later milestones.")
        }
        var prompt = """
        You are working on one YouTube channel. Its folder is your working directory. AGENTS.md there describes the channel. Read it first.

        ## Task: \(node.title)

        \((node.promptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines))

        """
        if !node.inputs.isEmpty {
            prompt += "\n## Files to use\n\n"
            for input in node.inputs {
                if let text = try? folder.readText(input), !text.isEmpty {
                    prompt += "### \(input)\n\n\(text.prefix(40_000))\n\n"
                } else {
                    prompt += "### \(input)\n\n(This file does not exist yet.)\n\n"
                }
            }
        }
        prompt += """

        ## What to return

        Return JSON with two fields. `content` is the complete text of the file \(node.outputs[0]), ready to save. `summary` is one short line describing it. Do not create or change any file yourself.
        """
        try folder.writeText(prompt, to: "\(run.folder)/prompt.md")
        try folder.writeJSON(Array(folder.fileInventory()).sorted(), to: "\(run.folder)/inventory-before.json")
    }

    private func execute(_ run: RunRecord, _ folder: ChannelFolder) async throws {
        guard let engine = node.engine else { throw YTAError(.checkFailed, "\(node.title) has no engine.") }
        let engineSettings = context.settings.engine(engine.tool)
        guard engineSettings.enabled else {
            throw YTAError(.toolMissing, "\(engine.tool.displayName) is switched off in Settings.")
        }
        let planChoice = context.planDefaults.choice(engine: engine.tool, plan: engineSettings.plan, kind: .general)
        var prompt = try folder.readText("\(run.folder)/prompt.md")
        if let note = run.repairNote {
            prompt += "\n\nYour previous answer could not be used: \(note) Return exactly the JSON described above."
        }
        let request = RunRequest(
            runID: run.id,
            prompt: prompt,
            workingDirectory: folder.root,
            runFolder: run.folder,
            model: engine.model ?? engineSettings.modelOverride ?? planChoice.model,
            effort: engine.effort ?? planChoice.effort,
            schema: Self.customSchema,
            policy: .readOnly,
            maxBudgetUSD: 2,
            allowAPIKey: engineSettings.allowAPIKey
        )
        try folder.writeJSON(EngineCall(tool: engine.tool, model: request.model, effort: request.effort, date: Date()), to: "\(run.folder)/engine.json")
        let runner = try await context.makeRunner(engine.tool, engineSettings.allowAPIKey)
        context.onProgress("\(node.title): starting \(engine.tool.displayName)")
        let title = node.title
        let report = context.onProgress
        let outcome = try await runner.run(request) { report("\(title): \($0)") }
        try folder.writeJSON(StoredOutcome(text: outcome.text, structured: outcome.structured, usage: outcome.usage), to: "\(run.folder)/outcome.json")
    }

    private func validate(_ run: RunRecord, _ folder: ChannelFolder) throws {
        let stored = try folder.readJSON(StoredOutcome.self, "\(run.folder)/outcome.json")
        let outcome = EngineOutcome(text: stored.text, structured: stored.structured, usage: stored.usage)
        guard let value = try ResultCheck.structured(outcome, schema: Self.customSchema),
              let content = value["content"]?.stringValue else {
            throw YTAError(.schemaMismatch, "The result had no content.")
        }
        let draft = RunDraft(files: [node.outputs[0]: content], summary: value["summary"]?.stringValue)
        try folder.writeJSON(draft, to: "\(run.folder)/draft.json")

        // Flag anything the tool created outside its own run folder.
        let before = Set((try? folder.readJSON([String].self, "\(run.folder)/inventory-before.json")) ?? [])
        let unexpected = folder.fileInventory().subtracting(before).filter { !$0.hasPrefix("\(run.folder)/") }
        if !unexpected.isEmpty {
            var updated = run
            updated.unexpectedFiles = unexpected.sorted()
            try RunStore(folder: folder).save(updated)
            throw YTAError(.checkFailed, "The engine created files outside its run folder: \(unexpected.sorted().joined(separator: ", ")).")
        }
    }

    private func write(_ run: RunRecord, _ folder: ChannelFolder) throws {
        let draft = try folder.readJSON(RunDraft.self, "\(run.folder)/draft.json")
        for (path, content) in draft.files {
            try folder.writeText(content.hasSuffix("\n") ? content : content + "\n", to: path, source: node.title)
        }
        if draft.files.keys.contains(where: { $0.hasPrefix("profile/") }) {
            try folder.regenerateAgentsFile(source: node.title)
        }
    }
}

struct EngineCall: Codable {
    var tool: EngineID
    var model: String?
    var effort: Effort?
    var date: Date
}

struct StoredOutcome: Codable {
    var text: String
    var structured: JSONValue?
    var usage: RunUsage?
}

extension RunStore {
    /// The draft a run is waiting on, if it got that far.
    public func draft(for run: RunRecord) -> RunDraft? {
        try? folder.readJSON(RunDraft.self, "\(run.folder)/draft.json")
    }

    /// The latest run of a node.
    public func latest(for nodeID: String) -> RunRecord? {
        all().last { $0.nodeID == nodeID }
    }
}
