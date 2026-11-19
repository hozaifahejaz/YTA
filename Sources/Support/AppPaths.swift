import Foundation

/// Where YTA keeps its own data and where channels live (section 4).
public struct AppPaths: Sendable, Equatable {
    /// `~/Library/Application Support/YTA`
    public let support: URL
    /// `~/YouTube Automation`
    public let storageRoot: URL

    public init(support: URL, storageRoot: URL) {
        self.support = support
        self.storageRoot = storageRoot
    }

    public static func standard(storageRoot: URL? = nil) -> AppPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/YTA", isDirectory: true)
        return AppPaths(
            support: support,
            storageRoot: storageRoot ?? home.appendingPathComponent("YouTube Automation", isDirectory: true)
        )
    }

    public var settingsFile: URL { support.appendingPathComponent("settings.json") }
    public var toolsFile: URL { support.appendingPathComponent("tools.json") }
    public var quotaFile: URL { support.appendingPathComponent("quota.json") }
    public var templates: URL { support.appendingPathComponent("templates", isDirectory: true) }
    public var skills: URL { support.appendingPathComponent("skills", isDirectory: true) }
    public var remotion: URL { support.appendingPathComponent("remotion", isDirectory: true) }
    public var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }

    public var channels: URL { storageRoot.appendingPathComponent("Channels", isDirectory: true) }
    public var research: URL { storageRoot.appendingPathComponent("Research", isDirectory: true) }

    public func createFolders() throws {
        for url in [support, templates, skills, logs, channels, research] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
