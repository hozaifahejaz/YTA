import ChannelStore
import Engines
import Foundation
import Support
import UserNotifications
import Artwork
import MediaTools
import Workflow
import YouTubeData

/// Starting, approving and stopping node runs (section 5.2). Runs keep going with the window closed.
extension AppModel {
    var runningCount: Int { runTasks.count }

    func isRunning(_ node: Node) -> Bool { runTasks[node.id] != nil }

    func canRun(_ node: Node) -> Bool { NodeRunExecutor.canRun(node) }

    func latestRun(for node: Node) -> RunRecord? {
        guard let folder = selectedChannel?.folder else { return nil }
        _ = diskRevision
        return RunStore(folder: folder).latest(for: node.id)
    }

    func draft(for run: RunRecord) -> RunDraft? {
        guard let folder = selectedChannel?.folder else { return nil }
        return RunStore(folder: folder).draft(for: run)
    }

    func context(for record: ChannelRecord, node: Node? = nil) -> RunContext {
        let owner = WeakModel(self)
        return RunContext(
            settings: settings,
            tools: health,
            planDefaults: planDefaults,
            automation: record.manifest.automation,
            onProgress: { line in
                Task { @MainActor in owner.model?.progress(line) }
            },
            youtube: youtube,
            http: URLSessionHTTP(),
            artwork: CoreGraphicsRenderer(),
            video: node.flatMap { VideoStore(folder: record.folder).video(containing: $0.id) },
            ai33Key: { [secrets] in try? secrets.valueForRequest(.ai33pro) },
            narrationTools: MacNarrationTools(whisper: whisper),
            mediaKey: { [secrets] source in
                switch source {
                case "pexels": try? secrets.valueForRequest(.pexels)
                case "pixabay": try? secrets.valueForRequest(.pixabay)
                default: nil
                }
            },
            remotion: remotionProject
        )
    }

    fileprivate func progress(_ line: String) {
        note(line)
    }

    /// Starts a node in the selected channel.
    func run(_ node: Node, note: String? = nil, in channel: ChannelRecord? = nil) {
        guard let record = channel ?? selectedChannel else { return }
        guard canRun(node) else {
            report(YTAError(.checkFailed, "\(node.title) can't run yet.", suggestion: "Built-in steps arrive in later milestones. Custom steps run now."))
            return
        }
        guard runTasks[node.id] == nil else { return }
        let driver = RunDriver(folder: record.folder, executor: NodeRunExecutor(node: node, context: context(for: record, node: node), note: note))
        switch node.state {
        case .done, .stale: statesBeforeRun[node.id] = (node.state, node.resultSummary)
        case .waiting, .failed: statesBeforeRun[node.id] = nil
        case .running, .needsYou: break
        }
        setState(of: node.id, in: record.folder, to: .running, summary: "")
        launch(node.id, title: node.title, channel: record) { await driver.start(node) }
    }

    /// Approves the waiting draft, which writes it into the channel.
    func approve(_ node: Node) {
        guard let record = selectedChannel, runTasks[node.id] == nil, let run = latestRun(for: node), run.stage == .awaitingApproval else { return }
        let driver = RunDriver(folder: record.folder, executor: NodeRunExecutor(node: node, context: context(for: record, node: node)))
        launch(node.id, title: node.title, channel: record) { await driver.resume(run, ownerApproved: true) }
    }

    /// Throws the waiting draft away. Nothing is written.
    func discard(_ node: Node) {
        guard let record = selectedChannel, let run = latestRun(for: node) else { return }
        let driver = RunDriver(folder: record.folder, executor: NodeRunExecutor(node: node, context: context(for: record, node: node)))
        _ = driver.cancel(run)
        // Throwing away a second draft leaves the earlier result in place.
        let before = statesBeforeRun[node.id]
        setState(of: node.id, in: record.folder, to: before?.state ?? .waiting, summary: before?.summary)
        diskRevision += 1
    }

    func stop(_ node: Node) {
        runTasks[node.id]?.cancel()
    }

    func stopAll() {
        for task in runTasks.values { task.cancel() }
    }

    private func launch(_ nodeID: String, title: String, channel: ChannelRecord, _ work: @escaping @Sendable () async -> RunRecord) {
        keepAwake.acquire(reason: "Running \(title)")
        runTasks[nodeID] = Task { [weak self] in
            let result = await work()
            await MainActor.run {
                guard let self else { return }
                self.runTasks[nodeID] = nil
                self.keepAwake.release()
                self.finished(result, channel: channel)
            }
        }
    }

