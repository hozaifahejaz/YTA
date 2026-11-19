import Foundation
import Support

public enum ChannelFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case longForm
    case shorts
    case both

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .longForm: "Long-form"
        case .shorts: "Shorts"
        case .both: "Long-form and Shorts"
        }
    }
}

public enum ChannelStatus: String, Codable, Sendable, CaseIterable {
    case settingUp
    case active
    case paused
    case archived

    public var title: String {
        switch self {
        case .settingUp: "Setting up"
        case .active: "Active"
        case .paused: "Paused"
        case .archived: "Archived"
        }
    }
}

public enum ChannelOrigin: String, Codable, Sendable {
    /// Started in YTA from a niche.
    case new
    /// An existing YouTube channel brought in (section 7.8).
    case imported
}

/// `channel.json`.
public struct ChannelManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var handle: String?
    public var format: ChannelFormat
    public var language: String
    public var country: String?
    public var status: ChannelStatus
    public var origin: ChannelOrigin
    /// For imported channels: the handle or link the owner gave.
    public var importLink: String?
    /// Sidebar group, since channels are unlimited.
    public var group: String?
    public var automation: AutomationLevel
    /// Engine choices that override the app defaults for this channel, keyed by role (for example "writer").
    public var engines: [String: String]
    public var createdAt: Date

    public init(
        id: String = Identifier.make(prefix: "ch"),
        name: String,
        handle: String? = nil,
        format: ChannelFormat = .longForm,
        language: String = "English",
        country: String? = nil,
        status: ChannelStatus = .settingUp,
        origin: ChannelOrigin = .new,
        importLink: String? = nil,
        group: String? = nil,
        automation: AutomationLevel = .approveEvery,
        engines: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.handle = handle
        self.format = format
        self.language = language
        self.country = country
        self.status = status
        self.origin = origin
        self.importLink = importLink
        self.group = group
        self.automation = automation
        self.engines = engines
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, handle, format, language, country, status, origin, importLink, group, automation, engines, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        format = (try? c.decodeIfPresent(ChannelFormat.self, forKey: .format)) ?? .longForm
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "English"
        country = try c.decodeIfPresent(String.self, forKey: .country)
        status = (try? c.decodeIfPresent(ChannelStatus.self, forKey: .status)) ?? .settingUp
        origin = (try? c.decodeIfPresent(ChannelOrigin.self, forKey: .origin)) ?? .new
        importLink = try c.decodeIfPresent(String.self, forKey: .importLink)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        automation = (try? c.decodeIfPresent(AutomationLevel.self, forKey: .automation)) ?? .approveEvery
        engines = try c.decodeIfPresent([String: String].self, forKey: .engines) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// `profile/sources.json`: which production sources the channel may use.
public struct SourcesConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var stockFootage: Bool = true
    public var aiImages: Bool = true
    public var aiVideo: Bool = false
    public var freeOnlineMedia: Bool = true
    public var screenshotsAndSnippets: Bool = true
    public var aiVoice: Bool = true
    /// Off by default. When on, the rules file says such media needs commentary or transformation.
    public var fairUse: Bool = false
    /// CC BY-SA carries a share-alike condition, so a channel can switch it off.
    public var allowShareAlike: Bool = true

    public init() {}
}
