import ChannelStore
import Engines
import Foundation
import Support

// MARK: Video file

public enum VideoStatus: String, Codable, Sendable, CaseIterable {
    case queued, working, paused, skipped, done, published
    public var title: String { rawValue.capitalized }
}

/// Per-video settings (section 8.1 and 8.2).
public struct VideoSettings: Codable, Equatable, Sendable {
    /// Target length; words win when both are set.
    public var minutes: Double?
    public var words: Int?
    public var short: Bool
    public var researchNotes: Bool
    public var guidelines: String

    public init(minutes: Double? = nil, words: Int? = nil, short: Bool = false, researchNotes: Bool = true, guidelines: String = "") {
        self.minutes = minutes
        self.words = words
        self.short = short
        self.researchNotes = researchNotes
        self.guidelines = guidelines
    }
}

/// `videos/<Title>/Working files/video.json`. Identity is `id`, never the folder name (section 4.3).
public struct VideoFile: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion = 1
    public var id: String
    public var title: String
    public var titleHistory: [String]
    public var folderName: String
    public var previousFolderNames: [String]
    public var status: VideoStatus
    /// The owner wrote the script. It is never changed.
    public var ownScript: Bool
    public var topic: String?
    public var settings: VideoSettings
    public var row: NodeList
    public var createdAt: Date
    /// The credits page link the owner pasted, or nil while it is pending (section 8.5).
    public var creditsLink: String?
    public var finishedAt: Date?
    public var publishedURL: String?
    public var publishedAt: Date?

    public var working: String { "\(ChannelLayout.videos)/\(folderName)/\(VideoStore.workingFolder)" }
    public func path(_ relative: String) -> String { "\(working)/\(relative)" }
}

/// `styles/script.json`: the channel's script defaults.
public struct ScriptStyle: Codable, Equatable, Sendable {
    public static let path = "styles/script.json"
    public var schemaVersion = 1
    /// Words a minute; recalibrated from real narration after the first video.
    public var speakingRate: Double = 150
    public var defaultMinutes: Double = 10
    public var shortSeconds: Double = 50
    public var tolerance: Double = 0.05
    /// The writer for new videos.
    public var writer: EngineID = .codex
    public var researchNotes = true
    /// The voice whose first narration set `speakingRate`; nil until then.
    public var calibratedFrom: String?

    public init() {}

    public static func load(_ folder: ChannelFolder) -> ScriptStyle {
        (try? folder.readJSON(ScriptStyle.self, path)) ?? ScriptStyle()
    }

    public func targetWords(_ settings: VideoSettings) -> Int {
        if let words = settings.words, words > 0 { return words }
        if settings.short { return Int((shortSeconds / 60 * speakingRate).rounded()) }
        return Int(((settings.minutes ?? defaultMinutes) * speakingRate).rounded())
    }
}

// MARK: Store

/// The channel's videos and its queue (section 8.1). The queue runs top to bottom.
public struct VideoStore: Sendable {
    public static let workingFolder = "Working files"
    public static let file = "video.json"
    public let folder: ChannelFolder

    public init(folder: ChannelFolder) {
        self.folder = folder
    }

    func queue() -> QueueFile {
        (try? folder.readJSON(QueueFile.self, ChannelLayout.queue)) ?? QueueFile()
    }

    func saveQueue(_ queue: QueueFile) throws {
        try folder.writeJSON(queue, to: ChannelLayout.queue)
    }

    /// Every video in queue order. Videos missing from the queue come last.
    public func all() -> [VideoFile] {
        guard let url = try? folder.url(ChannelLayout.videos),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        let videos = names.compactMap { try? folder.readJSON(VideoFile.self, "\(ChannelLayout.videos)/\($0)/\(Self.workingFolder)/\(Self.file)") }
        let order = queue().items.map(\.id)
        return videos.sorted { a, b in
            (order.firstIndex(of: a.id) ?? .max, a.createdAt) < (order.firstIndex(of: b.id) ?? .max, b.createdAt)
        }
    }

    public func video(_ id: String) -> VideoFile? { all().first { $0.id == id } }

    public func video(containing nodeID: String) -> VideoFile? { all().first { $0.row[nodeID] != nil } }

    public func save(_ video: VideoFile) throws {
        try folder.writeJSON(video, to: video.path(Self.file))
        var queue = queue()
        if let index = queue.items.firstIndex(where: { $0.id == video.id }) {
            queue.items[index].status = video.status.rawValue
        } else {
            queue.items.append(QueueFile.Item(id: video.id, status: video.status.rawValue))
        }
        try saveQueue(queue)
    }

