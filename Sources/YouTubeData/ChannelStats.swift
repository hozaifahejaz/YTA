import Foundation

/// Numbers the app works out from a snapshot for the import analysis (section 7.8, step 3).
public struct ChannelStats: Codable, Equatable, Sendable {
    public struct Winner: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var views: Int
        /// Views divided by the median of the same kind (long-form or Shorts).
        public var multiple: Double
        public var minutes: Double?
        public var ageDays: Int?
        public var short: Bool
        public var thumbnailURL: String?
    }

    public var videoCount: Int
    public var longMedianViews: Int?
    public var shortsMedianViews: Int?
    public var shortsShare: Double?
    public var typicalMinutes: Double?
    /// Uploads in each of the last six 30-day periods, newest first.
    public var uploadsByMonth: [Int]
    /// Uploads per weekday (Monday first), when dates are known.
    public var weekdays: [Int]?
    public var daysSinceLastUpload: Int?
    public var winners: [Winner]

    public static func compute(_ snapshot: ChannelSnapshot) -> ChannelStats {
        let now = snapshot.takenAt
        func age(_ video: YouTubeVideo) -> Int? {
            if let date = video.publishedAt { return max(0, Int(now.timeIntervalSince(date) / 86_400)) }
            return video.publishedText.flatMap(Parse.ageDays)
        }
        let videos = snapshot.videos
        let long = videos.filter { $0.isShort != true }
        let shorts = videos.filter { $0.isShort == true }
        let longMedian = NicheMeasures.median(long.compactMap(\.viewCount))
        let shortsMedian = NicheMeasures.median(shorts.compactMap(\.viewCount))

        var months = Array(repeating: 0, count: 6)
        for video in videos {
            guard let days = age(video), days < 180 else { continue }
            months[days / 30] += 1
        }

        var weekdays: [Int]?
        let dated = videos.compactMap(\.publishedAt)
        if !dated.isEmpty {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            var counts = Array(repeating: 0, count: 7)
            for date in dated { counts[(calendar.component(.weekday, from: date) + 5) % 7] += 1 }
            weekdays = counts
        }

        var winners: [Winner] = []
        for video in videos {
            guard let views = video.viewCount else { continue }
            let short = video.isShort == true
            guard let median = short ? shortsMedian : longMedian, median > 0 else { continue }
            let multiple = Double(views) / Double(median)
            guard multiple >= 2 else { continue }
            winners.append(Winner(id: video.id, title: video.title, views: views, multiple: (multiple * 10).rounded() / 10,
                                  minutes: video.durationSeconds.map { (Double($0) / 6).rounded() / 10 }, ageDays: age(video),
                                  short: short, thumbnailURL: video.thumbnailURL))
        }
        winners.sort { $0.multiple > $1.multiple }

        let timed = videos.filter { $0.durationSeconds != nil }
        return ChannelStats(
            videoCount: videos.count, longMedianViews: longMedian, shortsMedianViews: shortsMedian,
            shortsShare: timed.isEmpty ? nil : Double(timed.filter { $0.isShort == true }.count) / Double(timed.count),
            typicalMinutes: NicheMeasures.median(long.compactMap(\.durationSeconds)).map { Double($0) / 60 },
            uploadsByMonth: months, weekdays: weekdays,
            daysSinceLastUpload: videos.compactMap(age).min(),
            winners: Array(winners.prefix(15)))
    }

    /// Plain lines for the analysis prompt.
    public var summary: String {
        var lines = ["Videos in the snapshot: \(videoCount)"]
        if let value = longMedianViews { lines.append("Median views, long-form: \(value)") }
        if let value = shortsMedianViews { lines.append("Median views, Shorts: \(value)") }
        if let value = shortsShare { lines.append("Share of Shorts: \(Int((value * 100).rounded()))%") }
        if let value = typicalMinutes { lines.append(String(format: "Typical long-form length: %.0f minutes", value)) }
        lines.append("Uploads in each of the last six 30-day periods, newest first: \(uploadsByMonth.map(String.init).joined(separator: ", "))")
        if let weekdays {
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            lines.append("Uploads by weekday: " + zip(names, weekdays).map { "\($0) \($1)" }.joined(separator: ", "))
        }
        if let days = daysSinceLastUpload { lines.append("Days since the last upload: \(days)") }
        return lines.joined(separator: "\n")
    }
}
