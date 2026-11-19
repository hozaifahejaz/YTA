import Foundation
import Support
import YouTubeData

/// The `.com` through RDAP, and the same handle on social sites from public pages.
/// Social answers are hints, never facts (section 7.3, step 5).
public struct WebPresence: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTP()) {
        self.http = http
    }

    /// Verisign's RDAP answers 404 for a `.com` nobody has registered.
    public func dotCom(_ name: String) async -> Hint {
        let label = NameRules.domainLabel(name)
        guard !label.isEmpty, let url = URL(string: "https://rdap.verisign.com/com/v1/domain/\(label).com") else { return .unknown }
        guard let response = try? await http.get(url, headers: ["Accept": "application/rdap+json"]) else { return .unknown }
        switch response.status {
        case 404: return .looksFree
        case 200: return .looksTaken
        default: return .unknown
        }
    }

    public func social(_ site: SocialSite, handle: String) async -> Hint {
        // Instagram and TikTok allow letters, digits, underscores and periods only.
        guard handle.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return .unknown }
        // X shows every profile through scripts, so a plain page says nothing.
        guard site != .x else { return .unknown }
        guard let response = try? await http.get(site.profileURL(handle), headers: [
            "Accept-Language": "en-US,en;q=0.8",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        ]) else { return .unknown }
        return Self.read(site, handle: handle, status: response.status, html: String(decoding: response.data, as: UTF8.self))
    }

    static func read(_ site: SocialSite, handle: String, status: Int, html: String) -> Hint {
        if status == 404 { return .looksFree }
        guard status == 200 else { return .unknown }
        let lowered = html.lowercased()
        let name = handle.lowercased()
        switch site {
        case .instagram:
            if lowered.contains("(@\(name))") || lowered.contains("\"username\":\"\(name)\"") { return .looksTaken }
            if lowered.contains("page isn't available") || lowered.contains("page not found") { return .looksFree }
        case .tiktok:
            if lowered.contains("\"uniqueid\":\"\(name)\"") { return .looksTaken }
            if lowered.contains("\"statuscode\":10221") || lowered.contains("\"statuscode\":10202")
                || lowered.contains("couldn't find this account") { return .looksFree }
        case .x:
            break
        }
        return .unknown
    }
}

/// Runs the checks of section 7.3, steps 2 to 5, on the LLM's ideas.
public struct NameChecker: Sendable {
    let youtube: YouTubeService
    let presence: WebPresence
    let thresholds: NameOverlapThresholds
    /// How many free-handle names get the same-name search, and how many cards to aim for.
    public var searched = 10
    public var maxSearched = 16
    public var cardCount = 8

    public init(youtube: YouTubeService, presence: WebPresence, thresholds: NameOverlapThresholds) {
        self.youtube = youtube
        self.presence = presence
        self.thresholds = thresholds
    }

    public func check(_ ideas: [NameIdea], progress: @Sendable (String) -> Void = { _ in }) async throws -> (candidates: [NameCandidate], shortlist: [String]) {
        var seen = Set<String>()
        let usable = ideas.filter { NameRules.problem(with: $0) == nil && seen.insert($0.handle.lowercased()).inserted }
        var candidates = usable.map(NameCandidate.init)

        // Step 2: every handle.
        for index in candidates.indices {
            try Task.checkCancellation()
            progress("Checking handle \(index + 1) of \(candidates.count): @\(candidates[index].idea.handle)")
            let result = try await youtube.checkHandle(candidates[index].idea.handle)
            candidates[index].handleStatus = result.status
            candidates[index].handleOwner = result.channel?.title
            candidates[index].source = result.source
            if result.status == .taken { candidates[index].label = .taken }
        }

        // Step 3 and 4: same-name channels for the best free ones, in the LLM's order,
        // until there are enough cards or the search budget is spent.
        var shortlist: [String] = []
        var searchedCount = 0
        for index in candidates.indices where candidates[index].handleStatus == .looksFree {
            if shortlist.count >= cardCount || searchedCount >= maxSearched { break }
            if searchedCount >= searched && shortlist.count >= 6 { break }
            try Task.checkCancellation()
            searchedCount += 1
            progress("Looking for channels called \(candidates[index].idea.name)")
            candidates[index].matches = try await youtube.searchChannels(candidates[index].idea.name)
            let label = NameRules.label(candidates[index], thresholds: thresholds)
            candidates[index].label = label
            if label != .taken { shortlist.append(candidates[index].idea.name) }
        }

        // Step 5: domain and social hints for the cards only.
        for index in candidates.indices where shortlist.contains(candidates[index].idea.name) {
            try Task.checkCancellation()
            progress("Checking \(candidates[index].dotCom) and social handles")
            candidates[index].domain = await presence.dotCom(candidates[index].idea.name)
            for site in SocialSite.allCases {
                candidates[index].socials[site.rawValue] = await presence.social(site, handle: candidates[index].idea.handle)
            }
        }

        // Clear before small overlap, then the LLM's order.
        let order = { (name: String) -> Int in
            candidates.first { $0.idea.name == name }?.label == .clear ? 0 : 1
        }
        shortlist = shortlist.enumerated().sorted { (order($0.element), $0.offset) < (order($1.element), $1.offset) }.map(\.element)
        return (candidates, shortlist)
    }

    /// Up to two free handle variants of the chosen handle.
    public func fallbacks(for handle: String) async -> [String] {
        var free: [String] = []
        for variant in NameRules.variants(of: handle) where free.count < 2 {
            if let result = try? await youtube.checkHandle(variant), result.status == .looksFree {
                free.append(variant)
            }
        }
        return free
    }
}
