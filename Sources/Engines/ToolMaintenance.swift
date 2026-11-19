import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Support

/// How a tool got onto the Mac, which decides how YTA updates it.
public enum InstallMethod: String, Codable, Sendable {
    case homebrew, homebrewCask, npm, claudeInstaller, appManaged, unknown
}

/// A tool's installed and newest versions, and how to install or update it.
public struct ToolStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: HealthItemID
    public var installed: String?
    public var latest: String?
    public var method: InstallMethod
    /// The shell command YTA runs to update, or nil when it can't update this tool itself.
    public var updateCommand: String?
    public var installCommand: String?
    /// Where to send the owner when YTA can't do it.
    public var manualHint: String?

    public var updateAvailable: Bool {
        guard let installed, let latest else { return false }
        return Semver.isNewer(latest, than: installed)
    }

    public init(id: HealthItemID, installed: String?, latest: String?, method: InstallMethod, updateCommand: String?,
                installCommand: String?, manualHint: String? = nil) {
        self.id = id
        self.installed = installed
        self.latest = latest
        self.method = method
        self.updateCommand = updateCommand
        self.installCommand = installCommand
        self.manualHint = manualHint
    }
}

/// `tool-updates.json`: the last update check.
public struct ToolUpdatesFile: Codable, Sendable, Equatable {
    public var checkedAt: Date
    public var tools: [ToolStatus]

    public init(checkedAt: Date, tools: [ToolStatus]) {
        self.checkedAt = checkedAt
        self.tools = tools
    }
}

public enum Semver {
    /// The first dotted number in a version line, such as "2.1.328" from "2.1.328 (Claude Code)" or "v22.23.4".
    public static func parse(_ text: String) -> [Int]? {
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    public static func string(_ text: String?) -> String? {
        text.flatMap(parse).map { $0.map(String.init).joined(separator: ".") }
    }
}

/// Installs, checks and updates the tools YTA drives (section 6.4). Homebrew and npm tools are updated with
/// their own package manager, Claude Code with its own updater; Remotion is updated by the app itself.
public struct ToolMaintenance: Sendable {
    public var shell: @Sendable (String, TimeInterval) async throws -> ProcessResult
    public var fetch: @Sendable (URL) async -> Data?

    /// npm packages whose registry entry gives the newest version.
    static let npmPackages: [HealthItemID: String] = [
        .claude: "@anthropic-ai/claude-code", .codex: "@openai/codex", .opencode: "opencode-ai", .remotion: "remotion",
    ]
    static let brewNames: [HealthItemID: String] = [
        .codex: "codex", .opencode: "opencode", .node: "node", .ffmpeg: "ffmpeg", .whisper: "whisper-cpp",
    ]

    public init(shell: @escaping @Sendable (String, TimeInterval) async throws -> ProcessResult = { try await ProcessRunner.shell($0, timeout: $1) },
                fetch: @escaping @Sendable (URL) async -> Data? = ToolMaintenance.download) {
        self.shell = shell
        self.fetch = fetch
    }

    public static let download: @Sendable (URL) async -> Data? = { url in
        await withCheckedContinuation { continuation in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("YTA/1.0 (tool update check)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200
                continuation.resume(returning: ok ? data : nil)
            }.resume()
        }
    }

    /// From the tool's real path (symlinks followed) to how it was installed.
    public static func method(for id: HealthItemID, realPath: String?) -> InstallMethod {
        if id == .remotion { return .appManaged }
        guard let path = realPath else { return .unknown }
        if path.contains("/Caskroom/") { return .homebrewCask }
        if path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Homebrew/") { return .homebrew }
        if path.contains("/node_modules/") { return .npm }
        if id == .claude, path.contains("/.local/share/claude/") || path.contains("/.claude/local/") { return .claudeInstaller }
        return .unknown
    }

    static func updateCommand(_ id: HealthItemID, method: InstallMethod) -> String? {
        switch method {
        case .homebrew: brewNames[id].map { "brew upgrade \($0)" }
        case .homebrewCask: id == .claude ? "brew upgrade --cask claude-code" : brewNames[id].map { "brew upgrade --cask \($0)" }
        case .npm: npmPackages[id].map { "npm install -g \($0)@latest" }
        case .claudeInstaller: "claude update"
        case .appManaged, .unknown: nil
        }
    }

