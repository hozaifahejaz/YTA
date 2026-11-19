import Foundation

/// Writes go to a temporary file in the same folder and are then renamed into place,
/// so a crash never leaves half a file behind (section 4.4).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            // rename(2) is atomic within one volume and replaces an existing file.
            if rename(temp.path, url.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if isDiskFull(error) {
                throw YTAError(.diskFull, "The disk is full, so \(url.lastPathComponent) could not be saved.")
            }
            throw error
        }
    }

    public static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL, preservingUnknownFields: Bool = true) throws {
        let existing = preservingUnknownFields ? try? Data(contentsOf: url) : nil
        try write(JSONMerge.encodePreserving(value, over: existing), to: url)
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        return false
    }
}
