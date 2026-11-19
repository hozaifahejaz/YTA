import Foundation
import ChannelStore
import Support

/// Reads and writes a channel's node rows. The UI goes through here, never to the disk directly.
public struct WorkflowStore: Sendable {
    public let folder: ChannelFolder

    public init(folder: ChannelFolder) {
        self.folder = folder
    }

    public func setupRow() -> NodeList? {
        try? folder.readJSON(NodeList.self, ChannelLayout.setupWorkflow)
    }

    public func videoTemplate() -> NodeList? {
        try? folder.readJSON(NodeList.self, ChannelLayout.videoWorkflow)
    }

    public func saveSetupRow(_ list: NodeList) throws {
        try folder.writeJSON(list, to: ChannelLayout.setupWorkflow)
    }

    public func saveVideoTemplate(_ list: NodeList) throws {
        try folder.writeJSON(list, to: ChannelLayout.videoWorkflow)
    }

    /// Writes the default rows for a newly created channel. Leaves existing rows alone.
    public func installDefaults(origin: ChannelOrigin, nicheGiven: Bool) throws {
        if setupRow() == nil {
            var row = DefaultRows.setup(for: origin)
            if origin == .new, nicheGiven, let niche = row.nodes.first(where: { $0.type == "niche" }) {
                row.setState(niche.id, .done, summary: "Typed in by you")
            }
            try saveSetupRow(row)
        }
        if videoTemplate() == nil {
            try saveVideoTemplate(DefaultRows.videoRow())
        }
    }
}

/// Saved custom nodes and whole rows, kept in the app's `templates/` folder (section 5.1).
public struct TemplateStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public struct Template: Codable, Sendable, Equatable, Identifiable {
        public var schemaVersion: Int = 1
        public var id: String
        public var name: String
        public var nodes: [Node]
        public var createdAt: Date
    }

    public func list() -> [Template] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".node-template.json") }.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? JSONCoding.decoder().decode(Template.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func save(name: String, nodes: [Node]) throws -> Template {
        let cleaned = nodes.map { node -> Node in
            var copy = node
            copy.id = Identifier.make(prefix: "n")
            copy.state = .waiting
            copy.resultSummary = nil
            copy.updatedAt = nil
            return copy
        }
        let template = Template(id: Identifier.make(prefix: "tpl"), name: name, nodes: cleaned, createdAt: Date())
        let file = folder.appendingPathComponent("\(SafeName.folderName(for: name))-\(template.id).node-template.json")
        try AtomicFile.writeJSON(template, to: file, preservingUnknownFields: false)
        return template
    }
}
