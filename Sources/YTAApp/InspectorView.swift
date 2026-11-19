import Canvas
import ChannelStore
import DesignSystem
import Support
import SwiftUI
import Workflow

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let node = model.selectedNode {
                NodeInspector(node: node)
                    .id(node.id)
            } else if let channel = model.selectedChannel {
                ChannelInspector(channel: channel)
                    .id(channel.id)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "sidebar.right", description: Text("Pick a channel or a step."))
            }
        }
        .background(Palette.surface)
    }
}

// MARK: - Node

struct NodeInspector: View {
    @Environment(AppModel.self) private var model
    let node: Node

    @StateObject private var draft: LocalState<Node>

    init(node: Node) {
        self.node = node
        _draft = StateObject(wrappedValue: LocalState(node))
    }

    private var type: NodeType? { node.nodeType }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.s) {
                    SymbolTile(type?.symbol ?? NodeType.custom.symbol, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if node.isCustom {
                            TextField("Title", text: $draft.value.title)
                                .textFieldStyle(.plain)
                                .font(Typography.title)
                                .onSubmit(save)
                        } else {
                            Text(node.title).font(Typography.title)
                        }
                        Text(type?.summary ?? "Your own prompt and engine, writing one file.")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    StateBadge(node.state, locked: type?.lockedReason != nil)
                }
                if let reason = type?.lockedReason, node.state != .done {
                    Label(reason, systemImage: "lock")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
                if let result = node.resultSummary {
                    LabeledContent("Result", value: result)
                }
                LabeledContent("Done by", value: workerText)
            }

            if model.canRun(node) || node.state == .needsYou {
                RunSection(node: node)
            }

            if node.type == "setupKit", let checklist = model.setupChecklist() {
                SetupChecklistView(checklist: checklist)
            }

            if draft.value.engine != nil {
                Section("Engine") {
                    Picker("Tool", selection: engineTool) {
                        ForEach(EngineID.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Model", text: engineModel, prompt: Text("Plan default"))
                    Picker("Effort", selection: engineEffort) {
                        Text("Plan default").tag(Effort?.none)
                        ForEach(Effort.allCases, id: \.self) { Text($0.rawValue).tag(Effort?.some($0)) }
                    }
                }
                Section {
                    TextEditor(text: promptBinding)
                        .font(Typography.mono)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Prompt")
                } header: {
                    Text("Prompt")
                } footer: {
                    Text(node.isCustom ? "What this step should produce." : "Leave empty to use the built-in prompt.")
                }
            }

            Section("Approval") {
                Picker("Ask me to approve", selection: $draft.value.approval) {
                    Text("Always").tag(ApprovalRule.always)
                    Text("Follow the channel's dial").tag(ApprovalRule.byDial)
                    Text("Never").tag(ApprovalRule.never)
                }
                .disabled(!node.isCustom && type?.approval == .always)
            }

            Section("Files") {
                if node.isCustom {
                    TextField("Writes", text: outputBinding, prompt: Text("profile/notes.md"))
                    TextField("Reads", text: inputsBinding, prompt: Text("profile/niche.md, brand/brand.json"))
                } else {
                    FileList(title: "Reads", files: node.inputs)
                    FileList(title: "Writes", files: node.outputs)
                }
            }

            if let checks = type?.checks, !checks.isEmpty {
                Section {
                    ForEach(checks, id: \.self) { check in
                        Label(check, systemImage: "checkmark.shield")
                            .foregroundStyle(Palette.textSecondary)
                    }
                } header: {
                    Text("Checks")
                } footer: {
                    Text("Built-in checks always run.")
                }
            }

            let instructionFiles = node.outputs.filter(ChannelLayout.isInstructionFile)
            if !instructionFiles.isEmpty {
                Section("History") {
                    ForEach(instructionFiles, id: \.self) { file in
                        HistoryList(file: file)
                    }
                }
            }

            Section {
                HStack {
                    Button("Redo") { model.redo(node) }
                    Button("Save as Template") { model.saveAsTemplate(node) }
                    Spacer()
                    Button("Remove", role: .destructive) { model.requestRemove(node) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: draft.value) { _, _ in save() }
    }

    private func save() {
        guard draft.value != node else { return }
        model.updateNode(draft.value)
    }

    private var workerText: String {
        switch type?.worker {
        case .owner: "You"
        case .app: "YTA"
        case .llm, .none: "An LLM, checked by YTA"
        }
    }

    private var engineTool: Binding<EngineID> {
        Binding(get: { draft.value.engine?.tool ?? .claude }, set: { draft.value.engine?.tool = $0 })
    }

    private var engineModel: Binding<String> {
        Binding(get: { draft.value.engine?.model ?? "" }, set: { draft.value.engine?.model = $0.isEmpty ? nil : $0 })
    }

    private var engineEffort: Binding<Effort?> {
        Binding(get: { draft.value.engine?.effort }, set: { draft.value.engine?.effort = $0 })
    }

    private var promptBinding: Binding<String> {
        Binding(get: { draft.value.promptTemplate ?? "" }, set: { draft.value.promptTemplate = $0.isEmpty ? nil : $0 })
    }

    private var outputBinding: Binding<String> {
        Binding(get: { draft.value.outputs.first ?? "" }, set: { draft.value.outputs = $0.isEmpty ? [] : [$0.trimmingCharacters(in: .whitespaces)] })
    }

    private var inputsBinding: Binding<String> {
        Binding(
            get: { draft.value.inputs.joined(separator: ", ") },
            set: { draft.value.inputs = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }
}

struct FileList: View {
    let title: String
    let files: [String]

    var body: some View {
        LabeledContent(title) {
            if files.isEmpty {
                Text("Nothing").foregroundStyle(Palette.textTertiary)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(files, id: \.self) { Text($0).font(Typography.mono) }
                }
            }
        }
    }
}

struct HistoryList: View {
    @Environment(AppModel.self) private var model
    let file: String

    var body: some View {
        let _ = model.diskRevision
        let snapshots = model.history(for: file)
        DisclosureGroup {
            if snapshots.isEmpty {
                Text("No saved versions yet").foregroundStyle(Palette.textTertiary)
            }
            ForEach(snapshots.prefix(20)) { snapshot in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                        Text(snapshot.source).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    Button("Restore") { model.restore(snapshot) }
                        .disabled(snapshot.id == snapshots.first?.id)
                }
            }
        } label: {
            HStack {
                Text(file).font(Typography.mono)
                Spacer()
                Text("\(snapshots.count)").foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

// MARK: - Channel

struct ChannelInspector: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRecord

    @StateObject private var name: LocalState<String>
    @StateObject private var group: LocalState<String>
    @StateObject private var country: LocalState<String>
    @StateObject private var language: LocalState<String>

    init(channel: ChannelRecord) {
        self.channel = channel
        _name = StateObject(wrappedValue: LocalState(channel.manifest.name))
        _group = StateObject(wrappedValue: LocalState(channel.manifest.group ?? ""))
        _country = StateObject(wrappedValue: LocalState(channel.manifest.country ?? ""))
        _language = StateObject(wrappedValue: LocalState(channel.manifest.language))
    }

    var body: some View {
        let _ = model.diskRevision
        let sources = channel.folder.sources()
        Form {
            Section("Channel") {
                TextField("Name", text: $name.value)
                    .onSubmit { model.updateManifest { $0.name = name.value } }
                TextField("Group", text: $group.value, prompt: Text("None"))
                    .onSubmit { model.updateManifest { $0.group = group.value.isEmpty ? nil : group.value } }
                Picker("Format", selection: Binding(get: { channel.manifest.format }, set: { value in model.updateManifest { $0.format = value } })) {
                    ForEach(ChannelFormat.allCases) { Text($0.title).tag($0) }
                }
                TextField("Language", text: $language.value)
                    .onSubmit { model.updateManifest { $0.language = language.value } }
                TextField("Main country", text: $country.value, prompt: Text("Any"))
                    .onSubmit { model.updateManifest { $0.country = country.value.isEmpty ? nil : country.value } }
            }

            Section {
                Picker("Automation", selection: Binding(get: { channel.manifest.automation }, set: { value in model.updateManifest { $0.automation = value } })) {
                    ForEach(AutomationLevel.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("The final check before a video is finished always runs.")
            }

            Section {
                Toggle("Stock footage", isOn: sourceBinding(sources, \.stockFootage))
                Toggle("Free online media", isOn: sourceBinding(sources, \.freeOnlineMedia))
                Toggle("AI images", isOn: sourceBinding(sources, \.aiImages))
                Toggle("AI video", isOn: sourceBinding(sources, \.aiVideo))
                    .disabled(true)
                    .help("No AI video provider is chosen yet")
                Toggle("Screenshots and snippets", isOn: sourceBinding(sources, \.screenshotsAndSnippets))
                Toggle("AI voice", isOn: sourceBinding(sources, \.aiVoice))
                Toggle("Share-alike licences (CC BY-SA)", isOn: sourceBinding(sources, \.allowShareAlike))
                Toggle("Fair-use media", isOn: sourceBinding(sources, \.fairUse))
            } header: {
                Text("Production sources")
            } footer: {
                Text("Fair-use media needs real commentary or transformation. It is off by default.")
            }

            Section {
                LabeledContent("Folder") {
                    Text(channel.folder.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Typography.mono)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") { model.revealSelectedChannel() }
                    Spacer()
                    Button("Reset Setup Steps") { model.resetSetupRow() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func sourceBinding(_ current: SourcesConfig, _ keyPath: WritableKeyPath<SourcesConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { value in model.updateSources { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Running a step

/// Run, progress, the draft waiting for approval, and the last error (section 5.2).
struct RunSection: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        let run = model.latestRun(for: node)
        Section {
            if model.isRunning(node) {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(lastLine)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Stop") { model.stop(node) }
                }
            } else if let skills = model.pendingSkills(for: node) {
                SkillReviewView(node: node, review: skills)
            } else if let niches = model.pendingNiches(for: node) {
                NicheShortlistView(node: node, list: niches)
            } else if let names = model.pendingNames(for: node) {
                NamePickerView(node: node, file: names)
            } else if let brand = model.pendingBrand(for: node) {
                BrandBoardsView(node: node, file: brand)
            } else if let avatars = model.pendingAvatars(for: node) {
                AvatarPickerView(node: node, set: avatars)
            } else if let banner = model.bannerResult(for: node) {
                BannerPreviewView(node: node, result: banner.0, run: banner.1)
            } else if let run, run.stage == .awaitingApproval, let draft = model.draft(for: run) {
                ForEach(draft.files.keys.sorted(), id: \.self) { file in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(file).font(Typography.mono).foregroundStyle(Palette.textTertiary)
                        ScrollView {
                            Text(draft.files[file] ?? "")
                                .font(Typography.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 120, maxHeight: 260)
                    }
                }
                HStack {
                    Button("Discard") { model.discard(node) }
                    Button("Run Again") { model.discard(node); model.run(node) }
                    Spacer()
                    Button("Approve") { model.approve(node) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                }
            } else {
                if let run, run.stage == .failed, let error = run.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.danger)
                }
                if node.type == "niche" {
                    NicheBriefView(node: node)
                } else if node.type == "interview" {
                    InterviewView(node: node)
                } else {
                HStack {
                    if let run, let usage = run.engine {
                        Text("Last run on \(usage.tool.displayName)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    Button(node.state == .done ? "Run Again" : "Run") { model.run(node) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .disabled(!model.canRun(node))
                }
                }
            }
        } header: {
            Text(run?.stage == .awaitingApproval && !model.isRunning(node) ? "Draft to review" : "Run")
        } footer: {
            if let run, run.stage == .awaitingApproval, !model.isRunning(node) {
                Text("Nothing is saved to the channel until you approve.")
            }
        }
    }

    private var lastLine: String {
        model.activity.last { $0.text.hasPrefix("\(node.title):") }?.text
            .replacingOccurrences(of: "\(node.title): ", with: "") ?? "Starting…"
    }
}
