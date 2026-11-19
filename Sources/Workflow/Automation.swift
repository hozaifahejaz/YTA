import ChannelStore
import Engines
import Foundation
import Support

// MARK: Automation dial (section 5.9)

public enum AutomationPolicy {
    /// Steps that still stop for the owner when the dial says "approve only script and final cut".
    public static let keySteps: Set<String> = ["script", "ownScript", "cutReview"]

    /// Whether a run waits for the owner. Channel setup keeps its own approvals: it runs once and its choices
    /// (name, brand, voice) belong to the owner. Video steps follow the dial. The final check is never skipped,
    /// because it is a check, not an approval.
    public static func needsApproval(type: String, approval: ApprovalRule, automation: AutomationLevel, inVideo: Bool) -> Bool {
        if approval == .never { return false }
        guard inVideo else { return approval == .always || automation == .approveEvery }
        switch automation {
        case .approveEvery: return true
        case .approveKey: return keySteps.contains(type)
        case .straightThrough: return false
        }
    }
}

// MARK: Usage and spend

/// Each engine call's usage inside a run, in `usage.json` in the run folder.
public enum UsageLog {
    public static func append(_ usage: RunUsage?, run: RunRecord, folder: ChannelFolder) {
        guard let usage else { return }
        let path = "\(run.folder)/usage.json"
        var all = (try? folder.readJSON([RunUsage].self, path)) ?? []
        all.append(usage)
        try? folder.writeJSON(all, to: path)
    }

    public static func costUSD(run: RunRecord, folder: ChannelFolder) -> Double {
        ((try? folder.readJSON([RunUsage].self, "\(run.folder)/usage.json")) ?? []).compactMap(\.costUSD).reduce(0, +)
    }
}

/// What the app has spent, across channels: `spend.json` in Application Support.
public struct SpendLedger: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var channelID: String
        public var videoID: String?
        public var runID: String
        public var usd: Double
        public var voiceCharacters: Int

        public init(date: Date, channelID: String, videoID: String?, runID: String, usd: Double, voiceCharacters: Int) {
            self.date = date
            self.channelID = channelID
            self.videoID = videoID
            self.runID = runID
            self.usd = usd
            self.voiceCharacters = voiceCharacters
        }
    }

    public struct Totals: Equatable, Sendable {
        public var usd: Double = 0
        public var voiceCharacters = 0
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONCoding.decoder().decode([Entry].self, from: data)) ?? []
    }

    /// Adds a run's spend once; a run recorded again replaces its earlier entry.
    public func record(_ entry: Entry) throws {
        guard entry.usd > 0 || entry.voiceCharacters > 0 else { return }
        var all = entries().filter { $0.runID != entry.runID }
        all.append(entry)
        // Ninety days is plenty for daily caps and the Settings summary.
        let cutoff = entry.date.addingTimeInterval(-90 * 86_400)
        all.removeAll { $0.date < cutoff }
        try AtomicFile.writeJSON(all, to: url)
    }

    public func totals(videoID: String) -> Totals {
        sum(entries().filter { $0.videoID == videoID })
    }

    public func totals(dayOf date: Date, calendar: Calendar = .current) -> Totals {
        sum(entries().filter { calendar.isDate($0.date, inSameDayAs: date) })
    }

    private func sum(_ entries: [Entry]) -> Totals {
        entries.reduce(into: Totals()) { totals, entry in
            totals.usd += entry.usd
            totals.voiceCharacters += entry.voiceCharacters
        }
    }

    /// Why the queue must stop before more work on this video, or nil when every cap still has room.
    public func capReached(_ caps: CostCaps, videoID: String?, at date: Date = Date()) -> String? {
        let day = totals(dayOf: date)
        if let cap = caps.perDayUSD, day.usd >= cap {
            return String(format: "Today's engine spend reached the $%.2f daily cap.", cap)
        }
        if let cap = caps.perDayVoiceCharacters, day.voiceCharacters >= cap {
            return "Today's narration reached the \(cap.formatted()) character daily cap."
        }
        guard let videoID else { return nil }
        let video = totals(videoID: videoID)
        if let cap = caps.perVideoUSD, video.usd >= cap {
            return String(format: "This video's engine spend reached the $%.2f cap per video.", cap)
        }
        if let cap = caps.perVideoVoiceCharacters, video.voiceCharacters >= cap {
            return "This video's narration reached the \(cap.formatted()) character cap per video."
        }
        return nil
    }
}

