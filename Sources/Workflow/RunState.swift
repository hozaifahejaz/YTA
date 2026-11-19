import ChannelStore
import Foundation
import Support

/// The stages every run passes through (section 5.2). State is saved after each,
/// so a crash, a quit or a sleeping Mac resumes at the stage that was interrupted.
public enum RunStage: String, Codable, Sendable, CaseIterable, Comparable {
    case preparing
    case executing
    case validating
    case awaitingApproval
    case writing
    case finished
    case failed
    case cancelled

    public var isTerminal: Bool { self == .finished || self == .failed || self == .cancelled }

    /// The stages that do work, in order.
    public static let workStages: [RunStage] = [.preparing, .executing, .validating, .awaitingApproval, .writing]

    public static func < (lhs: RunStage, rhs: RunStage) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .preparing: "Preparing"
        case .executing: "Working"
        case .validating: "Checking the result"
        case .awaitingApproval: "Waiting for you"
        case .writing: "Saving"
        case .finished: "Finished"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }
}

/// `runs/<run id>/run.json`.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int = 1
    public var id: String
    public var nodeID: String
    public var nodeType: String
    public var nodeTitle: String
    public var engine: EngineChoice?
    public var stage: RunStage
    /// Stages that completed, so a resume skips them.
    public var completedStages: [RunStage]
    public var attempts: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var error: String?
    public var errorKind: YTAErrorKind?

    public init(node: Node, id: String = Identifier.make(prefix: "run"), date: Date = Date()) {
        self.id = id
        self.nodeID = node.id
        self.nodeType = node.type
        self.nodeTitle = node.title
        self.engine = node.engine
        self.stage = .preparing
        self.completedStages = []
        self.attempts = 0
        self.startedAt = date
        self.updatedAt = date
    }

    public var folder: String { "\(ChannelLayout.runs)/\(id)" }
    public var file: String { "\(folder)/run.json" }
    public var scratch: String { "\(folder)/scratch" }
}

/// Reads and writes run records inside a channel.
public struct RunStore: Sendable {
    public let folder: ChannelFolder

    public init(folder: ChannelFolder) {
        self.folder = folder
    }

    public func save(_ record: RunRecord) throws {
        var copy = record
        copy.updatedAt = Date()
        try folder.writeJSON(copy, to: copy.file)
    }

    public func load(_ id: String) throws -> RunRecord {
        try folder.readJSON(RunRecord.self, "\(ChannelLayout.runs)/\(id)/run.json")
    }

    public func all() -> [RunRecord] {
        guard let runsURL = try? folder.url(ChannelLayout.runs),
              let names = try? FileManager.default.contentsOfDirectory(atPath: runsURL.path) else { return [] }
        return names.compactMap { try? load($0) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Runs that were interrupted before reaching a final stage.
    public func unfinished() -> [RunRecord] {
        all().filter { !$0.stage.isTerminal }
    }
}

/// Does the work of one stage. Engines, checks and the approval step plug in here.
public protocol StageExecutor: Sendable {
    func perform(_ stage: RunStage, run: RunRecord, folder: ChannelFolder) async throws -> StageOutcome
}

public enum StageOutcome: Sendable, Equatable {
    /// Go on to the next stage.
    case proceed
    /// Stop here until the owner approves, then call `resume`.
    case waitForOwner
}

/// Runs a node's stages in order, saving after each one (section 5.2).
public struct RunDriver: Sendable {
    public let folder: ChannelFolder
    public let executor: any StageExecutor
    public var maxAttempts = 2

    public init(folder: ChannelFolder, executor: any StageExecutor) {
        self.folder = folder
        self.executor = executor
    }

    private var store: RunStore { RunStore(folder: folder) }

    /// Starts a new run for a node.
    public func start(_ node: Node) async -> RunRecord {
        let record = RunRecord(node: node)
        try? folder.createFolder(record.scratch)
        try? store.save(record)
        return await drive(record)
    }

    /// Continues a run from the stage it stopped at. Completed stages are not repeated.
    public func resume(_ record: RunRecord, ownerApproved: Bool = false) async -> RunRecord {
        var record = record
        if ownerApproved, record.stage == .awaitingApproval {
            record.completedStages.append(.awaitingApproval)
            record.stage = .writing
            try? store.save(record)
        }
        return await drive(record)
    }

    public func cancel(_ record: RunRecord) -> RunRecord {
        var record = record
        record.stage = .cancelled
        try? store.save(record)
        return record
    }

    private func drive(_ start: RunRecord) async -> RunRecord {
        var record = start
        for stage in RunStage.workStages where !record.completedStages.contains(stage) {
            if Task.isCancelled { return cancel(record) }
            record.stage = stage
            try? store.save(record)
            do {
                let outcome = try await executor.perform(stage, run: record, folder: folder)
                if outcome == .waitForOwner {
                    // Saved at this stage. Approval resumes it.
                    return record
                }
                record.completedStages.append(stage)
                record.attempts = 0
                try? store.save(record)
            } catch is CancellationError {
                return cancel(record)
            } catch {
                record.attempts += 1
                let typed = error as? YTAError
                record.error = typed?.message ?? String(describing: error)
                record.errorKind = typed?.kind
                if typed?.kind == .schemaMismatch, record.attempts < maxAttempts {
                    // One repair attempt for a malformed result (section 5.2).
                    try? store.save(record)
                    return await drive(record)
                }
                record.stage = .failed
                try? store.save(record)
                return record
            }
        }
        record.stage = .finished
        record.error = nil
        try? store.save(record)
        return record
    }
}

/// Keeps the Mac awake while a run or render is active (section 5.2).
public final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var holders = 0
    private var token: NSObjectProtocol?

    public init() {}

    public func acquire(reason: String) {
        lock.lock(); defer { lock.unlock() }
        holders += 1
        #if os(macOS)
        if holders == 1 {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
        }
        #endif
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        holders = max(0, holders - 1)
        #if os(macOS)
        if holders == 0, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        #endif
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return holders > 0
    }
}
