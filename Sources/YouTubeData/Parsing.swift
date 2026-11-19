import Foundation

/// What the owner pasted: a handle, a channel link or a video link (section 7.8, step 1).
public enum ChannelLink: Equatable, Sendable {
    case handle(String)
    case channelID(String)
    case video(String)
    /// Old-style /c/name or /user/name links. Only the page can resolve them.
    case legacyName(String)

    public static func parse(_ input: String) -> ChannelLink? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("@") { return handleIfValid(String(text.dropFirst())) }
        if isChannelID(text) { return .channelID(text) }

        let withScheme = text.contains("://") ? text : "https://\(text)"
        if let url = URL(string: withScheme), let host = url.host?.lowercased(),
           host.hasSuffix("youtube.com") || host == "youtu.be" {
            let parts = url.path.split(separator: "/").map(String.init)
            if host == "youtu.be", let id = parts.first, isVideoID(id) { return .video(id) }
            guard let first = parts.first else { return nil }
            if first.hasPrefix("@") { return handleIfValid(String(first.dropFirst()).removingPercentEncoding ?? "") }
            switch first {
            case "channel": return parts.count > 1 && isChannelID(parts[1]) ? .channelID(parts[1]) : nil
            case "watch":
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
                return id.flatMap { isVideoID($0) ? .video($0) : nil }
            case "shorts", "live", "embed":
                return parts.count > 1 && isVideoID(parts[1]) ? .video(parts[1]) : nil
            case "c", "user": return parts.count > 1 ? .legacyName(parts[1]) : nil
            default: return nil
            }
        }
        // A bare word is taken as a handle.
        return handleIfValid(text)
    }

    /// Handles are 3 to 30 characters: letters, digits, underscores, hyphens and periods.
    public static func normalisedHandle(_ raw: String) -> String? {
        var handle = raw.trimmingCharacters(in: .whitespaces)
        if handle.hasPrefix("@") { handle.removeFirst() }
        guard (3...30).contains(handle.count),
              handle.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return nil }
        return handle
    }

    static func handleIfValid(_ raw: String) -> ChannelLink? {
        normalisedHandle(raw).map { .handle($0) }
    }

    static func isChannelID(_ text: String) -> Bool {
        text.count == 24 && text.hasPrefix("UC") && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

enum Parse {
    /// ISO 8601 durations as the API writes them, for example `PT1H2M3S` or `P1DT2H`.
    static func duration(_ text: String) -> Int? {
        guard text.hasPrefix("P") else { return nil }
        var total = 0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let value = Int(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", false): total += value * 604_800
            case ("D", false): total += value * 86_400
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
        }
        return number.isEmpty ? total : nil
    }

    /// Clock lengths from pages, for example `12:34` or `1:02:03`.
    static func clock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    /// Counts as pages write them: `1,234 views`, `1.2M subscribers`, `12K`, `No views`.
    /// Pages are requested in English so the suffixes are predictable.
    static func count(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("no ") { return 0 }
        let tokens = lowered.split(separator: " ")
        guard let token = tokens.first else { return nil }
        var digits = token.replacingOccurrences(of: ",", with: "")
        var multiplier = 1.0
        // Spoken labels: "47 million subscribers".
        if tokens.count > 1, let value = Double(digits) {
            switch tokens[1] {
            case "thousand": return Int((value * 1_000).rounded())
            case "million": return Int((value * 1_000_000).rounded())
            case "billion": return Int((value * 1_000_000_000).rounded())
            default: break
            }
        }
        switch digits.last {
        case "k": multiplier = 1_000; digits.removeLast()
        case "m": multiplier = 1_000_000; digits.removeLast()
        case "b": multiplier = 1_000_000_000; digits.removeLast()
        default: break
        }
        guard let value = Double(digits) else { return nil }
        return Int((value * multiplier).rounded())
    }

    /// Days since a relative date as pages write it: "3 weeks ago", "Streamed 2 years ago".
    static func ageDays(_ text: String) -> Int? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard let agoIndex = words.firstIndex(of: "ago"), agoIndex >= 2,
              let value = Int(words[agoIndex - 2]) else { return nil }
        let unit = words[agoIndex - 1]
        let days: Double
        switch true {
        case unit.hasPrefix("second"), unit.hasPrefix("minute"), unit.hasPrefix("hour"): days = 0
        case unit.hasPrefix("day"): days = 1
        case unit.hasPrefix("week"): days = 7
        case unit.hasPrefix("month"): days = 30.4
        case unit.hasPrefix("year"): days = 365
        default: return nil
        }
        return Int((Double(value) * days).rounded())
    }

    static func int(_ text: String?) -> Int? {
        text.flatMap { Int($0) }
    }

    nonisolated(unsafe) static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let isoDateFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return isoDate.date(from: text) ?? isoDateFractional.date(from: text)
    }

    /// Splits the channel keywords string. Quoted phrases stay together.
    static func keywords(_ text: String?) -> [String] {
        guard let text else { return [] }
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle(); continue }
            if character == " " && !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
