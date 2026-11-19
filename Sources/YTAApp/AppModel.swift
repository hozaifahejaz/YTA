import AppKit
import ChannelStore
import Engines
import Foundation
import Observation
import Secrets
import Support
import Workflow

/// One line in the activity strip.
struct ActivityLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
    let isError: Bool
}

/// App state. Views read it and call its methods; it is the only thing that touches stores.
@MainActor
@Observable
final class AppModel {
    // MARK: Stores

    private(set) var settings: AppSettings
    private let settingsStore: SettingsStore
    private(set) var paths: AppPaths
    let secrets: any SecretStore

    // MARK: Channels

    private(set) var channels: [ChannelRecord] = []
    var selectedChannelID: String? {
        didSet { if oldValue != selectedChannelID { channelSelectionChanged() } }
    }
    private(set) var setupRow: NodeList?
    var selectedNodeID: String?
    var searchText = ""

    // MARK: Health

    private(set) var health: ToolsFile?
    private(set) var isCheckingHealth = false

    // MARK: Presentation

    var showNewChannel = false
    var showImportChannel = false
    var showHealthCheck = false
    var showInspector = true
    var pendingRemoval: Node?
    var alert: YTAError?
    private(set) var activity: [ActivityLine] = []
    /// Bumped after any write a view reads straight from disk (sources, history), so it redraws.
    private(set) var diskRevision = 0

    @ObservationIgnored private var watcher: ChannelWatcher?

    // MARK: Runs

    /// Running tasks by node id.
    @ObservationIgnored var runTasks: [String: Task<Void, Never>] = [:]
    /// The latest progress line per running node id.
    var runProgress: [String: String] = [:]
    @ObservationIgnored let keepAwake = KeepAwake()
    @ObservationIgnored var planDefaults = PlanDefaults.load()

    init(secrets: any SecretStore = KeychainSecretStore()) {
        let base = AppPaths.standard()
        let store = SettingsStore(url: base.settingsFile)
        let loaded = store.load()
        self.settingsStore = store
        self.settings = loaded
        self.paths = loaded.paths()
        self.secrets = secrets
    }

    // MARK: Lifecycle

    func start() {
        do {
            try paths.createFolders()
        } catch {
            report(error)
        }
        Log.shared.configure(folder: paths.logs)
        Log.shared.info("YTA started")
        let planFile = paths.support.appendingPathComponent("plan-defaults.json")
        PlanDefaults.installEditableCopy(at: planFile)
        planDefaults = PlanDefaults.load(override: planFile)
        Notifier.requestPermission()
        reloadChannels()
        health = HealthCheck.load(from: paths)
        resumeInterruptedRuns()
        if !settings.finishedFirstRun { showHealthCheck = true }
        Task { await runHealthCheck() }
    }

    func runHealthCheck() async {
        isCheckingHealth = true
        let result = await HealthCheck(paths: paths).run()
        health = result
        isCheckingHealth = false
        let missing = result.items.filter { $0.status == .missing && $0.id.required }
        if !missing.isEmpty {
            note("Missing: \(missing.map(\.id.title).joined(separator: ", ")). Open the health check to fix.", isError: true)
        }
    }

    func finishFirstRun() {
        updateSettings { $0.finishedFirstRun = true }
        showHealthCheck = false
    }

