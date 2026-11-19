import Foundation

/// Runs command line tools. A Mac app does not inherit the terminal PATH,
/// so tool lookups ask the owner's login shell (section 5.3).
public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum ProcessRunner {
    /// Runs a program to completion and collects its output.
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { handle in collector.appendOut(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in collector.appendErr(handle.availableData) }

        return try await withCheckedThrowingContinuation { continuation in
            let finished = OnceFlag()
            process.terminationHandler = { process in
                guard finished.set() else { return }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: collector.outString,
                    stderr: collector.errString
                ))
            }
            do {
                try process.run()
            } catch {
                guard finished.set() else { return }
                continuation.resume(throwing: YTAError(.toolMissing, "Could not start \(executable.lastPathComponent)."))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// The owner's login shell, falling back to zsh, the macOS default.
    public static var loginShell: URL {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return URL(fileURLWithPath: shell)
    }

    /// Runs a command line through the login shell so the owner's PATH applies.
    public static func shell(_ command: String, timeout: TimeInterval = 20) async throws -> ProcessResult {
        try await run(loginShell, arguments: ["-lc", command], timeout: timeout)
    }

    /// Finds a tool by name through the login shell. Returns nil when it is not installed.
    public static func locate(_ tool: String) async -> URL? {
        guard tool.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        guard let result = try? await shell("command -v \(tool)"), result.succeeded else { return nil }
        let path = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        return path.map { URL(fileURLWithPath: $0) }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }
    var outString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