    /// Adds a video: title only, title with the owner's script, or a researched topic.
    @discardableResult
    public func add(title: String, script: String? = nil, topic: String? = nil, settings: VideoSettings? = nil) throws -> VideoFile {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw YTAError(.checkFailed, "A video needs a title.") }
        let parent = try folder.url(ChannelLayout.videos)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let name = SafeName.uniqueFolderName(for: clean, in: parent)
        let style = ScriptStyle.load(folder)
        let own = !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var settings = settings ?? VideoSettings(minutes: style.defaultMinutes, researchNotes: style.researchNotes)
        if own { settings.researchNotes = false }
        let video = VideoFile(id: Identifier.make(prefix: "v"), title: clean, titleHistory: [clean], folderName: name,
                              previousFolderNames: [], status: .queued, ownScript: own, topic: topic, settings: settings,
                              row: Self.row(own: own, template: WorkflowStore(folder: folder).videoTemplate(), writer: style.writer),
                              createdAt: Date())
        if let script, own { try folder.writeText(script, to: video.path("script.md"), source: "your script") }
        try save(video)
        return video
    }

    /// The row for a new video: the channel's template, with the owner's-script steps when there is one.
    static func row(own: Bool, template: NodeList?, writer: EngineID) -> NodeList {
        var nodes = (template ?? DefaultRows.videoRow()).nodes.map { node -> Node in
            var copy = node
            copy.id = Identifier.make(prefix: "n")
            copy.state = .waiting
            copy.resultSummary = nil
            if copy.type == "script" { copy.engine = EngineChoice(tool: writer) }
            return copy
        }
        if own {
            nodes.removeAll { ["researchNotes", "prompt", "script"].contains($0.type) }
            if let index = nodes.firstIndex(where: { $0.type == "brief" }), let type = NodeRegistry.type("ownScript") {
                nodes.insert(Node(type), at: index + 1)
            }
        }
        return NodeList(kind: .video, nodes: nodes)
    }

    /// Bulk add from a pasted list or a `.csv` (first column, header skipped when it says "title").
    @discardableResult
    public func addMany(_ titles: [String]) throws -> [VideoFile] {
        try titles.map { try add(title: $0) }
    }

    public static func titles(fromList text: String, csv: Bool) -> [String] {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if csv {
            lines = lines.map { line in
                if line.hasPrefix("\"") {
                    let body = line.dropFirst()
                    var result = ""
                    var index = body.startIndex
                    while index < body.endIndex {
                        let char = body[index]
                        let next = body.index(after: index)
                        if char == "\"" {
                            if next < body.endIndex, body[next] == "\"" { result.append("\""); index = body.index(after: next); continue }
                            break
                        }
                        result.append(char)
                        index = next
                    }
                    return result
                }
                return String(line.split(separator: ",", omittingEmptySubsequences: false).first ?? "")
            }
            if let first = lines.first, first.lowercased() == "title" { lines.removeFirst() }
        } else {
            lines = lines.map { line in
                var text = line
                for prefix in ["- ", "* ", "• "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
                if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty {
                    text = String(text[text.index(after: dot)...])
                }
                return text.trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    // MARK: Queue order and status

    public func move(_ id: String, to position: Int) throws {
        var queue = queue()
        for video in all() where !queue.items.contains(where: { $0.id == video.id }) {
            queue.items.append(QueueFile.Item(id: video.id, status: video.status.rawValue))
        }
        guard let from = queue.items.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.items.remove(at: from)
        queue.items.insert(item, at: max(0, min(position, queue.items.count)))
        try saveQueue(queue)
    }

    public func setStatus(_ id: String, _ status: VideoStatus) throws {
        guard var video = video(id) else { throw YTAError(.notFound, "That video is not in this channel.") }
        video.status = status
        try save(video)
    }

    public func update(_ id: String, _ change: (inout VideoFile) throws -> Void) throws {
        guard var video = video(id) else { throw YTAError(.notFound, "That video is not in this channel.") }
        try change(&video)
        try save(video)
    }

    /// The next video the queue should work on: the first that is queued or working.
    public func next() -> VideoFile? {
        all().first { $0.status == .working || $0.status == .queued }
    }

    /// Renames the folder to match a new title and records the old names (section 4.3).
    public func retitle(_ id: String, to title: String) throws -> VideoFile {
        guard var video = video(id) else { throw YTAError(.notFound, "That video is not in this channel.") }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != video.title else { return video }
        let parent = try folder.url(ChannelLayout.videos)
        let newName = SafeName.folderName(for: clean) == video.folderName ? video.folderName
            : SafeName.uniqueFolderName(for: clean, in: parent)
        if newName != video.folderName {
            try FileManager.default.moveItem(at: parent.appendingPathComponent(video.folderName), to: parent.appendingPathComponent(newName))
            let oldVideo = parent.appendingPathComponent(newName).appendingPathComponent("\(video.folderName).mp4")
            if FileManager.default.fileExists(atPath: oldVideo.path) {
                try FileManager.default.moveItem(at: oldVideo, to: parent.appendingPathComponent(newName).appendingPathComponent("\(newName).mp4"))
            }
            video.previousFolderNames.append(video.folderName)
            video.folderName = newName
        }
        video.title = clean
        video.titleHistory.append(clean)
        try save(video)
        return video
    }

    // MARK: Node state

    /// Sets a node's state in whichever row holds it: the setup row or a video's row.
    public static func setState(_ nodeID: String, _ state: NodeState, summary: String?, folder: ChannelFolder) throws {
        let workflow = WorkflowStore(folder: folder)
        if var row = workflow.setupRow(), row[nodeID] != nil {
            row.setState(nodeID, state, summary: summary)
            if summary == nil, let i = row.index(of: nodeID) { row.nodes[i].resultSummary = nil }
            try workflow.saveSetupRow(row)
            return
        }
        let store = VideoStore(folder: folder)
        guard var video = store.video(containing: nodeID) else { return }
        video.row.setState(nodeID, state, summary: summary)
        if summary == nil, let i = video.row.index(of: nodeID) { video.row.nodes[i].resultSummary = nil }
        if state == .running, video.status == .queued { video.status = .working }
        if video.row.nodes.allSatisfy({ $0.state == .done }) { video.status = .done }
        try store.save(video)
    }
}