    // MARK: Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        let storageMoved = copy.storagePath != settings.storagePath
        settings = copy
        do {
            try settingsStore.save(copy)
        } catch {
            report(error)
        }
        if storageMoved {
            paths = copy.paths()
            try? paths.createFolders()
            selectedChannelID = nil
            reloadChannels()
        }
    }

    // MARK: Channels

    var channelStore: ChannelStore { ChannelStore(channelsFolder: paths.channels) }

    var selectedChannel: ChannelRecord? {
        channels.first { $0.id == selectedChannelID }
    }

    var filteredChannels: [ChannelRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.manifest.name.localizedCaseInsensitiveContains(query)
                || ($0.manifest.group ?? "").localizedCaseInsensitiveContains(query)
                || ($0.manifest.handle ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    /// Channels grouped for the sidebar. Ungrouped channels come first under "Channels".
    var channelGroups: [(name: String, channels: [ChannelRecord])] {
        let grouped = Dictionary(grouping: filteredChannels) { $0.manifest.group?.isEmpty == false ? $0.manifest.group! : "" }
        return grouped.keys.sorted { a, b in
            if a.isEmpty { return true }
            if b.isEmpty { return false }
            return a.localizedCompare(b) == .orderedAscending
        }
        .map { (name: $0.isEmpty ? "Channels" : $0, channels: grouped[$0]!.sorted { $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending }) }
    }

    func reloadChannels() {
        channels = channelStore.listChannels()
        if let id = selectedChannelID, !channels.contains(where: { $0.id == id }) {
            selectedChannelID = channels.first?.id
        } else if selectedChannelID == nil {
            selectedChannelID = channels.first?.id
        } else {
            loadSetupRow()
        }
    }

    func createChannel(_ request: NewChannelRequest) {
        do {
            let record = try channelStore.createChannel(request)
            try WorkflowStore(folder: record.folder).installDefaults(
                origin: request.origin,
                nicheGiven: request.niche?.isEmpty == false
            )
            note("Created \(record.manifest.name)")
            reloadChannels()
            selectedChannelID = record.id
            selectedNodeID = setupRow?.nextNode?.id
        } catch {
            report(error)
        }
    }

    func updateManifest(_ change: (inout ChannelManifest) -> Void) {
        guard let record = selectedChannel else { return }
        var manifest = record.manifest
        change(&manifest)
        guard manifest != record.manifest else { return }
        do {
            if manifest.name != record.manifest.name, !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty {
                let renamed = try channelStore.rename(record, to: manifest.name)
                manifest.name = renamed.manifest.name
                try renamed.folder.saveManifest(manifest)
            } else {
                try record.folder.saveManifest(manifest)
                try record.folder.regenerateAgentsFile(source: "channel settings")
            }
            reloadChannels()
        } catch {
            report(error)
        }
    }

    func updateSources(_ change: (inout SourcesConfig) -> Void) {
        guard let folder = selectedChannel?.folder else { return }
        var sources = folder.sources()
        change(&sources)
        do {
            try folder.writeJSON(sources, to: ChannelLayout.sources, source: "channel settings")
            try folder.regenerateAgentsFile(source: "channel settings")
            diskRevision += 1
        } catch {
            report(error)
        }
    }

    func revealSelectedChannel() {
        guard let root = selectedChannel?.folder.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.storageRoot])
    }

    // MARK: Setup row

    private func channelSelectionChanged() {
        selectedNodeID = nil
        loadSetupRow()
        startWatching()
    }

    func loadSetupRow() {
        guard let record = selectedChannel else {
            setupRow = nil
            return
        }
        let store = WorkflowStore(folder: record.folder)
        if store.setupRow() == nil {
            try? store.installDefaults(origin: record.manifest.origin, nicheGiven: false)
        }
        setupRow = store.setupRow()
    }

    var selectedNode: Node? {
        guard let id = selectedNodeID else { return nil }
        return setupRow?[id]
    }

    func selectNode(at index: Int) {
        guard let nodes = setupRow?.nodes, nodes.indices.contains(index) else { return }
        selectedNodeID = nodes[index].id
        showInspector = true
    }

    private func mutateRow(_ change: (inout NodeList) throws -> Void) {
        guard let record = selectedChannel, var row = setupRow else { return }
        do {
            try change(&row)
            try WorkflowStore(folder: record.folder).saveSetupRow(row)
            setupRow = row
        } catch {
            report(error)
        }
    }

    /// Saves the owner's edits to a node. Only editable fields are taken, so a stale
    /// inspector copy never overwrites the state a run has set.
    func updateNode(_ edited: Node) {
        mutateRow { row in
            guard var current = row[edited.id] else { return }
            current.title = edited.title
            current.engine = edited.engine
            current.promptTemplate = edited.promptTemplate
            current.inputs = edited.inputs
            current.outputs = edited.outputs
            current.approval = edited.approval
            row.update(current)
        }
    }

    func insertCustomNode(after anchor: String?) {
        let node = Node(
            type: NodeType.custom.id,
            title: "Custom step",
            engine: EngineChoice(tool: .claude),
            promptTemplate: "",
            outputs: ["profile/custom-\(Identifier.make().suffix(6)).md"],
            approval: .always
        )
        mutateRow { $0.insert(node, after: anchor) }
        selectedNodeID = node.id
        showInspector = true
    }

    func requestRemove(_ node: Node) {
        guard let row = setupRow else { return }
        if row.nodesBroken(byRemoving: node.id).isEmpty {
            remove(node, force: false)
        } else {
            pendingRemoval = node
        }
    }

    func remove(_ node: Node, force: Bool) {
        mutateRow { try $0.remove(node.id, force: force) }
        if selectedNodeID == node.id { selectedNodeID = nil }
        pendingRemoval = nil
    }

    func redo(_ node: Node) {
        mutateRow { $0.redo(node.id) }
        note("\(node.title) will run again. Later steps that used it are marked out of date.")
    }

    func saveAsTemplate(_ node: Node) {
        do {
            try TemplateStore(folder: paths.templates).save(name: node.title, nodes: [node])
            note("Saved \(node.title) as a template")
        } catch {
            report(error)
        }
    }

    func resetSetupRow() {
        guard let record = selectedChannel else { return }
        mutateRow { $0 = DefaultRows.setup(for: record.manifest.origin) }
    }

    // MARK: History

    func history(for file: String) -> [HistorySnapshot] {
        selectedChannel?.folder.history(for: file) ?? []
    }

    func restore(_ snapshot: HistorySnapshot) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            try folder.restore(snapshot)
            if snapshot.file.hasPrefix("profile/") { try folder.regenerateAgentsFile(source: "restore") }
            diskRevision += 1
            note("Restored \(snapshot.file) from \(snapshot.date.formatted(date: .abbreviated, time: .shortened))")
        } catch {
            report(error)
        }
    }

    // MARK: Watching

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard let record = selectedChannel else { return }
        let folder = record.folder
        watcher = ChannelWatcher(root: folder.root) { [weak self] paths in
            Task { @MainActor in self?.handleOutsideChanges(paths, in: folder) }
        }
    }

    private func handleOutsideChanges(_ changed: [String], in folder: ChannelFolder) {
        var reloadRow = false
        for path in changed {
            guard let relative = folder.relativePath(of: URL(fileURLWithPath: path)),
                  !relative.hasPrefix(ChannelLayout.history) else { continue }
            if relative == ChannelLayout.setupWorkflow { reloadRow = true }
            if ChannelLayout.isInstructionFile(relative), (try? folder.noteExternalChange(relative)) != nil {
                note("Saved a history copy of \(relative) after an outside edit")
            }
        }
        diskRevision += 1
        if reloadRow, folder == selectedChannel?.folder {
            loadSetupRow()
        }
    }

    // MARK: Messages

    func note(_ text: String, isError: Bool = false) {
        activity.append(ActivityLine(text: text, date: Date(), isError: isError))
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
        if isError { Log.shared.warning(text) } else { Log.shared.info(text) }
    }

    func report(_ error: Error) {
        let typed = (error as? YTAError) ?? YTAError(.fileFormat, error.localizedDescription)
        alert = typed
        note(typed.message, isError: true)
    }
}
