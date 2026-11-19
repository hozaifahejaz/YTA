import ChannelStore
import Engines
import Foundation
import Support
import YouTubeData

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
    /// YouTube data for steps that check names or read channels. Nil in tests that don't need it.
    public var youtube: YouTubeService?
    /// Plain HTTP for domain and social hints.
    public var http: HTTPClient

    public init(
        settings: AppSettings,
        tools: ToolsFile?,
        planDefaults: PlanDefaults,
        automation: AutomationLevel,
        makeRunner: (@Sendable (EngineID, Bool) async throws -> EngineRunner)? = nil,
        onProgress: @escaping @Sendable (String) -> Void = { _ in },
        youtube: YouTubeService? = nil,
        http: HTTPClient = URLSessionHTTP()
    ) {
        self.settings = settings
        self.tools = tools
        self.planDefaults = planDefaults
        self.automation = automation
        self.makeRunner = makeRunner ?? { id, allowKey in try await EngineRegistry.runner(for: id, tools: tools, allowAPIKey: allowKey) }
        self.onProgress = onProgress
        self.youtube = youtube
        self.http = http
    }
}

/// The draft a run produced, waiting for approval or already written.
public struct RunDraft: Codable, Sendable, Equatable {
    /// Relative path to content, for each text file the run will write.
    public var files: [String: String]
    public var summary: String?
    /// Binary files the run made in its own folder: channel path to the file inside the run folder.
    public var copies: [String: String]?

    public init(files: [String: String], summary: String? = nil, copies: [String: String]? = nil) {
        self.files = files
        self.summary = summary
        self.copies = copies
    }
}

/// Runs one node through the stages of section 5.2. The node's recipe supplies the
/// prompt, the result format and any work the app does with the result.
public struct NodeRunExecutor: StageExecutor {
    public let node: Node
    public let context: RunContext
    /// The owner's note for this run, for example "shorter names" on a second round.
    public let note: String?

    public init(node: Node, context: RunContext, note: String? = nil) {
        self.node = node
        self.context = context
        self.note = note
    }

    public static func canRun(_ node: Node) -> Bool {
        guard let recipe = NodeRecipes.recipe(for: node) else { return false }
        return !recipe.usesEngine || node.engine != nil
    }

    /// The result format for a custom node: the file's full text and a one-line summary.
    public static let customSchema = CustomRecipe.schema

    var recipe: NodeRecipe {
        get throws {
            guard let recipe = NodeRecipes.recipe(for: node) else {
                throw YTAError(.checkFailed, "\(node.title) is not runnable yet.", suggestion: "This step arrives in a later milestone.")
            }
            return recipe
        }
    }

    public func perform(_ stage: RunStage, run: RunRecord, folder: ChannelFolder) async throws -> StageOutcome {
        switch stage {
        case .preparing:
            try prepare(run, folder)
        case .executing:
            try await execute(run, folder)
        case .validating:
            try await validate(run, folder)
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
            throw YTAError(.checkFailed, "\(node.title) is not runnable yet.", suggestion: "This step arrives in a later milestone.")
        }
        let recipe = try recipe
        if recipe.usesEngine {
            var prompt = """
            You are working on one YouTube channel. Its folder is your working directory. AGENTS.md there describes the channel. Read it first.

            ## Task: \(node.title)

            \(try recipe.task(node: node, folder: folder).trimmingCharacters(in: .whitespacesAndNewlines))

            """
            if let note, !note.isEmpty {
                prompt += "\n## The owner's note for this run\n\n\(note)\n"
            }
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
            prompt += "\n## What to return\n\n\(recipe.returnInstructions(node: node))\n\nDo not create or change any file yourself."
            try folder.writeText(prompt, to: "\(run.folder)/prompt.md")
        } else if let note, !note.isEmpty {
            try folder.writeText(note, to: "\(run.folder)/note.md")
        }
        try folder.writeJSON(Array(folder.fileInventory()).sorted(), to: "\(run.folder)/inventory-before.json")
    }

    private func execute(_ run: RunRecord, _ folder: ChannelFolder) async throws {
        let recipe = try recipe
        guard recipe.usesEngine else { return }
        guard let engine = node.engine else { throw YTAError(.checkFailed, "\(node.title) has no engine.") }
        let engineSettings = context.settings.engine(engine.tool)
        guard engineSettings.enabled else {
            throw YTAError(.toolMissing, "\(engine.tool.displayName) is switched off in Settings.")
        }
        let planChoice = context.planDefaults.choice(engine: engine.tool, plan: engineSettings.plan, kind: recipe.kind)
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
            schema: recipe.schema,
            policy: recipe.policy,
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

    private func validate(_ run: RunRecord, _ folder: ChannelFolder) async throws {
        let recipe = try recipe
        var value = JSONValue.null
        if recipe.usesEngine {
            let stored = try folder.readJSON(StoredOutcome.self, "\(run.folder)/outcome.json")
            let outcome = EngineOutcome(text: stored.text, structured: stored.structured, usage: stored.usage)
            guard let checked = try ResultCheck.structured(outcome, schema: recipe.schema) else {
                throw YTAError(.schemaMismatch, "The result was empty.")
            }
            value = checked
        }
        let note = (try? folder.readText("\(run.folder)/note.md")) ?? self.note
        let draft = try await recipe.draft(from: value, run: run, node: node, folder: folder, context: context, note: note)
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
        for (path, source) in draft.copies ?? [:] {
            try folder.write(try folder.read(source), to: path, source: node.title)
        }
        if draft.files.keys.contains(where: { $0.hasPrefix("profile/") }) {
            try folder.regenerateAgentsFile(source: node.title)
        }
        try (try? recipe)?.afterWrite(draft: draft, node: node, folder: folder)
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