// MARK: Estimate before each video

public struct VideoEstimate: Equatable, Sendable {
    public var words: Int
    /// Characters sent to ai33pro, from the target length. ai33pro bills characters; [VERIFY] its credit rate.
    public var voiceCharacters: Int
    /// Steps that call an LLM tool, and the most they can cost at each run's budget cap.
    public var engineSteps: Int
    public var maxEngineUSD: Double
    /// AI images, only when the editing style fills empty shots with them.
    public var maxImageGenerations: Int

    /// Average characters per spoken word including the space, for English narration.
    public static let charactersPerWord = 6.0
    public static let budgetPerRun = 2.0

    public static func make(_ video: VideoFile, style: ScriptStyle, editing: EditingStyle) -> VideoEstimate {
        let words = style.targetWords(video.settings)
        let steps = video.row.nodes.filter { node in
            guard let recipe = NodeRecipes.recipe(for: node) else { return false }
            if node.type == "researchNotes", !video.settings.researchNotes { return false }
            return recipe.usesEngine || ["topicResearch", "media", "kit", "voice"].contains(node.type)
        }.count
        // Roughly one shot every 5 seconds of narration.
        let shots = Int((Double(words) / style.speakingRate * 60 / 5).rounded(.up))
        return VideoEstimate(
            words: words,
            voiceCharacters: Int(Double(words) * charactersPerWord),
            engineSteps: steps,
            maxEngineUSD: Double(steps) * budgetPerRun * 2,
            maxImageGenerations: editing.filler == .aiImage ? shots : 0)
    }

    public var summary: String {
        var parts = ["about \(words.formatted()) words", "about \(voiceCharacters.formatted()) narration characters",
                     "\(engineSteps) tool steps"]
        if maxImageGenerations > 0 { parts.append("up to \(maxImageGenerations) AI images") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Disk

public enum WorkingFiles {
    /// Folders inside a video's Working files that can be rebuilt or are no longer needed once it is finished.
    public static let clearable = ["media", "render", "audio/beats"]
    static let bulkyExtensions: Set<String> = ["mp4", "mov", "wav", "mp3", "m4a", "avi", "jpg", "jpeg", "png", "webp", "gif"]

    /// Clears bulky working files of videos finished more than `days` ago. The ledger, script, timeline, kit,
    /// timings and the finished video are never touched. Returns the bytes freed.
    @discardableResult
    public static func clear(folder: ChannelFolder, olderThanDays days: Int, at date: Date = Date()) throws -> Int64 {
        let store = VideoStore(folder: folder)
        let runs = RunStore(folder: folder).all()
        var freed: Int64 = 0
        for var video in store.all() {
            guard video.workingFilesClearedAt == nil, let finished = video.finishedAt,
                  date.timeIntervalSince(finished) >= Double(days) * 86_400 else { continue }
            for relative in clearable {
                let url = try folder.url(video.path(relative))
                freed += size(of: url)
                try? FileManager.default.removeItem(at: url)
            }
            let nodeIDs = Set(video.row.nodes.map(\.id))
            for run in runs where nodeIDs.contains(run.nodeID) {
                let runFolder = try folder.url(run.folder)
                guard let files = FileManager.default.enumerator(at: runFolder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
                for case let file as URL in files where bulkyExtensions.contains(file.pathExtension.lowercased()) {
                    freed += size(of: file)
                    try? FileManager.default.removeItem(at: file)
                }
            }
            video.workingFilesClearedAt = date
            try store.save(video)
        }
        return freed
    }

    public static func size(of url: URL) -> Int64 {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        if !isFolder.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
