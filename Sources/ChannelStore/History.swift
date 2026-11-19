import Foundation
import Support

/// One saved version of an instruction file.
public struct HistorySnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    /// The file's path inside the channel, for example `profile/voice.md`.
    public let file: String
    public let date: Date
    /// What made the change: a node title, "restore", "outside edit" or "original".
    public let source: String
    public let url: URL
}

/// Plain-copy history for instruction files, kept in `.history/` (section 5.7).
struct HistoryStore: Sendable {
    let channelRoot: URL

    private var historyRoot: URL { channelRoot.appendingPathComponent(ChannelLayout.history, isDirectory: true) }

    private func folder(for file: String) -> URL {
        historyRoot.appendingPathComponent(file, isDirectory: true)
    }

    func snapshots(for file: String) -> [HistorySnapshot] {
        let dir = folder(for: file)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> HistorySnapshot? in
            // name: <millis>__<source>.snap
            guard name.hasSuffix(".snap") else { return nil }
            let stem = String(name.dropLast(5))
            let parts = stem.components(separatedBy: "__")
            guard parts.count >= 2, let millis = Double(parts[0]) else { return nil }
            let source = parts.dropFirst().joined(separator: "__").replacingOccurrences(of: "_", with: " ")
            return HistorySnapshot(
                id: "\(file)#\(parts[0])",
                file: file,
                date: Date(timeIntervalSince1970: millis / 1000),
                source: source,
                url: dir.appendingPathComponent(name)
            )
        }
        .sorted { $0.date > $1.date }
    }

    @discardableResult
    func save(_ data: Data, file: String, source: String, date: Date = Date()) throws -> HistorySnapshot {
        let dir = folder(for: file)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var millis = UInt64(date.timeIntervalSince1970 * 1000)
        let cleanSource = source
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        // Keep names unique and ordered even when two saves land in the same millisecond.
        while snapshots(for: file).contains(where: { UInt64($0.date.timeIntervalSince1970 * 1000) == millis }) {
            millis += 1
        }
        let url = dir.appendingPathComponent("\(millis)__\(cleanSource.isEmpty ? "change" : cleanSource).snap")
        try AtomicFile.write(data, to: url)
        return snapshots(for: file).first { $0.url.lastPathComponent == url.lastPathComponent }!
    }

    func latestData(for file: String) -> Data? {
        snapshots(for: file).first.flatMap { try? Data(contentsOf: $0.url) }
    }
}
