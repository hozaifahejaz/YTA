import Foundation

/// A small file logger. Every line passes through the redactor first.
public final class Log: @unchecked Sendable {
    public enum Level: String, Sendable { case info, warning, error }

    public static let shared = Log()

    private let queue = DispatchQueue(label: "yta.log")
    private var folder: URL?
    private let redactor: Redactor

    public init(redactor: Redactor = .shared) {
        self.redactor = redactor
    }

    public func configure(folder: URL) {
        queue.sync { self.folder = folder }
    }

    public func info(_ message: @autoclosure () -> String, file: String = #fileID) { write(.info, message(), file) }
    public func warning(_ message: @autoclosure () -> String, file: String = #fileID) { write(.warning, message(), file) }
    public func error(_ message: @autoclosure () -> String, file: String = #fileID) { write(.error, message(), file) }

    private func write(_ level: Level, _ message: String, _ file: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level.rawValue)] \(file): \(redactor.redact(message))\n"
        queue.async { [folder] in
            guard let folder else { return }
            let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            let url = folder.appendingPathComponent("yta-\(day).log")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
