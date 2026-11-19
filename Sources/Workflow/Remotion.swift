import Foundation
import Support

/// The shipped Remotion project, installed into Application Support with its lockfile (section 8.4).
public struct RemotionProject: Sendable {
    /// Where the project is installed.
    public let directory: URL
    public let node: URL
    /// PATH for npm and Remotion's own downloads.
    public let path: String?
    /// A Chrome to use instead of Remotion's own download. Nil on the Mac.
    public let browser: String?

    public init(directory: URL, node: URL, path: String? = nil, browser: String? = nil) {
        self.directory = directory
        self.node = node
        self.path = path
        self.browser = browser
    }

    public static var shipped: URL? { shippedResource("remotion") }

    var cli: URL { directory.appendingPathComponent("node_modules/@remotion/cli/remotion-cli.js") }
    var entry: String { "src/index.ts" }

    var environment: [String: String] {
        var env = ["HOME": NSHomeDirectory(), "NODE_ENV": "production", "REMOTION_DISABLE_TELEMETRY": "1"]
        let nodeFolder = node.deletingLastPathComponent().path
        env["PATH"] = [nodeFolder, path ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        return env
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: cli.path) && installedLock == shippedLock
    }

    var installedLock: String? {
        try? String(contentsOf: directory.appendingPathComponent(".yta-installed"), encoding: .utf8)
    }

    var shippedLock: String? {
        guard let source = Self.shipped, let data = try? Data(contentsOf: source.appendingPathComponent("package-lock.json")) else { return nil }
        return SHA256.hex(data)
    }

    /// Copies the shipped project in and runs `npm ci`. Skipped when the installed lockfile matches.
    public func install(onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        if isInstalled { return }
        guard let source = Self.shipped else { throw YTAError(.notFound, "The Remotion project is missing from the app.") }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(atPath: source.path) where item != "node_modules" && item != "out" {
            let target = directory.appendingPathComponent(item)
            try? manager.removeItem(at: target)
            try manager.copyItem(at: source.appendingPathComponent(item), to: target)
        }
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        onLine("Installing the Remotion project")
        let result = try await StreamingProcess.run(npm, arguments: ["ci", "--no-audit", "--no-fund"], environment: environment,
                                                    workingDirectory: directory, onLine: onLine)
        guard result.succeeded else {
            throw YTAError(.toolMissing, "The Remotion project could not be installed.", suggestion: String(result.stderr.suffix(400)))
        }
        try (shippedLock ?? "").write(to: directory.appendingPathComponent(".yta-installed"), atomically: true, encoding: .utf8)
    }

    /// Asks Remotion to fetch its headless browser now, so the first render does not stall (section 8.4).
    public func prepareBrowser() async throws {
        guard browser == nil else { return }
        let result = try await StreamingProcess.run(node, arguments: [cli.path, "browser", "ensure"], environment: environment,
                                                    workingDirectory: directory) { _ in }
        guard result.succeeded else { throw YTAError(.toolMissing, "Remotion could not download its browser.") }
    }

    /// Renders a timeline. `publicDir` is the video's Working files, so the timeline's relative paths resolve.
    public func render(timeline: URL, composition: String, publicDir: URL, output: URL, scale: Double = 1,
                       control: ProcessControl? = nil, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let props = try Self.props(for: timeline, next: output)
        defer { try? FileManager.default.removeItem(at: props) }
        var arguments = [cli.path, "render", entry, composition, output.path, "--props=\(props.path)",
                         "--public-dir=\(publicDir.path)", "--concurrency=2", "--log=info"]
        if scale != 1 { arguments.append("--scale=\(scale)") }
        if let browser { arguments.append("--browser-executable=\(browser)") }
        let lines = LastLines()
        let result = try await StreamingProcess.run(node, arguments: arguments, environment: environment, workingDirectory: directory,
                                                    control: control) { line in
            lines.add(line)
            if let progress = Self.progress(in: line) { onProgress(progress) }
        }
        try Task.checkCancellation()
        guard result.succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw YTAError(.checkFailed, "The render failed.", suggestion: lines.text)
        }
    }

    /// The compositions take `{ "timeline": ... }`; the file sits beside `next`.
    static func props(for timeline: URL, next: URL) throws -> URL {
        let data = try Data(contentsOf: timeline)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw YTAError(.fileFormat, "The timeline could not be read.") }
        let url = next.deletingLastPathComponent().appendingPathComponent("props-\(UUID().uuidString.prefix(8)).json")
        try JSONEncoder().encode(JSONValue.object(["timeline": value])).write(to: url)
        return url
    }

    /// Reads "Rendered 120/900" style progress.
    static func progress(in line: String) -> Double? {
        guard line.lowercased().contains("render"),
              let match = line.range(of: #"(\d+)\s*/\s*(\d+)"#, options: .regularExpression) else { return nil }
        let parts = line[match].split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return min(1, parts[0] / parts[1])
    }

    /// Starts Remotion Studio on a timeline and returns its address. The process keeps running until `control` stops it.
    public func studio(timeline: URL, publicDir: URL, control: ProcessControl) async throws -> URL {
        let props = try Self.props(for: timeline, next: directory.appendingPathComponent("studio"))
        let found = AsyncAddress()
        let task = Task {
            try await StreamingProcess.run(node, arguments: [cli.path, "studio", entry, "--props=\(props.path)", "--public-dir=\(publicDir.path)", "--no-open"],
                                           environment: environment, workingDirectory: directory, control: control) { line in
                if let range = line.range(of: #"http://(localhost|127\.0\.0\.1):\d+"#, options: .regularExpression),
                   let url = URL(string: String(line[range])) {
                    found.set(url)
                }
            }
        }
        for _ in 0..<120 {
            if let url = found.value { return url }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        task.cancel()
        throw YTAError(.toolMissing, "Remotion Studio did not start.")
    }

    /// Runs Remotion's bundled ffmpeg or ffprobe.
    public func tool(_ name: String, _ arguments: [String]) async throws -> ProcessResult {
        try await StreamingProcess.run(node, arguments: [cli.path, name] + arguments, environment: environment, workingDirectory: directory) { _ in }
    }
}

private final class LastLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line); if lines.count > 12 { lines.removeFirst() } } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

private final class AsyncAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ value: URL) { lock.withLock { if url == nil { url = value } } }
    var value: URL? { lock.withLock { url } }
}

/// One render at a time on the Mac (section 8.4, Rendering). Paused renders hold their place.
public actor RenderQueue {
    public static let shared = RenderQueue()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    public nonisolated let control = ProcessControl()
    public private(set) var current: String?

    public func acquire(_ title: String) async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        current = title
    }

    public func release() {
        current = nil
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    public var queued: Int { waiting.count }
}
