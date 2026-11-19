import Foundation
import Support

/// Unit costs of the YouTube Data API v3 calls YTA makes.
/// Every list call costs 1 unit; a search costs 100.
public enum QuotaCost {
    public static let list = 1
    public static let search = 100
}

/// What has been spent today, for display and for the pre-run check.
public struct QuotaUsage: Equatable, Sendable {
    public let used: Int
    public let limit: Int
    public let searches: Int
    public let exhausted: Bool
    public let resetsAt: Date

    public var remaining: Int { exhausted ? 0 : max(0, limit - used) }
    public var searchesLeft: Int { remaining / QuotaCost.search }
}

/// Persists YouTube API units used today in `quota.json` (section 4.1).
/// The day follows Pacific time, because that is when Google resets the quota.
public final class QuotaLedger: @unchecked Sendable {
    struct Stored: Codable, Equatable {
        var schemaVersion = 1
        var day: String
        var units = 0
        var searches = 0
        /// Set when Google answered "quota exceeded" even though our count said otherwise.
        var exhausted = false
    }

    public static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private let file: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    public var dailyLimit: Int

    public init(file: URL, dailyLimit: Int = 10_000, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.dailyLimit = dailyLimit
        self.now = now
    }

    public static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// The next midnight in Pacific time after `date`.
    public static func nextReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start)!
    }

    public func usage() -> QuotaUsage {
        lock.withLock {
            let stored = current()
            return QuotaUsage(used: stored.units, limit: dailyLimit, searches: stored.searches,
                              exhausted: stored.exhausted, resetsAt: Self.nextReset(after: now()))
        }
    }

    /// Whether a run that needs this many calls can finish today.
    public func canFinish(searches: Int, lists: Int) -> Bool {
        usage().remaining >= searches * QuotaCost.search + lists * QuotaCost.list
    }

    /// Takes units before a request is sent. Google charges failed requests too.
    public func spend(_ units: Int) throws {
        try lock.withLock {
            var stored = current()
            guard !stored.exhausted, stored.units + units <= dailyLimit else {
                throw exhaustedError()
            }
            stored.units += units
            if units >= QuotaCost.search { stored.searches += 1 }
            try save(stored)
        }
    }

    /// Google said the quota is used up. Nothing more is sent until the reset.
    public func markExhausted() {
        lock.withLock {
            var stored = current()
            stored.exhausted = true
            try? save(stored)
        }
    }

    public func exhaustedError() -> YTAError {
        YTAError(.quotaExhausted, "Today's YouTube API quota is used up.", resetsAt: Self.nextReset(after: now()))
    }

    private func current() -> Stored {
        let today = Self.dayKey(for: now())
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONCoding.decoder().decode(Stored.self, from: data),
           stored.day == today {
            return stored
        }
        return Stored(day: today)
    }

    private func save(_ stored: Stored) throws {
        try AtomicFile.writeJSON(stored, to: file)
    }
}
