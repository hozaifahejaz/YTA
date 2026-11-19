import Foundation
import Support

/// The final answer of a run.
public struct EngineOutcome: Sendable, Equatable {
    public var text: String
    /// Set when the tool returned schema output itself, or when YTA found JSON in the text.
    public var structured: JSONValue?
    public var usage: RunUsage?

    public init(text: String, structured: JSONValue? = nil, usage: RunUsage? = nil) {
        self.text = text
        self.structured = structured
        self.usage = usage
    }
}

/// Starts an LLM tool for one run, streams its events, keeps the raw log and returns the result.
public struct EngineRunner: Sendable {
    public let adapter: any EngineAdapter
    public let executable: URL
    public let environment: [String: String]
    public var redactor: Redactor = .shared

    public init(adapter: any EngineAdapter, executable: URL, environment: [String: String]) {
        self.adapter = adapter
        self.executable = executable
        self.environment = environment
    }

    /// Runs the tool. Progress lines go to `onProgress`. The raw stream is kept in
    /// `runs/<run id>/events.jsonl`. Cancelling the task stops the tool.
    public func run(_ request: RunRequest, onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> EngineOutcome {
        let runFolder = request.workingDirectory.appendingPathComponent(request.runFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        let arguments = try adapter.arguments(for: request)
        let parser = adapter.makeParser(for: request)
        let log = RawLog(url: runFolder.appendingPathComponent("events.jsonl"), redactor: redactor)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = request.workingDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let state = RunState(parser: parser, onProgress: onProgress, log: log)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.consume(handle.availableData)
        }
        let errBuffer = LockedData()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errBuffer.append(handle.availableData)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EngineOutcome, Error>) in
                state.setContinuation(continuation)
                process.terminationHandler = { process in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.consume(stdout.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                    state.finish(status: process.terminationStatus, stderr: errBuffer.string, timedOut: state.timedOut)
                }
                do {
                    try process.run()
                } catch {
                    state.fail(YTAError(.toolMissing, "\(adapter.id.displayName) could not be started at \(executable.path)."))
                    return
                }
                state.setProcess(process)
                if let input = adapter.standardInput(for: request) {
                    let handle = stdin.fileHandleForWriting
                    DispatchQueue.global().async {
                        handle.write(Data(input.utf8))
                        try? handle.close()
                    }
                } else {
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout) {
                    if process.isRunning {
                        state.timedOut = true
                        process.terminate()
                        let pid = process.processIdentifier
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if process.isRunning { kill(pid, SIGKILL) }
                        }
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Appends raw output lines to the run's log, redacted.
final class RawLog: @unchecked Sendable {
    private let url: URL
    private let redactor: Redactor
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL, redactor: Redactor) {
        self.url = url
        self.redactor = redactor
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
        handle?.write(Data((redactor.redact(line) + "\n").utf8))
    }

    deinit {
        try? handle?.close()
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shared between the pipe handlers, the termination handler and cancellation.
final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let parser: any EventParser
    private let onProgress: @Sendable (String) -> Void
    private let log: RawLog
    private var buffer = Data()
    private var continuation: CheckedContinuation<EngineOutcome, Error>?
    private var process: Process?
    private var outcome: EngineOutcome?
    private var failure: YTAError?
    private var cancelled = false
    private var resumed = false
    var timedOut = false

    init(parser: any EventParser, onProgress: @escaping @Sendable (String) -> Void, log: RawLog) {
        self.parser = parser
        self.onProgress = onProgress
        self.log = log
    }

    func setContinuation(_ continuation: CheckedContinuation<EngineOutcome, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { process.terminate() }
    }

    func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        for line in lines { handle(line) }
    }

    private func handle(_ line: String) {
        log.append(line)
        for event in parser.parse(line: line) { apply(event) }
    }

    private func apply(_ event: RunEvent) {
        switch event {
        case .progress(let text):
            onProgress(text)
        case .result(let text, let structured, let usage):
            lock.lock(); outcome = EngineOutcome(text: text, structured: structured, usage: usage); lock.unlock()
        case .failure(let error):
            lock.lock(); if failure == nil { failure = error }; lock.unlock()
        }
    }

    func finish(status: Int32, stderr: String, timedOut: Bool) {
        // Flush a last line without a newline.
        lock.lock()
        let rest = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { handle(rest) }

        lock.lock()
        let haveOutcome = outcome != nil || failure != nil
        lock.unlock()
        if !haveOutcome {
            for event in parser.finish(status: status, stderr: stderr) { apply(event) }
        }
        if !stderr.isEmpty { log.append("{\"yta\":\"stderr\",\"text\":\(JSONValue.string(String(stderr.suffix(4000))).compactString)}") }

        lock.lock()
        let wasCancelled = cancelled
        let result = outcome
        var error = failure
        lock.unlock()
        if wasCancelled {
            resume(.failure(CancellationError()))
        } else if timedOut {
            resume(.failure(YTAError(.checkFailed, "The engine ran past its time limit and was stopped.")))
        } else if let error {
            resume(.failure(error))
        } else if let result {
            resume(.success(result))
        } else {
            error = YTAError(.checkFailed, "The engine ended without a result.")
            resume(.failure(error!))
        }
    }

    func fail(_ error: YTAError) {
        resume(.failure(error))
    }

    /// Stops the tool and returns at once. A tool that ignores the polite signal is killed after a few seconds.
    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        resume(.failure(CancellationError()))
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func resume(_ result: Result<EngineOutcome, Error>) {
        lock.lock()
        guard !resumed, let continuation else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

/// Finds each tool through the login shell and builds runners for it.
public struct EngineRegistry: Sendable {
    public static let adapters: [EngineID: any EngineAdapter] = [
        .claude: ClaudeAdapter(),
        .codex: CodexAdapter(),
        .opencode: OpenCodeAdapter(),
    ]

    public static func adapter(for id: EngineID) -> any EngineAdapter {
        adapters[id]!
    }

    /// A runner using the path recorded by the health check, or a fresh lookup.
    public static func runner(for id: EngineID, tools: ToolsFile?, allowAPIKey: Bool) async throws -> EngineRunner {
        let item = tools?.items.first { $0.id.rawValue == id.rawValue }
        var executable = item?.path.map { URL(fileURLWithPath: $0) }
        if executable == nil || !FileManager.default.isExecutableFile(atPath: executable!.path) {
            executable = await ProcessRunner.locate(id.command)
        }
        guard let executable else {
            throw YTAError(.toolMissing, "\(id.displayName) is not installed.")
        }
        let path = await loginPath()
        let env = CleanEnvironment.make(for: id, path: path, allowAPIKey: allowAPIKey)
        return EngineRunner(adapter: adapter(for: id), executable: executable, environment: env)
    }

    /// The PATH the owner's login shell sets, so tools find node and friends.
    static func loginPath() async -> String? {
        guard let result = try? await ProcessRunner.shell("printf %s \"$PATH\""), result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Checks a result against a schema, finding JSON in plain text when the tool did not return it structured.
public enum ResultCheck {
    public static func structured(_ outcome: EngineOutcome, schema: JSONValue?) throws -> JSONValue? {
        guard let schema else { return outcome.structured }
        guard let value = outcome.structured ?? JSONSchemaCheck.extractJSON(from: outcome.text) else {
            throw YTAError(.schemaMismatch, "The result was not in the expected format.")
        }
        let problems = JSONSchemaCheck.problems(in: value, against: schema)
        guard problems.isEmpty else {
            throw YTAError(.schemaMismatch, "The result did not match its format: \(problems.prefix(3).joined(separator: "; ")).")
        }
        return value
    }
}
