import Foundation

public enum Identifier {
    /// A short, sortable id: a time prefix plus random characters, for example `m3k9x2-a7f3q1`.
    public static func make(prefix: String? = nil, date: Date = Date()) -> String {
        let time = String(UInt64(date.timeIntervalSince1970 * 1000), radix: 36)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let random = String((0..<6).map { _ in alphabet.randomElement()! })
        let core = "\(time)-\(random)"
        if let prefix { return "\(prefix)_\(core)" }
        return core
    }
}
