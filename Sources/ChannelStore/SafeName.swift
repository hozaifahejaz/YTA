import Foundation

/// Turns a title into a folder name (section 4.3).
/// `/` and `:` are replaced, the name is trimmed to 120 characters,
/// and trailing dots and spaces are removed. Clashes get a numeric suffix.
public enum SafeName {
    public static let maxLength = 120

    public static func folderName(for title: String) -> String {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: "\u{0}", with: "")
        name = name.components(separatedBy: .newlines).joined(separator: " ")
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > maxLength { name = String(name.prefix(maxLength)) }
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        return name.isEmpty ? "Untitled" : name
    }

    /// A folder name that does not exist yet inside `parent`, adding " 2", " 3" and so on.
    public static func uniqueFolderName(for title: String, in parent: URL, fileManager: FileManager = .default) -> String {
        let base = folderName(for: title)
        var candidate = base
        var counter = 2
        while fileManager.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
            let suffix = " \(counter)"
            candidate = String(base.prefix(maxLength - suffix.count)) + suffix
            counter += 1
        }
        return candidate
    }
}
