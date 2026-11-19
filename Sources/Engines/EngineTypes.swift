import Foundation
import Support

/// What a run may do. Everything outside the list is denied without a prompt (section 5.3).
public struct ToolPolicy: Sendable, Equatable {
    /// Read files inside the channel folder.
    public var readChannel: Bool
    /// Search and fetch the web (research nodes only).
    public var web: Bool
    /// Write inside `runs/<run id>/scratch/` only.
    public var writeScratch: Bool

    public init(readChannel: Bool = true, web: Bool = false, writeScratch: Bool = false) {
        self.readChannel = readChannel
        self.web = web
        self.writeScratch = writeScratch
    }

    public static let readOnly = ToolPolicy()
    public static let research = ToolPolicy(web: true)
}

/// One headless run of an LLM tool.
public struct RunRequest: Sendable {
    public var runID: String
    public var prompt: String
    /// The channel folder. The tool starts here and must stay inside it.
    public var workingDirectory: URL
    /// Relative to the working directory: `runs/<run id>`.
    public var runFolder: String
    public var model: String?
    public var effort: Effort?
    /// A JSON Schema the final result must match.
    public var schema: JSONValue?
    public var policy: ToolPolicy
    /// Only used when the owner allowed API-key use for this tool.
    public var maxBudgetUSD: Double?
    public var allowAPIKey: Bool
    public var timeout: TimeInterval

    public init(
        runID: String,
        prompt: String,
        workingDirectory: URL,
        runFolder: String,
        model: String? = nil,
        effort: Effort? = nil,
        schema: JSONValue? = nil,
        policy: ToolPolicy = .readOnly,
        maxBudgetUSD: Double? = nil,
        allowAPIKey: Bool = false,
        timeout: TimeInterval = 30 * 60
    ) {
        self.runID = runID
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.runFolder = runFolder
        self.model = model
        self.effort = effort
        self.schema = schema
        self.policy = policy
        self.maxBudgetUSD = maxBudgetUSD
        self.allowAPIKey = allowAPIKey
        self.timeout = timeout
    }

    public var scratchFolder: String { "\(runFolder)/scratch" }
}

public struct RunUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}

/// What the adapter reports while a run goes.
public enum RunEvent: Sendable, Equatable {
    /// A plain-language line for the activity strip.
    case progress(String)
    /// The final answer. `structured` is set when the tool returned schema output itself.
    case result(text: String, structured: JSONValue?, usage: RunUsage?)
    /// A typed failure reported by the tool.
    case failure(YTAError)
}

public struct EngineCapabilities: Sendable, Equatable {
    public var schemaOutput: Bool
    public var effort: Bool
    public var webSearch: Bool
    public var skillsFolder: String?
}

/// One command line tool. Adapters only build arguments and read events;
/// `EngineRunner` starts the process (section 5.3).
public protocol EngineAdapter: Sendable {
    var id: EngineID { get }
    var capabilities: EngineCapabilities { get }
    /// Arguments after the executable. May write helper files (a schema) into the run folder.
    func arguments(for request: RunRequest) throws -> [String]
    /// Text sent on standard input, if the prompt goes there.
    func standardInput(for request: RunRequest) -> String?
    /// A fresh reader for one run's output.
    func makeParser(for request: RunRequest) -> any EventParser
}

extension EngineAdapter {
    public func standardInput(for request: RunRequest) -> String? { request.prompt }
}

/// Reads one run's output line by line. One parser per run, so it can keep state.
public protocol EventParser: AnyObject {
    func parse(line: String) -> [RunEvent]
    /// Called when the process ends. Emits the result if the stream did not.
    func finish(status: Int32, stderr: String) -> [RunEvent]
}

/// Maps a tool name from an event to a plain line for the activity strip.
enum ProgressText {
    static func forTool(_ name: String, detail: String?) -> String {
        let lower = name.lowercased()
        if lower == "structuredoutput" { return "Writing the result" }
        let tail = detail.map { ": \($0.prefix(80))" } ?? ""
        if lower.contains("search") && lower.contains("web") || lower == "web_search" { return "Searching the web\(tail)" }
        if lower.contains("fetch") { return "Reading a web page\(tail)" }
        if lower.contains("read") || lower == "view" { return "Reading \(detail ?? "a file")" }
        if lower.contains("glob") || lower.contains("grep") || lower == "list" { return "Looking through the channel folder" }
        if lower.contains("write") || lower.contains("edit") { return "Writing a draft" }
        return "Using \(name)\(tail)"
    }
}

/// Spots usage-limit and sign-in messages in tool output.
public enum ToolMessages {
    public static func classify(_ text: String) -> YTAError? {
        let lower = text.lowercased()
        let limitPhrases = ["usage limit", "rate limit", "rate_limit", "limit reached", "quota exceeded", "too many requests", "you've hit your", "out of credits"]
        if limitPhrases.contains(where: lower.contains) {
            return YTAError(.usageLimit, "The engine hit its usage limit.", resetsAt: resetTime(in: text))
        }
        let signInPhrases = ["not logged in", "please run /login", "please log in", "invalid api key", "authentication", "unauthorized", "codex login", "auth login"]
        if signInPhrases.contains(where: lower.contains) {
            return YTAError(.notSignedIn, "The engine is not signed in.")
        }
        return nil
    }

    /// Finds a Unix timestamp or an ISO date after the word "reset" if the tool gave one.
    static func resetTime(in text: String) -> Date? {
        guard let range = text.range(of: "reset", options: .caseInsensitive) else { return nil }
        let tail = String(text[range.upperBound...].prefix(80))
        let numbers: [Substring] = tail.split(whereSeparator: { !$0.isNumber })
        if let digits = numbers.first(where: { $0.count == 10 }), let seconds = TimeInterval(String(digits)) { return Date(timeIntervalSince1970: seconds) }
        let iso = ISO8601DateFormatter()
        for token in tail.split(whereSeparator: { $0 == " " || $0 == "\"" || $0 == "," }) {
            if let date = iso.date(from: String(token)) { return date }
        }
        return nil
    }
}
