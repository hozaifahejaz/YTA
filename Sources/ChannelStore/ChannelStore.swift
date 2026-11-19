import Foundation
import Support

/// A channel as the app lists it.
public struct ChannelRecord: Sendable, Equatable, Identifiable {
    public let folder: ChannelFolder
    public var manifest: ChannelManifest

    public var id: String { manifest.id }
}

public struct NewChannelRequest: Sendable {
    public var workingName: String
    public var niche: String?
    public var format: ChannelFormat
    public var language: String
    public var country: String?
    public var origin: ChannelOrigin
    public var importLink: String?
    public var automation: AutomationLevel

    public init(
        workingName: String,
        niche: String? = nil,
        format: ChannelFormat = .longForm,
        language: String = "English",
        country: String? = nil,
        origin: ChannelOrigin = .new,
        importLink: String? = nil,
        automation: AutomationLevel = .approveEvery
    ) {
        self.workingName = workingName
        self.niche = niche
        self.format = format
        self.language = language
        self.country = country
        self.origin = origin
        self.importLink = importLink
        self.automation = automation
    }
}

/// `queue.json`. Video rows refer to ids, never folder names.
public struct QueueFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var items: [Item] = []

    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var status: String
    }

    public init() {}
}

/// `calendar.json`.
public struct CalendarFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var cadencePerWeek: Int?
    public var entries: [JSONValue] = []

    public init() {}
}

/// Creates, lists and renames channel folders under `Channels/`.
public struct ChannelStore: Sendable {
    public let channelsFolder: URL

    public init(channelsFolder: URL) {
        self.channelsFolder = channelsFolder
    }

    public func listChannels() -> [ChannelRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: channelsFolder.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> ChannelRecord? in
                let folder = ChannelFolder(root: channelsFolder.appendingPathComponent(name, isDirectory: true))
                guard let manifest = try? folder.manifest() else { return nil }
                return ChannelRecord(folder: folder, manifest: manifest)
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Lays out a new channel folder with every file the later steps expect.
    @discardableResult
    public func createChannel(_ request: NewChannelRequest) throws -> ChannelRecord {
        let name = request.workingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw YTAError(.fileFormat, "The channel needs a working name.") }
        try FileManager.default.createDirectory(at: channelsFolder, withIntermediateDirectories: true)
        let folderName = SafeName.uniqueFolderName(for: name, in: channelsFolder)
        let root = channelsFolder.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = ChannelFolder(root: root)

        for sub in ChannelLayout.folders { try folder.createFolder(sub) }

        let manifest = ChannelManifest(
            name: name,
            format: request.format,
            language: request.language,
            country: request.country,
            origin: request.origin,
            importLink: request.importLink,
            automation: request.automation
        )
        try folder.saveManifest(manifest)

        let titles = ["niche.md": "Niche", "audience.md": "Audience", "voice.md": "Voice", "pillars.md": "Content pillars", "rules.md": "Channel rules"]
        for file in ChannelLayout.profileFiles {
            var body = "# \(titles[file]!)\n"
            if file == "niche.md", let niche = request.niche?.trimmingCharacters(in: .whitespacesAndNewlines), !niche.isEmpty {
                body += "\n\(niche)\n"
            }
            try folder.writeText(body, to: "\(ChannelLayout.profile)/\(file)", source: "new channel")
        }
        try folder.writeJSON(SourcesConfig(), to: ChannelLayout.sources, source: "new channel")
        try folder.writeText("", to: "\(ChannelLayout.styles)/banned-phrases.txt", source: "new channel")
        try folder.writeJSON(QueueFile(), to: ChannelLayout.queue)
        try folder.writeJSON(CalendarFile(), to: ChannelLayout.calendar)
        try folder.writeText("@AGENTS.md\n", to: ChannelLayout.claude)
        try folder.regenerateAgentsFile(source: "new channel")

        return ChannelRecord(folder: folder, manifest: manifest)
    }

    /// Renames the channel and its folder. Identity stays the id in `channel.json`.
    @discardableResult
    public func rename(_ record: ChannelRecord, to newName: String) throws -> ChannelRecord {
        var manifest = record.manifest
        manifest.name = newName
        let currentName = record.folder.root.lastPathComponent
        var target = record.folder.root
        if SafeName.folderName(for: newName) != currentName {
            let folderName = SafeName.uniqueFolderName(for: newName, in: channelsFolder)
            target = channelsFolder.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.moveItem(at: record.folder.root, to: target)
        }
        let folder = ChannelFolder(root: target)
        try folder.saveManifest(manifest)
        try folder.regenerateAgentsFile(source: "rename")
        return ChannelRecord(folder: folder, manifest: manifest)
    }
}
