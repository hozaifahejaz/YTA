import AppKit
import ChannelStore
import Control
import Engines
import Foundation
import Media
import Secrets
import Support
import Workflow
import YouTubeData

// Everything the owner can do in the window, as MCP tools (spec: "control everything").
//
// RULE FOR NEW FEATURES: every non-private AppModel method must be called from an action in this
// file, or be listed in Scripts/control-exempt.txt with the reason it has no action.
// `Scripts/check-control-coverage.py` runs in CI and fails otherwise.
// Step types need nothing here: run_step, approve_step and get_step work for every node type.

extension AppModel {
    // MARK: Server

    var controlURL: String { "http://127.0.0.1:\(settings.control.port)/mcp" }

    /// The token AI tools send. Made once and kept in the Keychain.
    func controlToken() throws -> String {
        if let token = try secrets.read(.controlToken), !token.isEmpty {
            Redactor.shared.register(token)
            return token
        }
        let token = ControlHTTPServer.makeToken()
        try secrets.save(token, for: .controlToken)
        Redactor.shared.register(token)
        return token
    }

    func startControlServer() {
        controlServer?.stop()
        controlServer = nil
        guard settings.control.enabled else {
            controlStatus = "Off"
            return
        }
        do {
            let token = try controlToken()
            let registry = ActionRegistry()
            registry.register(controlActions())
            controlActionCount = registry.all.count
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let mcp = MCPServer(registry: registry, version: version, instructions: Self.controlInstructions)
            let server = ControlHTTPServer(token: token) { body in await mcp.handle(body) }
            try server.start(port: UInt16(clamping: settings.control.port))
            controlServer = server
            controlStatus = "Listening on 127.0.0.1:\(server.port) with \(registry.all.count) tools"
            Log.shared.info("MCP server: \(controlStatus)")
        } catch {
            controlStatus = (error as? YTAError)?.message ?? error.localizedDescription
            note("The MCP server did not start: \(controlStatus)", isError: true)
        }
    }

    /// A new token. Clients set up with the old one must be set up again.
    func renewControlToken() {
        do {
            try secrets.save(ControlHTTPServer.makeToken(), for: .controlToken)
            startControlServer()
            note("Made a new MCP token. Set up your AI tools again.")
        } catch {
            report(error)
        }
    }

    /// The command that adds YTA to Claude Code, for the owner to copy.
    func claudeCodeSetupCommand() throws -> String {
        "claude mcp add --scope user --transport http yta \(controlURL) --header \"Authorization: Bearer \(try controlToken())\""
    }

