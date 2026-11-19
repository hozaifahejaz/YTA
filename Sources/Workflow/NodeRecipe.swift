import ChannelStore
import Engines
import Foundation
import Support

/// What a node type adds to the shared run lifecycle: its prompt, its result format,
/// and what the app does with the result before the owner sees it.
public protocol NodeRecipe: Sendable {
    /// False for steps the app does alone (drawing, rendering).
    var usesEngine: Bool { get }
    var schema: JSONValue { get }
    var kind: StepKind { get }
    var policy: ToolPolicy { get }
    /// The task, after the shared header. Built-in steps ignore the node's prompt only if it is nil.
    func task(node: Node, folder: ChannelFolder) throws -> String
    func returnInstructions(node: Node) -> String
    /// Turns the checked result into files. May take a while (name checks, drawing).
    func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
               context: RunContext, note: String?) async throws -> RunDraft
    /// Runs after the files are written, for example to update channel.json.
    func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws
}

extension NodeRecipe {
    public var usesEngine: Bool { true }
    public var kind: StepKind { .general }
    public var policy: ToolPolicy { .readOnly }
    public var schema: JSONValue { .null }
    public func task(node: Node, folder: ChannelFolder) throws -> String { node.promptTemplate ?? "" }
    public func returnInstructions(node: Node) -> String { "Return JSON matching the schema." }
    public func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws {}
}

/// Which recipe runs which node type. Types without one are not runnable yet.
public enum NodeRecipes {
    public static func recipe(for node: Node) -> NodeRecipe? {
        if node.isCustom { return node.outputs.isEmpty ? nil : CustomRecipe() }
        switch node.type {
        case "name": return NameRecipe()
        case "brand": return BrandRecipe()
        case "avatar": return AvatarRecipe()
        case "banner": return BannerRecipe()
        case "setupKit": return SetupKitRecipe()
        case "playbook": return PlaybookRecipe()
        default: return nil
        }
    }
}

/// The owner's own prompt, writing one text file.
public struct CustomRecipe: NodeRecipe {
    public static let schema = JSONValue.parse(#"""
    {"type":"object","required":["content","summary"],"additionalProperties":false,
     "properties":{"content":{"type":"string","minLength":1},"summary":{"type":"string","maxLength":160}}}
    """#)!

    public var schema: JSONValue { Self.schema }

    public func returnInstructions(node: Node) -> String {
        "Return JSON with two fields. `content` is the complete text of the file \(node.outputs[0]), ready to save. `summary` is one short line describing it."
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        guard let content = value["content"]?.stringValue, !content.isEmpty else {
            throw YTAError(.schemaMismatch, "The result had no content.")
        }
        return RunDraft(files: [node.outputs[0]: content], summary: value["summary"]?.stringValue)
    }
}
