import Foundation
import Support
import YouTubeData

/// The written rules of section 7.3, as code.
public enum NameRules {
    /// Why an idea breaks the rules, or nil when it is fine. Breaking ideas are dropped.
    public static func problem(with idea: NameIdea) -> String? {
        let name = idea.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "empty" }
        if name.split(separator: " ").count > 2 { return "more than two words" }
        if name.contains(where: \.isNumber) { return "has digits" }
        if name.contains("-") { return "has a hyphen" }
        if name.count > 24 { return "too long" }
        guard let handle = ChannelLink.normalisedHandle(idea.handle) else { return "handle is not valid" }
        if handle.contains(where: \.isNumber) || handle.contains("-") { return "handle has digits or hyphens" }
        return nil
    }

    /// Lowercase letters and digits only, for comparing names.
    public static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func domainLabel(_ name: String) -> String {
        squash(name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")))
    }

    /// Same name, or one letter off for names of five letters or more.
    public static func isNear(_ a: String, _ b: String) -> Bool {
        let x = squash(a), y = squash(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        return min(x.count, y.count) >= 5 && editDistance(x, y) <= 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }

    /// Labels a searched candidate (section 7.3, step 4).
    public static func label(_ candidate: NameCandidate, thresholds: NameOverlapThresholds) -> NameLabel {
        if candidate.handleStatus == .taken { return .taken }
        let near = (candidate.matches ?? []).filter {
            isNear($0.title, candidate.idea.name) || ($0.handle.map { isNear($0, candidate.idea.handle) } ?? false)
        }
        if near.isEmpty { return .clear }
        let allSmall = near.allSatisfy { match in
            guard let subscribers = match.subscriberCount, subscribers < thresholds.maxSubscribers else { return false }
            // No known upload counts as quiet.
            return (match.lastUploadDays ?? Int.max) >= thresholds.minDaysSinceUpload
        }
        return allSmall ? .smallOverlap : .taken
    }

    /// Handle variants to try as fallbacks for the chosen name.
    public static func variants(of handle: String) -> [String] {
        ["\(handle)tv", "the\(handle)", "\(handle)hq", "\(handle)official", "\(handle)channel"]
            .filter { ChannelLink.normalisedHandle($0) != nil }
    }
}
