import Foundation

/// Pause and resume for a running process, used by the render queue.
public final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var paused = false

    public init() {}

    func attach(_ process: Process) {
        lock.withLock {
            self.process = process
            if paused { process.suspend() }
        }
    }

    func detach() { lock.withLock { process = nil } }

    public var isPaused: Bool { lock.withLock { paused } }

    public func pause() {
        lock.withLock {
            guard !paused else { return }
            paused = true
            _ = process?.suspend()
        }
    }

    public func resume() {
        lock.withLock {
            guard paused else { return }
            paused = false
            _ = process?.resume()
        }
    }

    public func stop() {
        lock.withLock {
            if paused { _ = process?.resume() }
            process?.terminate()
        }
    }
}

/// Runs a long program, passing each output line on as it arrives. Cancelling the task stops the program.
public enum StreamingProcess {
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        control: ProcessControl? = nil,
        onLine: @escaping @Sendable (String) -> Void
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

        let collector = LineCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { collector.add($0.availableData, error: false) }
        err.fileHandleForReading.readabilityHandler = { collector.add($0.availableData, error: true) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let finished = OnceFlag()
                process.terminationHandler = { process in
                    guard finished.set() else { return }
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.add(out.fileHandleForReading.readDataToEndOfFile(), error: false)
                    collector.add(err.fileHandleForReading.readDataToEndOfFile(), error: true)
                    collector.flush()
                    control?.detach()
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: collector.stdout, stderr: collector.stderr))
                }
                do {
                    try process.run()
                    control?.attach(process)
                    // A task cancelled before the program started never reaches `onCancel` with it running.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    guard finished.set() else { return }
                    continuation.resume(throwing: YTAError(.toolMissing, "Could not start \(executable.lastPathComponent)."))
                }
            }
        } onCancel: {
            control?.resume()
            if process.isRunning { process.terminate() }
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var partial = ["out": "", "err": ""]
    private let onLine: @Sendable (String) -> Void
    /// Output kept for the result is capped; renders print a lot.
    private let cap = 2_000_000

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func add(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            if error { if err.count < cap { err.append(data) } } else { if out.count < cap { out.append(data) } }
            let key = error ? "err" : "out"
            var text = (partial[key] ?? "") + String(decoding: data, as: UTF8.self)
            text = text.replacingOccurrences(of: "\r", with: "\n")
            var parts = text.components(separatedBy: "\n")
            partial[key] = parts.removeLast()
            lines = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        lines.forEach(onLine)
    }

    func flush() {
        let rest = lock.withLock { () -> [String] in
            defer { partial = ["out": "", "err": ""] }
            return partial.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        rest.forEach(onLine)
    }

    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
}
