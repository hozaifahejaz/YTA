import Foundation
import Support

/// Guarded access to one channel folder. Every read and write goes through here (section 5.7).
public struct ChannelFolder: Sendable, Equatable, Identifiable {
    public let root: URL
    public let guardian: PathGuard

    public var id: String { root.path }

    public init(root: URL) {
        let resolved = PathGuard.resolve(root)
        self.root = resolved
        self.guardian = PathGuard(root: resolved)
    }

    public static func == (lhs: ChannelFolder, rhs: ChannelFolder) -> Bool { lhs.root == rhs.root }

    private var history: HistoryStore { HistoryStore(channelRoot: root) }

    // MARK: Paths

    public func url(_ relative: String) throws -> URL {
        try guardian.url(for: relative)
    }

    public func exists(_ relative: String) -> Bool {
        guard let url = try? url(relative) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The relative path of a URL inside this channel, or nil if it is outside.
    public func relativePath(of url: URL) -> String? {
        guard let resolved = try? guardian.check(url) else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if resolved.path == root.path { return "" }
        return String(resolved.path.dropFirst(rootPath.count))
    }

    // MARK: Reading

    public func read(_ relative: String) throws -> Data {
        let url = try url(relative)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw YTAError(.notFound, "\(relative) does not exist in this channel.")
        }
        return data
    }

    public func readText(_ relative: String) throws -> String {
        String(decoding: try read(relative), as: UTF8.self)
    }

    public func readJSON<T: Decodable>(_ type: T.Type, _ relative: String) throws -> T {
        let data = try read(relative)
        do {
            return try JSONCoding.decoder().decode(type, from: data)
        } catch {
            throw YTAError(.fileFormat, "\(relative) could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: Writing

    /// Writes a file atomically. Instruction files get a history snapshot naming `source`.
    public func write(_ data: Data, to relative: String, source: String = "YTA") throws {
        let url = try url(relative)
        let isInstruction = ChannelLayout.isInstructionFile(relative)
        if isInstruction, history.snapshots(for: relative).isEmpty,
           let original = FileManager.default.contents(atPath: url.path) {
            try history.save(original, file: relative, source: "original")
        }
        try AtomicFile.write(data, to: url)
        if isInstruction {
            try history.save(data, file: relative, source: source)
        }
    }

    public func writeText(_ text: String, to relative: String, source: String = "YTA") throws {
        try write(Data(text.utf8), to: relative, source: source)
    }

    /// Encodes and writes JSON, keeping fields in the existing file that the app does not model.
    public func writeJSON<T: Encodable>(_ value: T, to relative: String, source: String = "YTA") throws {
        let existing = exists(relative) ? try? read(relative) : nil
        try write(JSONMerge.encodePreserving(value, over: existing), to: relative, source: source)
    }

    public func createFolder(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    // MARK: History

    public func history(for relative: String) -> [HistorySnapshot] {
        history.snapshots(for: relative)
    }

    /// Writes a saved version back. The restore itself is recorded as a new version.
    public func restore(_ snapshot: HistorySnapshot) throws {
        guard ChannelLayout.isInstructionFile(snapshot.file) else {
            throw YTAError(.notFound, "\(snapshot.file) has no history.")
        }
        let data = try Data(contentsOf: snapshot.url)
        try write(data, to: snapshot.file, source: "restore")
    }

    /// Called when a file changed outside the app. Instruction files get a snapshot when their content is new.
    @discardableResult
    public func noteExternalChange(_ relative: String) throws -> HistorySnapshot? {
        guard ChannelLayout.isInstructionFile(relative), exists(relative) else { return nil }
        let data = try read(relative)
        if history.latestData(for: relative) == data { return nil }
        return try history.save(data, file: relative, source: "outside edit")
    }

    // MARK: Manifest

    public func manifest() throws -> ChannelManifest {
        try readJSON(ChannelManifest.self, ChannelLayout.manifest)
    }

    public func saveManifest(_ manifest: ChannelManifest) throws {
        try writeJSON(manifest, to: ChannelLayout.manifest)
    }

    public func sources() -> SourcesConfig {
        (try? readJSON(SourcesConfig.self, ChannelLayout.sources)) ?? SourcesConfig()
    }

    /// Rebuilds `AGENTS.md` from the profile, keeping the owner's marked section.
    public func regenerateAgentsFile(source: String = "profile change") throws {
        let manifest = try manifest()
        var files: [String: String] = [:]
        for name in ChannelLayout.profileFiles {
            files[name] = try? readText("\(ChannelLayout.profile)/\(name)")
        }
        let existing = try? readText(ChannelLayout.agents)
        let text = AgentsFile.render(.init(manifest: manifest, files: files, sources: sources()), keepingManualFrom: existing)
        if text != existing {
            try writeText(text, to: ChannelLayout.agents, source: source)
        }
    }

    /// Lists every file under the channel, relative paths, skipping history. Used to spot unexpected files after a run.
    public func fileInventory() -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result = Set<String>()
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let relative = relativePath(of: url),
                  !relative.hasPrefix(ChannelLayout.history + "/")
            else { continue }
            result.insert(relative)
        }
        return result
    }
}
