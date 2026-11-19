import Foundation
import Support

/// The editable row of nodes stored in `workflow/setup.json` or `workflow/video.json` (section 5.1).
public struct NodeList: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var kind: Kind
    public var nodes: [Node]

    public enum Kind: String, Codable, Sendable {
        case setup
        case video
    }

    public init(kind: Kind, nodes: [Node]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.nodes = nodes
    }

    public func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    public subscript(id: String) -> Node? { nodes.first { $0.id == id } }

    // MARK: Dependencies

    /// Nodes that read a file this node writes, directly or through others, in row order.
    public func downstream(of id: String) -> [Node] {
        guard let start = index(of: id) else { return [] }
        var produced = Set(nodes[start].outputs)
        var result: [Node] = []
        for node in nodes[(start + 1)...] where !produced.isDisjoint(with: node.inputs) {
            result.append(node)
            produced.formUnion(node.outputs)
        }
        return result
    }

    /// Nodes that would lose an input if this node were removed, because no other node produces it.
    public func nodesBroken(byRemoving id: String) -> [Node] {
        guard let target = self[id] else { return [] }
        let remaining = nodes.filter { $0.id != id }
        let stillProduced = Set(remaining.flatMap(\.outputs))
        let lost = Set(target.outputs).subtracting(stillProduced)
        guard !lost.isEmpty else { return [] }
        return remaining.filter { !lost.isDisjoint(with: $0.inputs) }
    }

    /// Removes a node. Throws if others depend on it, unless `force` is true (the owner confirmed).
    public mutating func remove(_ id: String, force: Bool = false) throws {
        guard let i = index(of: id) else { throw YTAError(.notFound, "That step is no longer in the row.") }
        let broken = nodesBroken(byRemoving: id)
        if !broken.isEmpty && !force {
            let names = broken.map(\.title).joined(separator: ", ")
            throw YTAError(.checkFailed, "Removing \(nodes[i].title) breaks \(names).", suggestion: "Confirm to remove it anyway.")
        }
        nodes.remove(at: i)
    }

    /// Inserts a node after the last node that produces one of its inputs (section 5.1).
    /// With `after` given, the node goes right after that node instead.
    @discardableResult
    public mutating func insert(_ node: Node, after anchor: String? = nil) -> Int {
        var position: Int
        if let anchor, let i = index(of: anchor) {
            position = i + 1
        } else {
            let lastProducer = nodes.lastIndex { !Set($0.outputs).isDisjoint(with: node.inputs) }
            position = lastProducer.map { $0 + 1 } ?? nodes.count
        }
        position = min(max(position, 0), nodes.count)
        nodes.insert(node, at: position)
        return position
    }

    public mutating func update(_ node: Node) {
        guard let i = index(of: node.id) else { return }
        nodes[i] = node
    }

    /// Marks a node for redoing and every node downstream of it as out of date.
    public mutating func redo(_ id: String) {
        guard let i = index(of: id) else { return }
        let downstreamIDs = Set(downstream(of: id).map(\.id))
        nodes[i].state = .waiting
        nodes[i].resultSummary = nil
        for j in nodes.indices where downstreamIDs.contains(nodes[j].id) && nodes[j].state == .done {
            nodes[j].state = .stale
        }
    }

    public mutating func setState(_ id: String, _ state: NodeState, summary: String? = nil) {
        guard let i = index(of: id) else { return }
        nodes[i].state = state
        if let summary { nodes[i].resultSummary = summary }
        nodes[i].updatedAt = Date()
    }

    /// The first node that is not done, which is where the row continues.
    public var nextNode: Node? {
        nodes.first { $0.state != .done }
    }

    public var progress: (done: Int, total: Int) {
        (nodes.filter { $0.state == .done }.count, nodes.count)
    }
}
