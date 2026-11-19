import Foundation
import Support

/// A tool or resource the health check looks for (section 6.4).
public enum HealthItemID: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode
    case node
    case remotion
    case ffmpeg
    case disk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .node: "Node.js"
        case .remotion: "Remotion"
        case .ffmpeg: "ffmpeg"
        case .disk: "Free disk space"
        }
    }

    public var purpose: String {
        switch self {
        case .claude: "Research, prompts, reviews. Runs on your subscription."
        case .codex: "Script writing with ChatGPT, and images."
        case .opencode: "An extra engine you can pick per step."
        case .node: "Needed to run Remotion."
        case .remotion: "Edits and renders videos."
        case .ffmpeg: "Audio and video checks."
        case .disk: "Renders and media need room."
        }
    }

    /// The command to find, for items that are command line tools.
    public var command: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .node: "node"
        case .ffmpeg: "ffmpeg"
        case .remotion, .disk: nil
        }
    }

    /// How to fix it when missing. Shown as a command the owner can copy.
    public var fix: String? {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .opencode: "npm install -g opencode-ai"
        case .node: "Install Node.js LTS from nodejs.org"
        case .remotion: "YTA installs it on first use"
        case .ffmpeg: "Comes with Remotion (npx remotion ffmpeg)"
        case .disk: "Free some space or move storage in Settings"
        }
    }

    /// Items YTA cannot work without.
    public var required: Bool {
        switch self {
        case .claude, .node, .disk: true
        default: false
        }
    }
}

public struct HealthItem: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case ok
        case missing
        case warning
        case checking
    }

    public var id: HealthItemID
    public var status: Status
    public var path: String?
    public var version: String?
    public var detail: String?
}

/// `tools.json`: resolved paths and versions, re-checked on launch.
public struct ToolsFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var checkedAt: Date
    public var items: [HealthItem]
}

public struct HealthCheck: Sendable {
    public let paths: AppPaths
    /// Lets tests replace the login-shell lookup.
    public var locate: @Sendable (String) async -> URL?
    public var version: @Sendable (URL) async -> String?
    public var minimumFreeBytes: Int64 = 20 * 1_000_000_000

    public init(paths: AppPaths) {
        self.paths = paths
        self.locate = { await ProcessRunner.locate($0) }
        self.version = { url in
            guard let result = try? await ProcessRunner.run(url, arguments: ["--version"], timeout: 15) else { return nil }
            let text = (result.stdout.isEmpty ? result.stderr : result.stdout)
            return text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    public func run() async -> ToolsFile {
        var items: [HealthItem] = []
        await withTaskGroup(of: HealthItem.self) { group in
            for id in HealthItemID.allCases {
                group.addTask { await check(id) }
            }
            for await item in group { items.append(item) }
        }
        items.sort { HealthItemID.allCases.firstIndex(of: $0.id)! < HealthItemID.allCases.firstIndex(of: $1.id)! }
        let file = ToolsFile(checkedAt: Date(), items: items)
        try? AtomicFile.writeJSON(file, to: paths.toolsFile, preservingUnknownFields: false)
        return file
    }

    public func check(_ id: HealthItemID) async -> HealthItem {
        switch id {
        case .disk:
            let free = HealthCheck.freeBytes(at: paths.storageRoot)
            let gb = Double(free ?? 0) / 1_000_000_000
            let status: HealthItem.Status = (free ?? 0) >= minimumFreeBytes ? .ok : .warning
            return HealthItem(id: id, status: free == nil ? .warning : status, detail: String(format: "%.0f GB free", gb))
        case .remotion:
            let installed = FileManager.default.fileExists(atPath: paths.remotion.appendingPathComponent("node_modules/remotion").path)
            return HealthItem(id: id, status: installed ? .ok : .warning, path: installed ? paths.remotion.path : nil,
                              detail: installed ? nil : "Installed on first use")
        case .ffmpeg:
            if let url = await locate("ffmpeg") {
                return HealthItem(id: id, status: .ok, path: url.path, version: await version(url))
            }
            // Remotion ships its own ffmpeg, so a missing system copy is only a warning.
            return HealthItem(id: id, status: .warning, detail: "Will use the copy that comes with Remotion")
        default:
            guard let command = id.command, let url = await locate(command) else {
                return HealthItem(id: id, status: .missing, detail: id.fix)
            }
            return HealthItem(id: id, status: .ok, path: url.path, version: await version(url))
        }
    }

    public static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        #if os(macOS)
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        #endif
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: probe.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    public static func load(from paths: AppPaths) -> ToolsFile? {
        guard let data = try? Data(contentsOf: paths.toolsFile) else { return nil }
        return try? JSONCoding.decoder().decode(ToolsFile.self, from: data)
    }
}
