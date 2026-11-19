import Foundation

/// The command line tools YTA drives. Antigravity and a local model are planned later (section 5.3).
public enum EngineID: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    /// The command the adapter starts.
    public var command: String { rawValue }

    /// The plans the owner can choose for this tool (section 5.4).
    public var plans: [String] {
        switch self {
        case .claude: ["Pro", "Max 5x", "Max 20x", "API"]
        case .codex: ["Plus", "Pro", "API"]
        case .opencode: ["Default"]
        }
    }
}

/// How hard an engine thinks. Each adapter maps it to its own tool's values.
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

public enum AutomationLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Approve every node.
    case approveEvery
    /// Approve only the script and the final cut.
    case approveKey
    /// Run straight through to the finished folder. The final check still runs.
    case straightThrough

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .approveEvery: "Approve every step"
        case .approveKey: "Approve script and final cut"
        case .straightThrough: "Run straight through"
        }
    }
}

public enum ImageRoute: String, Codable, Sendable, CaseIterable, Identifiable {
    case appDrawn
    case chatGPTViaCodex
    case ai33pro
    case llmDrawingCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appDrawn: "Drawn by YTA"
        case .chatGPTViaCodex: "ChatGPT through Codex"
        case .ai33pro: "ai33pro image generation"
        case .llmDrawingCode: "Drawing code written by an LLM"
        }
    }
}

public struct EngineSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var plan: String
    /// Off by default. Claude Code runs on the subscription login (rule 6).
    public var allowAPIKey: Bool
    /// An exact model id typed by the owner, overriding the plan default.
    public var modelOverride: String?

    public init(enabled: Bool = true, plan: String, allowAPIKey: Bool = false, modelOverride: String? = nil) {
        self.enabled = enabled
        self.plan = plan
        self.allowAPIKey = allowAPIKey
        self.modelOverride = modelOverride
    }
}

/// Spend caps that stop the queue (section 5.9). Nil means no cap.
public struct CostCaps: Codable, Sendable, Equatable {
    public var perVideoUSD: Double?
    public var perDayUSD: Double?
    public var perVideoVoiceCharacters: Int?
    public var perDayVoiceCharacters: Int?

    public init(perVideoUSD: Double? = nil, perDayUSD: Double? = nil, perVideoVoiceCharacters: Int? = nil, perDayVoiceCharacters: Int? = nil) {
        self.perVideoUSD = perVideoUSD
        self.perDayUSD = perDayUSD
        self.perVideoVoiceCharacters = perVideoVoiceCharacters
        self.perDayVoiceCharacters = perDayVoiceCharacters
    }
}

/// The MCP server that lets AI tools on this Mac control YTA. It listens on 127.0.0.1 only.
public struct ControlSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var port: Int

    public static let defaultPort = 47821

    public init(enabled: Bool = true, port: Int = ControlSettings.defaultPort) {
        self.enabled = enabled
        self.port = port
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var engines: [String: EngineSettings]
    /// The folder that holds `Channels/` and `Research/`. Nil means `~/YouTube Automation`.
    public var storagePath: String?
    public var imageRoute: ImageRoute
    public var automationDefault: AutomationLevel
    /// The engine that writes scripts unless a channel says otherwise.
    public var defaultWriter: EngineID
    /// Days after a video is finished before bulky working files are cleared. Nil keeps them.
    public var clearWorkingFilesAfterDays: Int?
    public var finishedFirstRun: Bool
    /// When a same-name channel counts as only a small overlap (section 7.3, step 4).
    public var nameOverlap: NameOverlapThresholds
    public var caps: CostCaps
    /// Install updates to the tools YTA drives on its own, once a day, when nothing is running.
    public var autoUpdateTools: Bool
    public var control: ControlSettings

    public init() {
        schemaVersion = Self.currentSchemaVersion
        engines = Dictionary(uniqueKeysWithValues: EngineID.allCases.map { ($0.rawValue, EngineSettings(plan: $0.plans[0])) })
        storagePath = nil
        imageRoute = .appDrawn
        automationDefault = .approveEvery
        defaultWriter = .codex
        clearWorkingFilesAfterDays = nil
        finishedFirstRun = false
        nameOverlap = NameOverlapThresholds()
        caps = CostCaps()
        autoUpdateTools = true
        control = ControlSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, engines, storagePath, imageRoute, automationDefault, defaultWriter, clearWorkingFilesAfterDays, finishedFirstRun
        case nameOverlap, caps, autoUpdateTools, control
    }

    /// Missing keys fall back to defaults, so older files keep loading.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let value = try c.decodeIfPresent([String: EngineSettings].self, forKey: .engines) {
            engines.merge(value) { _, new in new }
        }
        storagePath = try c.decodeIfPresent(String.self, forKey: .storagePath)
        imageRoute = (try? c.decodeIfPresent(ImageRoute.self, forKey: .imageRoute)) ?? .appDrawn
        automationDefault = (try? c.decodeIfPresent(AutomationLevel.self, forKey: .automationDefault)) ?? .approveEvery
        nameOverlap = (try? c.decodeIfPresent(NameOverlapThresholds.self, forKey: .nameOverlap)) ?? NameOverlapThresholds()
        defaultWriter = (try? c.decodeIfPresent(EngineID.self, forKey: .defaultWriter)) ?? .codex
        clearWorkingFilesAfterDays = try c.decodeIfPresent(Int.self, forKey: .clearWorkingFilesAfterDays)
        finishedFirstRun = try c.decodeIfPresent(Bool.self, forKey: .finishedFirstRun) ?? false
        caps = (try? c.decodeIfPresent(CostCaps.self, forKey: .caps)) ?? CostCaps()
        autoUpdateTools = (try? c.decodeIfPresent(Bool.self, forKey: .autoUpdateTools)) ?? true
        control = (try? c.decodeIfPresent(ControlSettings.self, forKey: .control)) ?? ControlSettings()
    }

    public func engine(_ id: EngineID) -> EngineSettings {
        engines[id.rawValue] ?? EngineSettings(plan: id.plans[0])
    }

    public mutating func setEngine(_ id: EngineID, _ value: EngineSettings) {
        engines[id.rawValue] = value
    }

    public func paths() -> AppPaths {
        AppPaths.standard(storageRoot: storagePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) })
    }
}

/// Loads and saves `settings.json`.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        do {
            var settings = try JSONCoding.decoder().decode(AppSettings.self, from: data)
            if settings.schemaVersion < AppSettings.currentSchemaVersion {
                settings.schemaVersion = AppSettings.currentSchemaVersion
            }
            return settings
        } catch {
            Log.shared.warning("settings.json could not be read, using defaults: \(error)")
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) throws {
        try AtomicFile.writeJSON(settings, to: url)
    }
}

/// A same-name channel is a small overlap when it is under this size and has not uploaded for this long.
public struct NameOverlapThresholds: Codable, Sendable, Equatable {
    public var maxSubscribers: Int
    public var minDaysSinceUpload: Int

    public init(maxSubscribers: Int = 1_000, minDaysSinceUpload: Int = 365) {
        self.maxSubscribers = maxSubscribers
        self.minDaysSinceUpload = minDaysSinceUpload
    }
}
