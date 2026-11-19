import ChannelStore
import Foundation
import Support
import Testing
@testable import Workflow

/// Records which stages ran and can crash, fail or pause at a chosen stage.
final class ScriptedExecutor: StageExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var performed: [RunStage] = []
    var crashAt: RunStage?
    var pauseAt: RunStage?
    var failAt: RunStage?
    var failKind: YTAErrorKind = .network
    var failuresLeft = 1

    struct Crash: Error {}

    func perform(_ stage: RunStage, run: RunRecord, folder: ChannelFolder) async throws -> StageOutcome {
        let (crash, pause, fail) = lock.withLock { () -> (Bool, Bool, Bool) in
            performed.append(stage)
            var fail = false
            if failAt == stage, failuresLeft > 0 { failuresLeft -= 1; fail = true }
            return (crashAt == stage, pauseAt == stage, fail)
        }
        if crash {
            // Simulates the app being killed: the task never returns normally.
            try await Task.sleep(for: .seconds(3600))
        }
        if fail { throw YTAError(failKind, "Stage \(stage) failed") }
        return pause ? .waitForOwner : .proceed
    }
}

func makeFolder() throws -> ChannelFolder {
    let store = ChannelStore(channelsFolder: FileManager.default.temporaryDirectory.appendingPathComponent("yta-run-\(UUID().uuidString)"))
    return try store.createChannel(NewChannelRequest(workingName: "Runs")).folder
}

@Suite struct RunDriverTests {
    let node = Node(NodeRegistry.type("name")!)

    @Test func runsEveryStageAndFinishes() async throws {
        let folder = try makeFolder()
        let executor = ScriptedExecutor()
        let record = await RunDriver(folder: folder, executor: executor).start(node)
        #expect(record.stage == .finished)
        #expect(executor.performed == RunStage.workStages)
        #expect(try RunStore(folder: folder).load(record.id).stage == .finished)
        #expect(folder.exists(record.scratch))
    }

    @Test func resumesAtTheInterruptedStageAfterAKill() async throws {
        let folder = try makeFolder()
        let crashing = ScriptedExecutor()
        crashing.crashAt = .validating
        let task = Task { await RunDriver(folder: folder, executor: crashing).start(node) }
        // Wait until the run has saved itself at the validating stage, then "kill" it.
        let store = RunStore(folder: folder)
        for _ in 0..<200 where store.unfinished().first?.stage != .validating {
            try await Task.sleep(for: .milliseconds(10))
        }
        // What a fresh launch would find on disk after the app was killed here.
        let interrupted = try #require(store.unfinished().first)
        task.cancel()
        #expect(await task.value.stage == .cancelled)

        #expect(interrupted.stage == .validating)
        #expect(interrupted.completedStages == [.preparing, .executing])

        let fresh = ScriptedExecutor()
        let resumed = await RunDriver(folder: folder, executor: fresh).resume(interrupted)
        #expect(resumed.stage == .finished)
        #expect(fresh.performed == [.validating, .awaitingApproval, .writing])
        #expect(try store.load(interrupted.id).stage == .finished)
    }

    @Test func pausesForApprovalAndContinues() async throws {
        let folder = try makeFolder()
        let executor = ScriptedExecutor()
        executor.pauseAt = .awaitingApproval
        let driver = RunDriver(folder: folder, executor: executor)
        let waiting = await driver.start(node)
        #expect(waiting.stage == .awaitingApproval)
        let done = await driver.resume(waiting, ownerApproved: true)
        #expect(done.stage == .finished)
        #expect(executor.performed.filter { $0 == .awaitingApproval }.count == 1)
    }

    @Test func schemaMismatchGetsOneRepairAttempt() async throws {
        let folder = try makeFolder()
        let executor = ScriptedExecutor()
        executor.failAt = .validating
        executor.failKind = .schemaMismatch
        let record = await RunDriver(folder: folder, executor: executor).start(node)
        #expect(record.stage == .finished)
        #expect(executor.performed.filter { $0 == .validating }.count == 2)
    }

    @Test func otherFailuresStopVisiblyAndKeepFinishedStages() async throws {
        let folder = try makeFolder()
        let executor = ScriptedExecutor()
        executor.failAt = .executing
        let record = await RunDriver(folder: folder, executor: executor).start(node)
        #expect(record.stage == .failed)
        #expect(record.errorKind == .network)
        #expect(record.completedStages == [.preparing])
    }

    @Test func keepAwakeCountsHolders() {
        let awake = KeepAwake()
        awake.acquire(reason: "a")
        awake.acquire(reason: "b")
        awake.release()
        #expect(awake.isHeld)
        awake.release()
        #expect(!awake.isHeld)
    }
}
