import Foundation
import Support

/// A node's state (section 5.1). Only `needsYou` uses the accent colour.
public enum NodeState: String, Codable, Sendable, CaseIterable {
    case waiting
    case running
    case needsYou
    case done
    case failed
    case stale

    public var title: String {
        switch self {
        case .waiting: "Waiting"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .stale: "Out of date"
        }
    }
}

/// Which tool, model and effort a node runs on.
public struct EngineChoice: Codable, Sendable, Equatable {
    public var tool: EngineID
    /// An alias such as `sonnet` or an exact id. Nil uses the plan default.
    public var model: String?
    public var effort: Effort?

    public init(tool: EngineID, model: String? = nil, effort: Effort? = nil) {
        self.tool = tool
        self.model = model
        self.effort = effort
    }
}

/// One step in a channel's or video's row.
public struct Node: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String
    public var title: String
    public var engine: EngineChoice?
    /// Editable prompt. Nil uses the built-in template.
    public var promptTemplate: String?
    public var inputs: [String]
    public var outputs: [String]
    public var approval: ApprovalRule
    public var state: NodeState
    /// One line shown on the card when done.
    public var resultSummary: String?
    public var updatedAt: Date?

    public init(
        id: String = Identifier.make(prefix: "n"),
        type: String,
        title: String,
        engine: EngineChoice? = nil,
        promptTemplate: String? = nil,
        inputs: [String] = [],
        outputs: [String] = [],
        approval: ApprovalRule = .byDial,
        state: NodeState = .waiting,
        resultSummary: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.engine = engine
        self.promptTemplate = promptTemplate
        self.inputs = inputs
        self.outputs = outputs
        self.approval = approval
        self.state = state
        self.resultSummary = resultSummary
        self.updatedAt = updatedAt
    }

    /// A node of a built-in type with its default inputs, outputs and engine.
    public init(_ type: NodeType, engine: EngineChoice? = nil) {
        self.init(
            type: type.id,
            title: type.title,
            engine: type.worker == .llm ? (engine ?? EngineChoice(tool: .claude)) : nil,
            inputs: type.inputs,
            outputs: type.outputs,
            approval: type.approval
        )
    }

    public var nodeType: NodeType? { NodeRegistry.type(type) }

    public var isCustom: Bool { type == NodeType.custom.id }
}