    /// JSON for clients configured by file (Cursor, Claude Desktop with a bridge, OpenCode and others).
    func controlClientConfig() throws -> String {
        let token = try controlToken()
        return """
        {
          "mcpServers": {
            "yta": {
              "type": "http",
              "url": "\(controlURL)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    /// Runs `claude mcp add` for the owner. Only on their click.
    func addToClaudeCode() async {
        guard let path = health?.items.first(where: { $0.id == .claude })?.path else {
            report(YTAError(.toolMissing, "Claude Code was not found.", suggestion: "Install it from the health check, or copy the setup command."))
            return
        }
        do {
            let claude = URL(fileURLWithPath: path)
            let token = try controlToken()
            _ = try? await ProcessRunner.run(claude, arguments: ["mcp", "remove", "--scope", "user", "yta"], timeout: 30)
            let result = try await ProcessRunner.run(claude, arguments: [
                "mcp", "add", "--scope", "user", "--transport", "http", "yta", controlURL,
                "--header", "Authorization: Bearer \(token)",
            ], timeout: 30)
            if result.succeeded {
                note("Added YTA to Claude Code. New Claude Code sessions can control YTA.")
            } else {
                report(YTAError(.checkFailed, "Claude Code did not add YTA: \(Redactor.shared.redact(result.stderr + result.stdout))"))
            }
        } catch {
            report(error)
        }
    }

    static let controlInstructions = """
    YTA makes faceless YouTube videos. You control the YTA app on this Mac.
    Start with get_overview. Channels hold a setup row of steps; each video in a channel's queue has its own row.
    Steps are nodes with ids. run_step starts a step and returns at once; use wait_for_step or get_step to follow it.
    A step in state needsYou has a draft or a choice waiting: get_step shows it under "pending".
    Answer it with the matching action (choose_niche, pick_name, choose_brand, choose_avatar, choose_voice, queue_topics,
    edit_script, swap_media, decide_skill, save_interview), or approve_step / discard_step.
    start_queue runs a channel's videos top to bottom. Files inside a channel are readable and writable with read_file and write_file.
    API keys are never readable; the owner adds them in YTA Settings, Keys.
    """

    // MARK: Helpers

    /// Runs one action on the main actor. App errors (which also show in the window) become tool errors.
    func perform(_ kind: ControlAction.Kind, _ body: @MainActor @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        let before = activity.count
        let value = try await body()
        let lines = activity.suffix(max(0, activity.count - before))
        if let failure = lines.last(where: \.isError) {
            throw ControlError.failed(failure.text)
        }
        guard kind != .read else { return value }
        var object = value.objectValue ?? (value == .null ? [:] : ["result": value])
        object["ok"] = .bool(true)
        if !lines.isEmpty { object["activity"] = .array(lines.map { .string($0.text) }) }
        return .object(object)
    }

    func makeAction(_ name: String, _ summary: String, _ kind: ControlAction.Kind = .change, _ parameters: [Parameter] = [],
                    _ body: @escaping @MainActor @Sendable (AppModel, ActionInput) async throws -> JSONValue) -> ControlAction {
        ControlAction(name, summary, kind: kind, parameters: parameters) { [weak self] input in
            guard let model = self else { throw ControlError.failed("YTA is closing.") }
            return try await model.perform(kind) { try await body(model, input) }
        }
    }

    /// Picks the channel named by `channel_id` (an id or a name), or the selected one.
    func controlChannel(_ input: ActionInput) throws -> ChannelRecord {
        if let key = input.optionalString("channel_id") {
            guard let record = channels.first(where: { $0.id == key || $0.manifest.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw ControlError.invalid("No channel \(key). list_channels shows them.")
            }
            if selectedChannelID != record.id { selectedChannelID = record.id }
            return record
        }
        guard let record = selectedChannel else { throw ControlError.invalid("No channel is selected. Pass channel_id.") }
        return record
    }

    /// Finds a step in any channel and selects that channel, since the app acts on the selected channel.
    func controlNode(_ input: ActionInput, key: String = "node_id") throws -> Node {
        let id = try input.string(key)
        for record in channels {
            let inSetup = WorkflowStore(folder: record.folder).setupRow()?[id] != nil
            guard inSetup || VideoStore(folder: record.folder).video(containing: id) != nil else { continue }
            if selectedChannelID != record.id { selectedChannelID = record.id }
            if let node = setupRow?[id] ?? video(containing: id)?.row[id] { return node }
        }
        throw ControlError.invalid("No step \(id). get_channel and get_video list step ids.")
    }

    func controlVideo(_ input: ActionInput) throws -> VideoFile {
        let id = try input.string("video_id")
        for record in channels where VideoStore(folder: record.folder).video(id) != nil {
            if selectedChannelID != record.id { selectedChannelID = record.id }
            if let video = videos.first(where: { $0.id == id }) { return video }
        }
        throw ControlError.invalid("No video \(id). list_videos shows them.")
    }

    static func text(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    func json<T: Encodable>(_ value: T?) throws -> JSONValue {
        guard let value else { return .null }
        return try JSONValue(encoding: value)
    }

    func stepSummary(_ node: Node) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(node.id), "type": .string(node.type), "title": .string(node.title),
            "state": .string(node.state.rawValue), "running": .bool(isRunning(node)),
        ]
        if let summary = node.resultSummary { object["summary"] = .string(summary) }
        if let progress = runProgress[node.id] { object["progress"] = .string(progress) }
        return .object(object)
    }

    func videoSummary(_ video: VideoFile) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(video.id), "title": .string(video.title), "status": .string(video.status.rawValue),
            "short": .bool(video.settings.short),
            "next_step": video.row.nextNode.map(stepSummary) ?? .null,
        ]
        if let url = video.publishedURL { object["published_url"] = .string(url) }
        if let parent = video.parentID { object["parent_id"] = .string(parent) }
        return .object(object)
    }

    func estimateJSON(_ estimate: VideoEstimate) -> JSONValue {
        .object([
            "words": .number(Double(estimate.words)),
            "voice_characters": .number(Double(estimate.voiceCharacters)),
            "engine_steps": .number(Double(estimate.engineSteps)),
            "max_engine_usd": .number(estimate.maxEngineUSD),
            "max_image_generations": .number(Double(estimate.maxImageGenerations)),
        ])
    }

    /// Every step waiting for the owner, in every channel.
    func stepsNeedingYou() -> [JSONValue] {
        channels.flatMap { record -> [JSONValue] in
            let setup = WorkflowStore(folder: record.folder).setupRow()?.nodes ?? []
            let videoNodes = VideoStore(folder: record.folder).all().flatMap(\.row.nodes)
            return (setup + videoNodes).filter { $0.state == .needsYou }.map { node in
                .object(["channel_id": .string(record.id), "node_id": .string(node.id), "title": .string(node.title),
                         "summary": .string(node.resultSummary ?? "")])
            }
        }
    }

    // MARK: The actions

    func controlActions() -> [ControlAction] {
        overviewActions() + channelActions() + fileActions() + stepActions() + choiceActions()
            + videoActions() + toolActions() + settingsActions() + youtubeActions() + windowActions()
    }

    private static let channelParameter = Parameter.optional("channel_id", .string, "Channel id or name. Defaults to the selected channel.")
    private static let nodeParameter = Parameter("node_id", .string, "The step's id.")
    private static let videoParameter = Parameter("video_id", .string, "The video's id.")
    private static let changesParameter = Parameter("changes", .object, "Only the fields to change, with the same names as in the matching get_ result.")

    private func overviewActions() -> [ControlAction] {
        [
            makeAction("get_overview", "What YTA is doing now: channels, running steps, queues, steps waiting for the owner, missing tools and recent activity.", .read) { m, _ in
                let channels: [JSONValue] = m.channels.map { .object(["id": .string($0.id), "name": .string($0.manifest.name)]) }
                let running: [JSONValue] = m.runTasks.keys.sorted().map { id in
                    .object(["node_id": .string(id), "progress": .string(m.runProgress[id] ?? "")])
                }
                let queues: [JSONValue] = m.runningQueues.sorted().map(JSONValue.string)
                let missing: [JSONValue] = (m.health?.items ?? []).filter { $0.status == .missing }.map { .string($0.id.rawValue) }
                let recent: [JSONValue] = m.activity.suffix(15).map { .string($0.text) }
                var object: [String: JSONValue] = [:]
                object["selected_channel_id"] = Self.text(m.selectedChannelID)
                object["channels"] = .array(channels)
                object["running_steps"] = .array(running)
                object["running_queues"] = .array(queues)
                object["needs_you"] = .array(m.stepsNeedingYou())
                object["missing_tools"] = .array(missing)
                object["recent_activity"] = .array(recent)
                object["mcp"] = .string(m.controlStatus)
                return .object(object)
            },
            makeAction("get_activity", "The activity log, newest last.", .read, [.optional("limit", .integer, "How many lines. Default 50.")]) { m, input in
                .array(m.activity.suffix(max(1, input.optionalInt("limit") ?? 50)).map {
                    .object(["text": .string($0.text), "error": .bool($0.isError), "date": .string($0.date.ISO8601Format())])
                })
            },
            makeAction("list_step_types", "Every built-in step type: id, title, what it does, inputs and outputs.", .read) { _, _ in
                .array(NodeType.all.map { type in
                    .object(["id": .string(type.id), "title": .string(type.title), "summary": .string(type.summary),
                             "inputs": .array(type.inputs.map { .string($0) }), "outputs": .array(type.outputs.map { .string($0) }),
                             "locked_reason": Self.text(type.lockedReason)])
                })
            },
            makeAction("get_spend", "Money and narration characters spent today and on one video, and the caps.", .read,
                       [.optional("video_id", .string, "A video, for its own totals.")]) { m, input in
                let ledger = SpendLedger(url: m.spendLedgerURL)
                let today = ledger.totals(dayOf: Date())
                var object: [String: JSONValue] = [
                    "today_usd": .number(today.usd), "today_voice_characters": .number(Double(today.voiceCharacters)),
                    "caps": try m.json(m.settings.caps),
                ]
                if let id = input.optionalString("video_id") {
                    let video = ledger.totals(videoID: id)
                    object["video_usd"] = .number(video.usd)
                    object["video_voice_characters"] = .number(Double(video.voiceCharacters))
                }
                return .object(object)
            },
            makeAction("refresh", "Reloads channels and videos from disk, after files changed outside YTA.") { m, _ in
                m.reloadChannels()
                m.loadSetupRow()
                m.diskRevision += 1
                return .null
            },
        ]
    }

    private func channelActions() -> [ControlAction] {
        [
            makeAction("list_channels", "Every channel with its id, name, handle, group, origin and automation level.", .read) { m, _ in
                .array(try m.channels.map { try m.json($0.manifest) })
            },
            makeAction("get_channel", "One channel: its settings, sources, setup steps, videos, Shorts switch, editing style, setup kit and music.", .read,
                       [Self.channelParameter]) { m, input in
                let record = try m.controlChannel(input)
                var object: [String: JSONValue] = [:]
                object["manifest"] = try m.json(record.manifest)
                object["sources"] = try m.json(record.folder.sources())
                object["setup_steps"] = .array((m.setupRow?.nodes ?? []).map(m.stepSummary))
                object["videos"] = .array(m.videos.map(m.videoSummary))
                object["queue_running"] = .bool(m.isQueueRunning(record))
                object["makes_shorts"] = .bool(m.makesShorts)
                object["editing_style"] = try m.json(m.editingStyle)
                object["setup_kit"] = try m.json(m.setupChecklist())
                object["interview_answers"] = .array(m.interviewAnswers().map(JSONValue.string))
                object["last_niche_brief"] = try m.json(m.lastNicheBrief())
                object["music"] = try m.json(m.musicTracks)
                return .object(object)
            },
            makeAction("select_channel", "Shows a channel in the window.", .change, [Parameter("channel_id", .string, "Channel id or name.")]) { m, input in
                _ = try m.controlChannel(input)
                return .null
            },
            makeAction("create_channel", "Creates a channel and its setup steps. Leave niche out to have YTA research one.", .change, [
                Parameter("name", .string, "Working name. The name step can replace it."),
                .optional("niche", .string, "The niche, if the owner has one."),
                .optional("format", .oneOf(ChannelFormat.allCases.map(\.rawValue)), "Long-form, Shorts or both. Default longForm."),
                .optional("language", .string, "Default English."),
                .optional("country", .string, "Target country."),
                .optional("import_link", .string, "A YouTube channel link, to import an existing channel instead."),
                .optional("automation", .oneOf(AutomationLevel.allCases.map(\.rawValue)), "How often YTA stops for approval. Default from Settings."),
            ]) { m, input in
                let link = input.optionalString("import_link")
                m.createChannel(NewChannelRequest(
                    workingName: try input.string("name"),
                    niche: link == nil ? input.optionalString("niche") : nil,
                    format: input.optionalString("format").flatMap(ChannelFormat.init(rawValue:)) ?? .longForm,
                    language: input.optionalString("language") ?? "English",
                    country: input.optionalString("country"),
                    origin: link == nil ? .new : .imported,
                    importLink: link,
                    automation: input.optionalString("automation").flatMap(AutomationLevel.init(rawValue:)) ?? m.settings.automationDefault
                ))
                return .object(["channel_id": Self.text(m.selectedChannelID)])
            },
            makeAction("update_channel", "Changes a channel's settings (name, handle, group, automation, language and the rest of get_channel's manifest).", .change,
                       [Self.channelParameter, Self.changesParameter]) { m, input in
                let record = try m.controlChannel(input)
                let changed = try JSONValue.patch(record.manifest, with: try input.object("changes"), name: "channel")
                m.updateManifest { $0 = changed }
                return try m.json(m.selectedChannel?.manifest)
            },
            makeAction("update_sources", "Changes where a channel may take media from (get_channel's sources).", .change,
                       [Self.channelParameter, Self.changesParameter]) { m, input in
                let record = try m.controlChannel(input)
                let changed = try JSONValue.patch(record.folder.sources(), with: try input.object("changes"), name: "sources")
                m.updateSources { $0 = changed }
                return try m.json(record.folder.sources())
            },
            makeAction("reset_setup_steps", "Puts the channel's setup row back to the default steps. Custom steps are removed.", .destructive,
                       [Self.channelParameter]) { m, input in
                _ = try m.controlChannel(input)
                m.resetSetupRow()
                return .null
            },
            makeAction("set_kit_item", "Ticks or unticks an item on the channel's setup kit checklist.", .change,
                       [Self.channelParameter, Parameter("item_id", .string, "From get_channel's setup_kit."), Parameter("done", .boolean, "Ticked or not.")]) { m, input in
                _ = try m.controlChannel(input)
                m.setKitItem(try input.string("item_id"), done: try input.bool("done"))
                return .null
            },
            makeAction("set_makes_shorts", "Whether new videos in the channel get a Shorts step after the final check.", .change,
                       [Self.channelParameter, Parameter("on", .boolean, "On or off.")]) { m, input in
                _ = try m.controlChannel(input)
                m.setMakesShorts(try input.bool("on"))
                return .null
            },
            makeAction("add_music", "Adds a music file from this Mac to the channel's music library, with its licence.", .change, [
                Self.channelParameter,
                Parameter("file_path", .string, "Absolute path of the audio file."),
                Parameter("title", .string, "Track title."),
                Parameter("author", .string, "Who made it."),
                Parameter("licence", .string, "Licence name, for example CC BY 4.0."),
                .optional("licence_url", .string, "Link to the licence."),
                Parameter("source_page", .string, "The page the track came from."),
            ]) { m, input in
                _ = try m.controlChannel(input)
                m.addMusic(URL(fileURLWithPath: (try input.string("file_path") as NSString).expandingTildeInPath),
                           title: try input.string("title"), author: try input.string("author"), licence: try input.string("licence"),
                           licenceURL: input.optionalString("licence_url") ?? "", source: try input.string("source_page"))
                return .null
            },
            makeAction("set_music_approved", "Approves or blocks a track in the music library.", .change,
                       [Self.channelParameter, Parameter("file", .string, "The track's file, from get_channel's music."), Parameter("approved", .boolean, "Approved or not.")]) { m, input in
                _ = try m.controlChannel(input)
                let file = try input.string("file")
                guard let track = m.musicTracks.first(where: { $0.file == file }) else { throw ControlError.invalid("No track \(file).") }
                m.setMusicApproved(track, try input.bool("approved"))
                return .null
            },
            makeAction("remove_music", "Removes a track from the music library.", .destructive,
                       [Self.channelParameter, Parameter("file", .string, "The track's file.")]) { m, input in
                _ = try m.controlChannel(input)
                let file = try input.string("file")
                guard let track = m.musicTracks.first(where: { $0.file == file }) else { throw ControlError.invalid("No track \(file).") }
                m.removeMusic(track)
                return .null
            },
        ]
    }

    private func fileActions() -> [ControlAction] {
        [
            makeAction("list_files", "Lists a folder inside a channel.", .read,
                       [Self.channelParameter, .optional("path", .string, "Folder inside the channel. Default the channel's root.")]) { m, input in
                let record = try m.controlChannel(input)
                let url = try record.folder.url(input.optionalString("path") ?? "")
                let names = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                return .array(names.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    return .object(["name": .string(item.lastPathComponent), "folder": .bool(values?.isDirectory ?? false),
                                    "bytes": .number(Double(values?.fileSize ?? 0))])
                })
            },
            makeAction("read_file", "Reads a text file inside a channel (profile, scripts, plans, kit, run logs).", .read,
                       [Self.channelParameter, Parameter("path", .string, "Path inside the channel, for example profile/voice.md.")]) { m, input in
                let record = try m.controlChannel(input)
                let data = try record.folder.read(try input.string("path"))
                guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else {
                    return .object(["binary": .bool(true), "bytes": .number(Double(data.count))])
                }
                return .string(text)
            },
            makeAction("write_file", "Writes a text file inside a channel. Instruction files keep a history copy.", .change, [
                Self.channelParameter, Parameter("path", .string, "Path inside the channel."), Parameter("text", .string, "The whole new text."),
            ]) { m, input in
                let record = try m.controlChannel(input)
                let path = try input.string("path")
                try record.folder.writeText(try input.string("text"), to: path, source: "MCP")
                if path.hasPrefix("profile/") { try record.folder.regenerateAgentsFile(source: "MCP") }
                m.diskRevision += 1
                m.loadSetupRow()
                return .null
            },
            makeAction("get_file_history", "Saved versions of an instruction file, newest first.", .read,
                       [Self.channelParameter, Parameter("path", .string, "Path inside the channel.")]) { m, input in
                _ = try m.controlChannel(input)
                return .array(m.history(for: try input.string("path")).map {
                    .object(["version_id": .string($0.id), "date": .string($0.date.ISO8601Format()), "source": .string($0.source)])
                })
            },
            makeAction("restore_file_version", "Puts a saved version of an instruction file back.", .change, [
                Self.channelParameter, Parameter("path", .string, "Path inside the channel."), Parameter("version_id", .string, "From get_file_history."),
            ]) { m, input in
                _ = try m.controlChannel(input)
                let id = try input.string("version_id")
                guard let snapshot = m.history(for: try input.string("path")).first(where: { $0.id == id }) else {
                    throw ControlError.invalid("No version \(id).")
                }
                m.restore(snapshot)
                return .null
            },
            makeAction("reveal_in_finder", "Shows a channel, a file in it, or the whole storage folder in Finder.", .change, [
                Self.channelParameter, .optional("path", .string, "A file or folder inside the channel."),
                .optional("storage", .boolean, "Show the storage folder that holds every channel."),
            ]) { m, input in
                if try input.bool("storage", default: false) {
                    m.revealStorage()
                    return .null
                }
                _ = try m.controlChannel(input)
                if let path = input.optionalString("path") { m.revealInChannel(path) } else { m.revealSelectedChannel() }
                return .null
            },
        ]
    }

    private func stepActions() -> [ControlAction] {
        [
            makeAction("get_step", "One step: its settings, state, latest run, draft and anything waiting for the owner's choice (under pending).", .read,
                       [Self.nodeParameter]) { m, input in
                let node = try m.controlNode(input)
                var object: [String: JSONValue] = [
                    "step": try m.json(node), "running": .bool(m.isRunning(node)), "can_run": .bool(m.canRun(node)),
                    "video_id": Self.text(m.video(containing: node.id)?.id),
                ]
                if let progress = m.runProgress[node.id] { object["progress"] = .string(progress) }
                if let run = m.latestRun(for: node) {
                    object["latest_run"] = try m.json(run)
                    if let draft = m.draft(for: run) {
                        object["draft"] = .object(["summary": Self.text(draft.summary), "files": .array(draft.files.keys.sorted().map { .string($0) })])
                    }
                }
                object["pending"] = try m.pendingChoice(for: node)
                return .object(object)
            },
            makeAction("wait_for_step", "Waits until a step stops running (or the timeout passes), then returns get_step's summary.", .read,
                       [Self.nodeParameter, .optional("timeout_seconds", .integer, "At most 600. Default 120.")]) { m, input in
                let node = try m.controlNode(input)
                let deadline = Date().addingTimeInterval(Double(min(600, max(1, input.optionalInt("timeout_seconds") ?? 120))))
                while m.isRunning(node), Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                }
                let current = m.setupRow?[node.id] ?? m.video(containing: node.id)?.row[node.id] ?? node
                return m.stepSummary(current)
            },
            makeAction("select_step", "Shows a step in the inspector. Give node_id, or position for the setup row's Nth step (1 is first).", .change, [
                .optional("node_id", .string, "The step's id."), .optional("position", .integer, "1-based place in the setup row."),
            ]) { m, input in
                if let position = input.optionalInt("position") {
                    m.selectNode(at: position - 1)
                } else {
                    let node = try m.controlNode(input)
                    m.selectedNodeID = node.id
                    m.showInspector = true
                }
                return .object(["selected": Self.text(m.selectedNodeID)])
            },
            makeAction("run_step", "Starts a step. Returns at once; follow it with wait_for_step.", .change,
                       [Self.nodeParameter, .optional("note", .string, "Extra direction for this run.")]) { m, input in
                let node = try m.controlNode(input)
                m.run(node, note: input.optionalString("note"))
                return .null
            },
            makeAction("approve_step", "Approves the draft a step is waiting on, which writes it into the channel.", .change, [Self.nodeParameter]) { m, input in
                let node = try m.controlNode(input)
                guard m.latestRun(for: node)?.stage == .awaitingApproval else { throw ControlError.invalid("\(node.title) has no draft waiting.") }
                m.approve(node)
                return .null
            },
            makeAction("discard_step", "Throws away the draft a step is waiting on. Nothing is written.", .destructive, [Self.nodeParameter]) { m, input in
                m.discard(try m.controlNode(input))
                return .null
            },
            makeAction("stop_step", "Stops a running step.", .change, [Self.nodeParameter]) { m, input in
                m.stop(try m.controlNode(input))
                return .null
            },
            makeAction("stop_all", "Stops every running step.", .change) { m, _ in
                m.stopAll()
                return .null
            },
            makeAction("redo_step", "Marks a finished step to run again. Later steps that used it are marked out of date.", .change, [Self.nodeParameter]) { m, input in
                m.redo(try m.controlNode(input))
                return .null
            },
            makeAction("update_step", "Changes a step's title, engine, promptTemplate, inputs, outputs or approval.", .change,
                       [Self.nodeParameter, Self.changesParameter]) { m, input in
                let node = try m.controlNode(input)
                m.updateNode(try JSONValue.patch(node, with: try input.object("changes"), name: "step"))
                return try m.json(m.setupRow?[node.id] ?? m.video(containing: node.id)?.row[node.id])
            },
            makeAction("add_custom_step", "Adds a custom step after another step, or at the start of a video's row.", .change, [
                Self.channelParameter, .optional("after_node_id", .string, "The step it follows."),
                .optional("video_id", .string, "The video whose row gets it, when it goes first."),
            ]) { m, input in
                if input.optionalString("after_node_id") != nil { _ = try m.controlNode(input, key: "after_node_id") } else { _ = try m.controlChannel(input) }
                if input.optionalString("video_id") != nil { _ = try m.controlVideo(input) }
                m.insertCustomNode(after: input.optionalString("after_node_id"), inVideo: input.optionalString("video_id"))
                return .object(["node_id": Self.text(m.selectedNodeID)])
            },
            makeAction("remove_step", "Removes a step. Without force it refuses when later steps need its files.", .destructive,
                       [Self.nodeParameter, .optional("force", .boolean, "Remove even if later steps need it.")]) { m, input in
                let node = try m.controlNode(input)
                let row = m.video(containing: node.id)?.row ?? m.setupRow
                let force = try input.bool("force", default: false)
                if !force, let broken = row?.nodesBroken(byRemoving: node.id), !broken.isEmpty {
                    throw ControlError.invalid("Later steps need \(node.title). Pass force to remove it anyway.")
                }
                m.remove(node, force: force)
                return .null
            },
            makeAction("save_step_as_template", "Saves a step as a reusable template.", .change, [Self.nodeParameter]) { m, input in
                m.saveAsTemplate(try m.controlNode(input))
                return .null
            },
            makeAction("set_editing_style", "Changes the channel's editing style through its edit step (fields as in get_channel's editing_style).", .change,
                       [Self.nodeParameter, Self.changesParameter]) { m, input in
                let node = try m.controlNode(input)
                m.setEditingStyle(try JSONValue.patch(m.editingStyle, with: try input.object("changes"), name: "editing style"), for: node)
                return .null
            },
            makeAction("render_preview", "Renders a short preview of a video's cut.", .change, [Self.nodeParameter]) { m, input in
                m.renderPreview(try m.controlNode(input))
                return .null
            },
            makeAction("toggle_render_pause", "Pauses the render that is running, or resumes it.", .change) { m, _ in
                m.toggleRenderPause()
                return .object(["paused": .bool(m.renderPausedFlag)])
            },
            makeAction("open_studio", "Opens a video's cut in Remotion Studio in the browser.", .change, [Self.nodeParameter]) { m, input in
                m.openStudio(for: try m.controlNode(input))
                return .null
            },
        ]
    }

    /// Whatever a waiting step offers the owner, by step type.
    func pendingChoice(for node: Node) throws -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let value = pendingNiches(for: node) { object["niches"] = try json(value) }
        if let value = pendingNames(for: node) { object["names"] = try json(value) }
        if let value = pendingBrand(for: node) { object["brand"] = try json(value) }
        if let value = pendingAvatars(for: node) { object["avatars"] = try json(value) }
        if case let (result, _)? = bannerResult(for: node) { object["banner"] = try json(result) }
        if let value = pendingSkills(for: node) { object["skills"] = try json(value) }
        if let value = pendingVoices(for: node) {
            object["voices"] = try json(value)
            object["chosen_voice_id"] = Self.text(chosenVoiceID(for: node))
        }
        if let value = pendingTopics(for: node) { object["topics"] = try json(value) }
        if let value = pendingScript(for: node) {
            object["script"] = Self.text(value.script)
            object["review"] = try json(value.review)
        }
        if let value = pendingMedia(for: node) {
            object["media"] = .object(["plan": try json(value.plan), "ledger": try json(value.ledger), "shots": try json(value.shots)])
        }
        if case let (set, _)? = thumbnailSet(for: node) { object["thumbnails"] = try json(set) }
        if case let (kit, _)? = kitFile(for: node) { object["kit"] = try json(kit) }
        return object.isEmpty ? .null : .object(object)
    }

    private func choiceActions() -> [ControlAction] {
        [
            makeAction("research_niche", "Runs niche research with a brief (fields as in get_channel's last_niche_brief).", .change,
                       [Self.nodeParameter, .optional("changes", .object, "Brief fields to change from the last brief.")]) { m, input in
                let node = try m.controlNode(input)
                let brief = try JSONValue.patch(m.lastNicheBrief(), with: (try? input.object("changes")) ?? [:], name: "brief")
                m.researchNiche(node, brief: brief)
                return .null
            },
            makeAction("choose_niche", "Picks a niche from the shortlist (index from get_step's pending.niches, 0 is first).", .change,
                       [Self.nodeParameter, Parameter("index", .integer, "0-based.")]) { m, input in
                m.chooseNiche(try input.int("index"), for: try m.controlNode(input))
                return .null
            },
            makeAction("pick_name", "Picks a channel name from the shortlist. YTA checks fallback handles, then saves it.", .change,
                       [Self.nodeParameter, Parameter("name", .string, "Exactly as in pending.names.")]) { m, input in
                m.pickName(try input.string("name"), for: try m.controlNode(input))
                return .null
            },
            makeAction("more_names", "Asks for a fresh round of names, steered by a note.", .change,
                       [Self.nodeParameter, .optional("note", .string, "What to change.")]) { m, input in
                m.anotherRound(of: try m.controlNode(input), note: input.optionalString("note") ?? "")
                return .null
            },
            makeAction("choose_brand", "Picks a brand option (0-based index into pending.brand).", .change,
                       [Self.nodeParameter, Parameter("index", .integer, "0-based.")]) { m, input in
                m.chooseBrand(try input.int("index"), for: try m.controlNode(input))
                return .null
            },
            makeAction("choose_avatar", "Picks a profile picture from pending.avatars, then approve_step saves it.", .change,
                       [Self.nodeParameter, Parameter("avatar_id", .string, "The candidate's id.")]) { m, input in
                m.chooseAvatar(try input.string("avatar_id"), for: try m.controlNode(input))
                return .null
            },
            makeAction("redraw_banner", "Draws the banner again with new text.", .change, [
                Self.nodeParameter, Parameter("name", .string, "Channel name on the banner."),
                .optional("tagline", .string, "Line under the name."), .optional("schedule", .string, "Upload schedule line."),
            ]) { m, input in
                m.redrawBanner(try m.controlNode(input), text: BannerText(name: try input.string("name"), tagline: input.optionalString("tagline"),
                                                                         schedule: input.optionalString("schedule")))
                return .null
            },
            makeAction("decide_skill", "Installs or skips one suggested skill from pending.skills.", .change, [
                Self.nodeParameter, Parameter("name", .string, "The skill's name."), Parameter("install", .boolean, "Install it or skip it."),
            ]) { m, input in
                await m.decideSkill(try input.string("name"), install: try input.bool("install"), for: try m.controlNode(input))
                return .null
            },
            makeAction("save_interview", "Answers the import interview and runs the step (answers in question order).", .change,
                       [Self.nodeParameter, Parameter("answers", .array(.string), "One answer per question.")]) { m, input in
                m.saveInterview(try m.controlNode(input), answers: try input.strings("answers"))
                return .null
            },
            makeAction("choose_voice", "Picks the narrator voice from pending.voices, then approve_step saves it.", .change, [
                Self.nodeParameter, Parameter("voice_id", .string, "The voice's id."), .optional("speed", .number, "Speaking speed. Default 1."),
            ]) { m, input in
                m.chooseVoice(try input.string("voice_id"), speed: (try? input.double("speed")) ?? 1, for: try m.controlNode(input))
                return .null
            },
            makeAction("queue_topics", "Picks topics from pending.topics and queues them as videos.", .change, [
                Self.nodeParameter, Parameter("picks", .array(.object), "Each {topic: index into pending.topics.topics, title: the video's title}."),
            ]) { m, input in
                let picks = try input.decode([TopicFile.Pick].self, "picks")
                m.queueTopics(picks, for: try m.controlNode(input))
                return .null
            },
            makeAction("edit_script", "Replaces the waiting script draft with new text (paragraphs separated by blank lines).", .change,
                       [Self.nodeParameter, Parameter("text", .string, "The whole script.")]) { m, input in
                m.editScriptDraft(try m.controlNode(input), text: try input.string("text"))
                return .null
            },
            makeAction("swap_media", "Swaps the media chosen for one shot. Leave candidate_id out to search again.", .change, [
                Self.nodeParameter, Parameter("shot_id", .string, "The shot, from pending.media."), .optional("candidate_id", .string, "Another candidate's id."),
            ]) { m, input in
                await m.swapMedia(try input.string("shot_id"), to: input.optionalString("candidate_id"), for: try m.controlNode(input))
                return .null
            },
        ]
    }

    private func videoActions() -> [ControlAction] {
        [
            makeAction("list_videos", "A channel's queue, top to bottom, with each video's next step.", .read, [Self.channelParameter]) { m, input in
                _ = try m.controlChannel(input)
                return .array(m.videos.map(m.videoSummary))
            },
            makeAction("get_video", "One video: its settings, steps, cost estimate, spend, kit and thumbnails.", .read, [Self.videoParameter]) { m, input in
                let video = try m.controlVideo(input)
                let spend = SpendLedger(url: m.spendLedgerURL).totals(videoID: video.id)
                return .object([
                    "video": try m.json(video),
                    "steps": .array(video.row.nodes.map(m.stepSummary)),
                    "estimate": m.estimateJSON(m.estimate(for: video)),
                    "spent_usd": .number(spend.usd),
                    "spent_voice_characters": .number(Double(spend.voiceCharacters)),
                ])
            },
            makeAction("add_video", "Adds a video to the end of a channel's queue. Give script to use the owner's own script.", .change, [
                Self.channelParameter, Parameter("title", .string, "Working title."), .optional("script", .string, "The owner's script, if any."),
                .optional("settings", .object, "Video settings (minutes, words, short, researchNotes, guidelines)."),
            ]) { m, input in
                _ = try m.controlChannel(input)
                let settings = try input["settings"].map { try JSONValue.patch(VideoSettings(), with: $0.objectValue ?? [:], name: "settings") }
                m.addVideo(title: try input.string("title"), script: input.optionalString("script"), settings: settings)
                return .object(["video_id": Self.text(m.expandedVideoID)])
            },
            makeAction("add_videos", "Adds many videos from a list of titles (one per line, or CSV).", .change, [
                Self.channelParameter, Parameter("list", .string, "The titles."), .optional("csv", .boolean, "The list is CSV."),
            ]) { m, input in
                _ = try m.controlChannel(input)
                m.addVideos(fromList: try input.string("list"), csv: try input.bool("csv", default: false))
                return .null
            },
            makeAction("move_video", "Moves a video up (negative) or down (positive) in the queue.", .change,
                       [Self.videoParameter, Parameter("by", .integer, "Places to move.")]) { m, input in
                m.moveVideo(try m.controlVideo(input).id, by: try input.int("by"))
                return .null
            },
            makeAction("set_video_status", "Sets a video's status.", .change,
                       [Self.videoParameter, Parameter("status", .oneOf(VideoStatus.allCases.map(\.rawValue)), "The new status.")]) { m, input in
                guard let status = VideoStatus(rawValue: try input.string("status")) else { throw ControlError.invalid("Unknown status.") }
                m.setVideoStatus(try m.controlVideo(input).id, status)
                return .null
            },
            makeAction("update_video_settings", "Changes a video's settings (minutes, words, short, researchNotes, guidelines).", .change,
                       [Self.videoParameter, Self.changesParameter]) { m, input in
                let video = try m.controlVideo(input)
                m.updateVideoSettings(video.id, try JSONValue.patch(video.settings, with: try input.object("changes"), name: "settings"))
                return .null
            },
            makeAction("retitle_video", "Renames a video and its folder.", .change, [Self.videoParameter, Parameter("title", .string, "New title.")]) { m, input in
                m.retitleVideo(try m.controlVideo(input).id, to: try input.string("title"))
                return .null
            },
            makeAction("reveal_video", "Shows a video's folder in Finder.", .change, [Self.videoParameter]) { m, input in
                m.revealVideoFolder(try m.controlVideo(input))
                return .null
            },
            makeAction("expand_video", "Opens a video's row in the queue view.", .change, [Self.videoParameter]) { m, input in
                m.expandedVideoID = try m.controlVideo(input).id
                return .null
            },
            makeAction("set_credits_link", "Adds the credits page link (https) to a video's kit.", .change,
                       [Self.videoParameter, Parameter("link", .string, "https link.")]) { m, input in
                m.setCreditsLink(try input.string("link"), for: try m.controlVideo(input))
                return .null
            },
            makeAction("mark_published", "Marks a video published with its YouTube link. YTA then reads its numbers after 1, 3, 7 and 28 days.", .change,
                       [Self.videoParameter, Parameter("link", .string, "The YouTube video link.")]) { m, input in
                m.markPublished(try input.string("link"), video: try m.controlVideo(input))
                return .null
            },
            makeAction("start_queue", "Starts a channel's queue: its videos run top to bottom until something needs the owner.", .change,
                       [Self.channelParameter]) { m, input in
                let record = try m.controlChannel(input)
                if !m.isQueueRunning(record) { m.toggleQueue() }
                return .object(["running": .bool(m.isQueueRunning(record))])
            },
            makeAction("pause_queue", "Pauses a channel's queue. Steps already running finish.", .change, [Self.channelParameter]) { m, input in
                let record = try m.controlChannel(input)
                if m.isQueueRunning(record) { m.toggleQueue() }
                return .object(["running": .bool(m.isQueueRunning(record))])
            },
            makeAction("refresh_published_stats", "Reads the public numbers of published videos whose next checkpoint has passed.", .change) { m, _ in
                await m.followUpPublishedVideos()
                return .null
            },
            makeAction("clear_old_working_files", "Clears bulky working files of long-finished videos, as Settings allows.", .destructive) { m, _ in
                await m.clearOldWorkingFiles()
                return .null
            },
        ]
    }

    private func toolActions() -> [ControlAction] {
        let tools = HealthItemID.allCases.map(\.rawValue)
        return [
            makeAction("get_health", "Tools YTA needs (Homebrew, Node, ffmpeg, Whisper, Remotion, Claude Code, Codex, OpenCode), their versions and updates.", .read) { m, _ in
                .object([
                    "health": try m.json(m.health),
                    "updates": try m.json(m.toolUpdates),
                    "busy": .array(m.busyTools.map { .string($0.rawValue) }),
                    "whisper_ready": .bool(m.whisper != nil),
                    "tools": .array(try HealthItemID.allCases.compactMap { m.status(of: $0) }.map { try m.json($0) }),
                ])
            },
            makeAction("run_health_check", "Looks for every tool again.", .change) { m, _ in
                await m.runHealthCheck()
                return try m.json(m.health)
            },
            makeAction("check_tool_updates", "Checks every tool for a newer version.", .change) { m, _ in
                await m.checkToolUpdates()
                return try m.json(m.toolUpdates)
            },
            makeAction("update_tool", "Updates one tool to its latest version.", .change, [Parameter("tool", .oneOf(tools), "The tool.")]) { m, input in
                guard let id = HealthItemID(rawValue: try input.string("tool")) else { throw ControlError.invalid("Unknown tool.") }
                await m.updateTool(id)
                return .null
            },
            makeAction("install_tool", "Installs one tool. Homebrew opens Terminal, because its installer asks for the Mac's password.", .change,
                       [Parameter("tool", .oneOf(tools), "The tool.")]) { m, input in
                guard let id = HealthItemID(rawValue: try input.string("tool")) else { throw ControlError.invalid("Unknown tool.") }
                await m.installTool(id)
                return .null
            },
            makeAction("download_whisper_model", "Downloads Whisper's speech model (about 470 MB) if it is missing.", .change) { m, _ in
                await m.ensureWhisperModel()
                return .null
            },
        ]
    }

    private func settingsActions() -> [ControlAction] {
        [
            makeAction("get_settings", "App settings, and which keys are saved (key values are never shown).", .read) { m, _ in
                .object([
                    "settings": try m.json(m.settings),
                    "keys_saved": .object(Dictionary(uniqueKeysWithValues: SecretKey.serviceKeys.map { ($0.rawValue, JSONValue.bool(m.secrets.has($0))) })),
                    "storage": .string(m.paths.storageRoot.path),
                ])
            },
            makeAction("update_settings", "Changes app settings (fields as in get_settings' settings, nested objects merge).", .change,
                       [Self.changesParameter]) { m, input in
                let changed = try JSONValue.patch(m.settings, with: try input.object("changes"), name: "settings")
                m.updateSettings { $0 = changed }
                return try m.json(m.settings)
            },
            makeAction("finish_first_run", "Closes the first-run health check for good.", .change) { m, _ in
                m.finishFirstRun()
                return .null
            },
        ]
    }

    private func youtubeActions() -> [ControlAction] {
        [
            makeAction("get_youtube_quota", "Today's YouTube Data API units used and left.", .read) { m, _ in
                let usage = m.quotaUsage
                return .object(["used": .number(Double(usage.used)), "limit": .number(Double(usage.limit)), "remaining": .number(Double(usage.remaining)),
                                "searches_left": .number(Double(usage.searchesLeft)), "resets_at": .string(usage.resetsAt.ISO8601Format()),
                                "has_key": .bool(m.hasYouTubeKey)])
            },
            makeAction("check_handle", "Checks whether a YouTube @handle looks free.", .change, [Parameter("handle", .string, "With or without @.")]) { m, input in
                try m.json(await m.checkHandle(try input.string("handle")))
            },
            makeAction("youtube_snapshot", "Reads a YouTube channel's public numbers and recent videos. save keeps it in the selected channel's research.", .change, [
                Parameter("link", .string, "Channel link or @handle."), .optional("save", .boolean, "Save into the channel's research folder."),
                Self.channelParameter,
            ]) { m, input in
                guard let snapshot = await m.takeSnapshot(try input.string("link")) else { return .null }
                if try input.bool("save", default: false) {
                    _ = try m.controlChannel(input)
                    m.saveSnapshot(snapshot)
                }
                return try m.json(snapshot)
            },
        ]
    }

    private func windowActions() -> [ControlAction] {
        [
            makeAction("show", "Opens a sheet or panel in the YTA window.", .change, [
                Parameter("screen", .oneOf(["new_channel", "import_channel", "youtube_lookup", "health_check", "inspector", "settings", "window"]), "What to open."),
            ]) { m, input in
                switch try input.string("screen") {
                case "new_channel": m.showNewChannel = true
                case "import_channel": m.showImportChannel = true
                case "youtube_lookup": m.showYouTubeLookup = true
                case "health_check": m.showHealthCheck = true
                case "inspector": m.showInspector = true
                case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                default: break
                }
                NSApp.activate()
                return .null
            },
        ]
    }
}
