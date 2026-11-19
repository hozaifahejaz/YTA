import Foundation

/// Removes any stored secret from text before it is logged or shown (section 5.8).
public final class Redactor: @unchecked Sendable {
    public static let shared = Redactor()

    private let lock = NSLock()
    private var secrets: Set<String> = []

    public init() {}

    public func register(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return }
        lock.lock(); defer { lock.unlock() }
        secrets.insert(trimmed)
    }

    public func forget(_ secret: String) {
        lock.lock(); defer { lock.unlock() }
        secrets.remove(secret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func redact(_ text: String) -> String {
        lock.lock()
        let known = secrets.sorted { $0.count > $1.count }
        lock.unlock()
        var output = text
        for secret in known where output.contains(secret) {
            output = output.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return output
    }
}
