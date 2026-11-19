import ChannelStore
import Foundation
import Support

/// A track in `library/music/`. Only tracks the owner approved are used (section 8.4, Music).
public struct MusicTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: String { file }
    /// Inside the channel, under `library/music/`.
    public var file: String
    public var title: String
    public var mood: String?
    public var approved: Bool
    public var ledger: LedgerEntry

    public init(file: String, title: String, mood: String? = nil, approved: Bool = false, ledger: LedgerEntry) {
        self.file = file
        self.title = title
        self.mood = mood
        self.approved = approved
        self.ledger = ledger
    }
}

public struct MusicLibrary: Sendable {
    public static let folder = "library/music"
    public static let index = "library/music/tracks.json"
    public static let audioTypes: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "flac"]
    let channel: ChannelFolder

    public init(folder: ChannelFolder) {
        self.channel = folder
    }

    public func tracks() -> [MusicTrack] {
        (try? channel.readJSON([MusicTrack].self, Self.index)) ?? []
    }

    public func approved() -> [MusicTrack] { tracks().filter(\.approved) }

    /// Copies a track in with its licence. A licence that is not accepted is refused.
    @discardableResult
    public func add(_ data: Data, fileName: String, title: String, author: String, licence: String, licenceURL: String?,
                    sourcePage: String, mood: String? = nil, allowShareAlike: Bool = true) throws -> MusicTrack {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard Self.audioTypes.contains(ext) else { throw YTAError(.fileFormat, "\(fileName) is not an audio file YTA can use.") }
        let kind: LicenceKind
        if licence.lowercased().contains("own") {
            kind = .owner
        } else if licence.lowercased().contains("ai33") || licence.lowercased().contains("generated") {
            kind = .generated
        } else {
            switch LicenceCheck.classify(name: licence, url: licenceURL, allowShareAlike: allowShareAlike) {
            case .accepted(let accepted): kind = accepted
            case .rejected(let reason): throw YTAError(.checkFailed, "\(title) can't join the library. \(reason)")
            }
        }
        var list = tracks()
        let base = SafeName.folderName(for: (fileName as NSString).deletingPathExtension)
        var name = "\(base).\(ext)"
        var counter = 2
        while list.contains(where: { $0.file == "\(Self.folder)/\(name)" }) { name = "\(base) \(counter).\(ext)"; counter += 1 }
        let path = "\(Self.folder)/\(name)"
        try channel.write(data, to: path, source: "Music library")
        let entry = LedgerEntry(id: "music:\(name)", source: sourcePage.isEmpty ? kind.title : (URL(string: sourcePage)?.host ?? sourcePage),
                                title: title, pageURL: sourcePage, fileURL: sourcePage, author: author, licence: kind,
                                licenceName: licence, licenceURL: licenceURL, retrieved: Date(), sha256: SHA256.hex(data), file: path,
                                aiGenerated: kind == .generated)
        let track = MusicTrack(file: path, title: title, mood: mood, ledger: entry)
        list.append(track)
        try channel.writeJSON(list, to: Self.index, source: "Music library")
        return track
    }

    public func setApproved(_ file: String, _ approved: Bool) throws {
        var list = tracks()
        guard let index = list.firstIndex(where: { $0.file == file }) else { return }
        list[index].approved = approved
        try channel.writeJSON(list, to: Self.index, source: "Music library")
    }

    public func remove(_ file: String) throws {
        var list = tracks()
        list.removeAll { $0.file == file }
        try channel.writeJSON(list, to: Self.index, source: "Music library")
    }
}