    private func finished(_ run: RunRecord, channel: ChannelRecord) {
        let folder = channel.folder
        if run.stage == .finished || run.stage == .awaitingApproval || run.stage == .failed {
            recordSpend(run, channel: channel)
        }
        switch run.stage {
        case .awaitingApproval:
            let summary = RunStore(folder: folder).draft(for: run)?.summary ?? "Draft ready"
            setState(of: run.nodeID, in: folder, to: .needsYou, summary: summary)
            note("\(run.nodeTitle) is ready for you to review")
            Notifier.post(title: "\(run.nodeTitle) needs you", body: "\(channel.manifest.name): a draft is ready to review.")
        case .finished:
            let draft = RunStore(folder: folder).draft(for: run)
            let summary = draft?.summary ?? "Saved"
            if draft?.keepsStepOpen == true {
                // A preview is not the step's result: the step goes back to where it was.
                let before = statesBeforeRun[run.nodeID]
                setState(of: run.nodeID, in: folder, to: before?.state ?? .waiting, summary: before?.summary)
                note("\(run.nodeTitle): \(summary)")
            } else {
                setState(of: run.nodeID, in: folder, to: .done, summary: summary)
                note("\(run.nodeTitle) is done")
            }
            if run.nodeType == "name" { adoptChosenName(in: channel) }
        case .failed:
            setState(of: run.nodeID, in: folder, to: .failed, summary: run.error)
            note("\(run.nodeTitle) failed: \(run.error ?? "unknown error")", isError: true)
            if run.errorKind == .usageLimit {
                Notifier.post(title: "Usage limit reached", body: "\(run.nodeTitle) stopped. It can run again once the limit resets.")
            }
        case .cancelled:
            // A stopped re-run leaves the earlier result in place.
            let before = statesBeforeRun[run.nodeID]
            setState(of: run.nodeID, in: folder, to: before?.state ?? .waiting, summary: before?.summary)
            note("Stopped \(run.nodeTitle)")
        default:
            break
        }
        if run.stage != .awaitingApproval { statesBeforeRun[run.nodeID] = nil }
        diskRevision += 1
        switch run.stage {
        case .finished, .awaitingApproval, .failed:
            // After a failure this stops the queue and says why, instead of leaving it marked as running.
            advanceQueue(channel)
        case .cancelled:
            // Stopping a video's step pauses its queue; otherwise the queue would start the step again at once.
            if VideoStore(folder: folder).video(containing: run.nodeID) != nil, runningQueues.remove(channel.manifest.id) != nil {
                note("Queue paused for \(channel.manifest.name)")
            }
        default:
            break
        }
    }

    /// Updates a node's state in any channel's row, on disk and on screen.
    func setState(of nodeID: String, in folder: ChannelFolder, to state: NodeState, summary: String?) {
        do {
            try VideoStore.setState(nodeID, state, summary: summary, folder: folder)
        } catch {
            report(error)
        }
        if folder == selectedChannel?.folder { loadSetupRow() }
    }

    /// After a crash or quit, picks every unfinished run up at the stage it stopped (section 5.2).
    func resumeInterruptedRuns() {
        for record in channels {
            let store = RunStore(folder: record.folder)
            let setup = WorkflowStore(folder: record.folder).setupRow()
            let videos = VideoStore(folder: record.folder).all()
            for run in store.unfinished() {
                let found = setup?[run.nodeID] ?? videos.lazy.compactMap { $0.row[run.nodeID] }.first
                guard let node = found, NodeRunExecutor.canRun(node) else {
                    _ = RunDriver(folder: record.folder, executor: NodeRunExecutor(node: Node(type: run.nodeType, title: run.nodeTitle), context: context(for: record))).cancel(run)
                    continue
                }
                if run.stage == .awaitingApproval {
                    setState(of: node.id, in: record.folder, to: .needsYou, summary: store.draft(for: run)?.summary ?? "Draft ready")
                    continue
                }
                note("Resuming \(node.title) in \(record.manifest.name)")
                let driver = RunDriver(folder: record.folder, executor: NodeRunExecutor(node: node, context: context(for: record, node: node)))
                setState(of: node.id, in: record.folder, to: .running, summary: "")
                launch(node.id, title: node.title, channel: record) { await driver.resume(run) }
            }
        }
    }
}

/// Notifications when a node needs the owner. Only inside a real app bundle.
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Lets background progress reach the model without keeping it alive.
private final class WeakModel: @unchecked Sendable {
    weak var model: AppModel?
    init(_ model: AppModel) { self.model = model }
}
