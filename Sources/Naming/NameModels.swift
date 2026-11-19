import Foundation
import Support
import YouTubeData

/// One idea from the LLM (section 7.3, step 1).
public struct NameIdea: Codable, Equatable, Sendable {
    public var name: String
    public var handle: String
    public var why: String

    public init(name: String, handle: String, why: String = "") {
        self.name = name
        self.handle = handle
        self.why = why
    }
}

/// Free, taken or "can't tell" for checks that read public pages.
public enum Hint: String, Codable, Sendable {
    case looksFree
    case looksTaken
    case unknown

    public var title: String {
        switch self {
        case .looksFree: "Looks free"
        case .looksTaken: "Looks taken"
        case .unknown: "Unknown"
        }
    }
}

public enum NameLabel: String, Codable, Sendable {
    case clear
    /// Only small, quiet channels share the name.
    case smallOverlap
    /// The handle is taken or an active channel uses the name. Dropped from the cards.
    case taken

    public var title: String {
        switch self {
        case .clear: "Clear"
        case .smallOverlap: "Small overlap"
        case .taken: "Taken"
        }
    }
}

public enum SocialSite: String, Codable, Sendable, CaseIterable {
    case instagram, tiktok, x

    public var title: String {
        switch self {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .x: "X"
        }
    }

    public func profileURL(_ handle: String) -> URL {
        switch self {
        case .instagram: URL(string: "https://www.instagram.com/\(handle)/")!
        case .tiktok: URL(string: "https://www.tiktok.com/@\(handle)")!
        case .x: URL(string: "https://x.com/\(handle)")!
        }
    }
}

/// An idea with everything the app found out about it.
public struct NameCandidate: Codable, Equatable, Sendable {
    public var idea: NameIdea
    public var handleStatus: HandleCheck.Status?
    /// The channel that already has the handle, if any.
    public var handleOwner: String?
    /// Nil when the name was not searched (only the best are).
    public var matches: [ChannelMatch]?
    public var label: NameLabel?
    public var domain: Hint
    public var socials: [String: Hint]
    public var source: DataSource?

    public init(idea: NameIdea) {
        self.idea = idea
        self.domain = .unknown
        self.socials = [:]
    }

    public var dotCom: String { NameRules.domainLabel(idea.name) + ".com" }
}

/// `brand/name.json`.
public struct NameFile: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var round: Int
    public var note: String?
    public var generatedAt: Date
    public var candidates: [NameCandidate]
    /// The names shown as cards, best first.
    public var shortlist: [String]
    public var chosen: String?
    public var handle: String?
    /// A handle is only confirmed when claimed, so the kit carries two more.
    public var fallbackHandles: [String]
    public var thresholds: NameOverlapThresholds

    public init(round: Int, note: String?, generatedAt: Date, candidates: [NameCandidate], shortlist: [String],
                thresholds: NameOverlapThresholds) {
        self.round = round
        self.note = note
        self.generatedAt = generatedAt
        self.candidates = candidates
        self.shortlist = shortlist
        self.chosen = nil
        self.handle = nil
        self.fallbackHandles = []
        self.thresholds = thresholds
    }

    public var cards: [NameCandidate] {
        shortlist.compactMap { name in candidates.first { $0.idea.name == name } }
    }

    /// Records the owner's pick and the fallback handles checked for it.
    public func choosing(_ name: String, fallbacks: [String]) throws -> NameFile {
        guard let pick = candidates.first(where: { $0.idea.name == name }) else {
            throw YTAError(.notFound, "\(name) is not one of the names.")
        }
        var copy = self
        copy.chosen = pick.idea.name
        copy.handle = pick.idea.handle
        copy.fallbackHandles = Array(fallbacks.prefix(2))
        return copy
    }

    public static func trademarkSearchURL(_ name: String) -> URL {
        var components = URLComponents(string: "https://tmsearch.uspto.gov/search/search-results")!
        components.queryItems = [URLQueryItem(name: "query", value: name)]
        return components.url!
    }
}
