import Foundation
import Support

/// One asset's record in `ledger.json` (section 8.4).
public struct LedgerEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var source: String
    public var title: String
    public var pageURL: String
    public var fileURL: String
    public var author: String
    public var licence: LicenceKind
    /// The licence as the source wrote it.
    public var licenceName: String
    public var licenceURL: String
    public var creditRequired: Bool
    public var shareAlike: Bool
    public var retrieved: Date
    public var sha256: String
    /// Where the file is inside the video's Working files.
    public var file: String
    public var shots: [String]
    /// Made by an AI route: the upload needs YouTube's altered-content label.
    public var aiGenerated: Bool

    public init(id: String, source: String, title: String, pageURL: String, fileURL: String, author: String,
                licence: LicenceKind, licenceName: String, licenceURL: String?, retrieved: Date, sha256: String,
                file: String, shots: [String] = [], aiGenerated: Bool = false) {
        self.id = id
        self.source = source
        self.title = title
        self.pageURL = pageURL
        self.fileURL = fileURL
        self.author = author
        self.licence = licence
        self.licenceName = licenceName
        self.licenceURL = licenceURL ?? licence.defaultURL ?? ""
        self.creditRequired = licence.creditRequired
        self.shareAlike = licence.shareAlike
        self.retrieved = retrieved
        self.sha256 = sha256
        self.file = file
        self.shots = shots
        self.aiGenerated = aiGenerated
    }

    /// Fields that are empty. A complete entry has none.
    public var missing: [String] {
        var fields: [String] = []
        if source.isEmpty { fields.append("source") }
        if pageURL.isEmpty && licence != .owner && licence != .generated { fields.append("source page") }
        if fileURL.isEmpty && licence != .owner && licence != .generated { fields.append("direct link") }
        if author.isEmpty { fields.append("author") }
        if licenceName.isEmpty { fields.append("licence") }
        if licenceURL.isEmpty && licence != .owner && licence != .generated { fields.append("licence link") }
        if sha256.count != 64 { fields.append("file hash") }
        if file.isEmpty { fields.append("file") }
        return fields
    }

    /// One line for the credits page.
    public var credit: String {
        "\(title) by \(author), \(licenceName)\(licenceURL.isEmpty ? "" : " (\(licenceURL))"), via \(source): \(pageURL)"
    }
}

public struct Ledger: Codable, Equatable, Sendable {
    public static let file = "ledger.json"
    public var schemaVersion = 1
    public var entries: [LedgerEntry]

    public init(entries: [LedgerEntry] = []) {
        self.entries = entries
    }

    public var incomplete: [(LedgerEntry, [String])] {
        entries.compactMap { entry in entry.missing.isEmpty ? nil : (entry, entry.missing) }
    }

    public var needsAILabel: Bool { entries.contains { $0.aiGenerated } }

    public mutating func add(_ entry: LedgerEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].shots = Array(Set(entries[index].shots + entry.shots)).sorted()
        } else {
            entries.append(entry)
        }
    }
}

/// Image width and height read from the file header (PNG, JPEG, GIF, WebP), so size checks work everywhere.
public enum ImageSize {
    public static func read(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(256 * 1024))
        guard bytes.count > 24 else { return nil }
        func be16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        func le16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func le24(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 }

        if bytes[0] == 0x89, bytes[1] == 0x50 { return (be32(16), be32(20)) }
        if bytes[0] == 0x47, bytes[1] == 0x49 { return (le16(6), le16(8)) }
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes.count > 30, bytes[8] == 0x57 {
            let chunk = String(decoding: bytes[12..<16], as: UTF8.self)
            if chunk == "VP8X" { return (le24(24) + 1, le24(27) + 1) }
            if chunk == "VP8 " { return (le16(26) & 0x3fff, le16(28) & 0x3fff) }
            if chunk == "VP8L" {
                let b = bytes[21..<25].map(Int.init)
                return (1 + (b[0] | (b[1] & 0x3f) << 8), 1 + ((b[1] >> 6) | b[2] << 2 | (b[3] & 0x0f) << 10))
            }
        }
        if bytes[0] == 0xff, bytes[1] == 0xd8 {
            var i = 2
            while i + 9 < bytes.count {
                guard bytes[i] == 0xff else { i += 1; continue }
                let marker = bytes[i + 1]
                if (0xc0...0xcf).contains(marker), marker != 0xc4, marker != 0xc8, marker != 0xcc {
                    return (be16(i + 7), be16(i + 5))
                }
                if marker == 0xd8 || marker == 0x01 || (0xd0...0xd7).contains(marker) { i += 2; continue }
                i += 2 + be16(i + 2)
            }
        }
        return nil
    }
}