    static func installCommand(_ id: HealthItemID, hasBrew: Bool, hasNpm: Bool) -> String? {
        switch id {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: hasNpm ? "npm install -g @openai/codex" : (hasBrew ? "brew install codex" : nil)
        case .opencode: hasBrew ? "brew install opencode" : (hasNpm ? "npm install -g opencode-ai" : nil)
        case .node, .ffmpeg, .whisper: hasBrew ? brewNames[id].map { "brew install \($0)" } : nil
        case .remotion, .disk: nil
        }
    }

    /// An install command when no update check has run yet.
    public static func fallbackInstall(_ id: HealthItemID) -> String? {
        installCommand(id, hasBrew: true, hasNpm: true)
    }

    static func manualHint(_ id: HealthItemID) -> String? {
        switch id {
        case .node: "Install Node.js LTS from nodejs.org, or install Homebrew (brew.sh) and YTA will do it."
        case .ffmpeg, .whisper: "Install Homebrew from brew.sh, then YTA can install and update it."
        default: nil
        }
    }

    func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Newest versions from Homebrew (for Homebrew installs) or the npm registry.
    public func check(_ tools: ToolsFile, remotionVersion: String?) async -> [ToolStatus] {
        let hasBrew = ((try? await shell("command -v brew", 15))?.succeeded) ?? false
        let hasNpm = ((try? await shell("command -v npm", 15))?.succeeded) ?? false
        var outdated: [String: String] = [:]
        if hasBrew {
            _ = try? await shell("brew update --quiet", 300)
            if let result = try? await shell("brew outdated --json=v2", 120), result.succeeded {
                outdated = Self.brewOutdated(result.stdout)
            }
        }
        var statuses: [ToolStatus] = []
        for id in HealthItemID.allCases where id != .disk {
            let item = tools.items.first { $0.id == id }
            let present = item?.path != nil && item?.status != .missing
            let method = Self.method(for: id, realPath: item?.path.map(realPath))
            var installed = id == .remotion ? remotionVersion : Semver.string(item?.version)
            if !present, id != .remotion { installed = nil }
            var latest: String?
            if method == .homebrew || method == .homebrewCask, let name = Self.brewNames[id] ?? (id == .claude ? "claude-code" : nil) {
                latest = outdated[name] ?? installed
            } else if let package = Self.npmPackages[id] {
                latest = await npmLatest(package)
            } else if id == .node {
                latest = await nodeLTS()
            }
            statuses.append(ToolStatus(
                id: id, installed: installed, latest: latest, method: method,
                updateCommand: present ? Self.updateCommand(id, method: method) : nil,
                installCommand: present ? nil : Self.installCommand(id, hasBrew: hasBrew, hasNpm: hasNpm),
                manualHint: present ? nil : Self.manualHint(id)))
        }
        return statuses
    }

    /// `brew outdated --json=v2`: formula and cask names to their newest version.
    public static func brewOutdated(_ json: String) -> [String: String] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return [:] }
        var result: [String: String] = [:]
        for key in ["formulae", "casks"] {
            for item in value[key]?.arrayValue ?? [] {
                if let name = item["name"]?.stringValue, let current = item["current_version"]?.stringValue {
                    result[name] = current
                    if let short = name.split(separator: "/").last { result[String(short)] = current }
                }
            }
        }
        return result
    }

    func npmLatest(_ package: String) async -> String? {
        let escaped = package.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://registry.npmjs.org/\(escaped)/latest"), let data = await fetch(url),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value["version"]?.stringValue
    }

    func nodeLTS() async -> String? {
        guard let data = await fetch(URL(string: "https://nodejs.org/dist/index.json")!),
              let list = (try? JSONDecoder().decode(JSONValue.self, from: data))?.arrayValue else { return nil }
        let lts = list.first { item in if case .string = item["lts"] { return true } else { return false } }
        return lts?["version"]?.stringValue.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
    }

    /// Runs an install or update command through the login shell. Never interactive.
    public func run(_ command: String) async throws -> ProcessResult {
        let result = try await shell("export HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 CI=1; \(command) < /dev/null", 1800)
        guard result.succeeded else {
            throw YTAError(.toolMissing, "\"\(command)\" did not finish.", suggestion: String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(400)))
        }
        return result
    }
}
