import Foundation
import Support

/// Refuses any path that resolves outside a root folder, following symlinks (section 5.7).
public struct PathGuard: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = PathGuard.resolve(root)
    }

    /// Resolves `relative` inside the root, or throws if it would land outside.
    public func url(for relative: String) throws -> URL {
        if relative.hasPrefix("/") || relative.hasPrefix("~") {
            throw YTAError(.pathOutsideChannel, "“\(relative)” is not a path inside the channel.")
        }
        let candidate = root.appendingPathComponent(relative)
        return try check(candidate)
    }

    /// Checks an absolute URL and returns its resolved form.
    public func check(_ url: URL) throws -> URL {
        let resolved = PathGuard.resolve(url)
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
            throw YTAError(.pathOutsideChannel, "“\(url.path)” is outside the channel folder.")
        }
        return resolved
    }

    public func contains(_ url: URL) -> Bool {
        (try? check(url)) != nil
    }

    /// Resolves symlinks for the deepest part of the path that exists, then appends the rest.
    static func resolve(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var remainder: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for part in remainder { result.appendPathComponent(part) }
        return result.standardizedFileURL
    }
}
