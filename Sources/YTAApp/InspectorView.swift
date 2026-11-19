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

    @State private var draft: Node

    init(node: Node) {
        self.node = node
        _draft = State(initialValue: node)
    }

    private var type: NodeType? { node.nodeType }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.s) {
                    SymbolTile(type?.symbol ?? NodeType.custom.symbol, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if node.isCustom {
                            TextField("Title", text: $draft.title)
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

            if draft.engine != nil {
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
                Picker("Ask me to approve", selection: $draft.approval) {
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
        .onChange(of: draft) { _, _ in save() }
    }

    private func save() {
        guard draft != node else { return }
        model.updateNode(draft)
    }

    private var workerText: String {
        switch type?.worker {
        case .owner: "You"
        case .app: "YTA"
        case .llm, .none: "An LLM, checked by YTA"
        }
    }

    private var engineTool: Binding<EngineID> {
        Binding(get: { draft.engine?.tool ?? .claude }, set: { draft.engine?.tool = $0 })
    }

    private var engineModel: Binding<String> {
        Binding(get: { draft.engine?.model ?? "" }, set: { draft.engine?.model = $0.isEmpty ? nil : $0 })
    }

    private var engineEffort: Binding<Effort?> {
        Binding(get: { draft.engine?.effort }, set: { draft.engine?.effort = $0 })
    }

    private var promptBinding: Binding<String> {
        Binding(get: { draft.promptTemplate ?? "" }, set: { draft.promptTemplate = $0.isEmpty ? nil : $0 })
    }

    private var outputBinding: Binding<String> {
        Binding(get: { draft.outputs.first ?? "" }, set: { draft.outputs = $0.isEmpty ? [] : [$0.trimmingCharacters(in: .whitespaces)] })
    }

    private var inputsBinding: Binding<String> {
        Binding(
            get: { draft.inputs.joined(separator: ", ") },
            set: { draft.inputs = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
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

    @State private var name: String
    @State private var group: String
    @State private var country: String
    @State private var language: String

    init(channel: ChannelRecord) {
        self.channel = channel
        _name = State(initialValue: channel.manifest.name)
        _group = State(initialValue: channel.manifest.group ?? "")
        _country = State(initialValue: channel.manifest.country ?? "")
        _language = State(initialValue: channel.manifest.language)
    }

    var body: some View {
        let _ = model.diskRevision
        let sources = channel.folder.sources()
        Form {
            Section("Channel") {
                TextField("Name", text: $name)
                    .onSubmit { model.updateManifest { $0.name = name } }
                TextField("Group", text: $group, prompt: Text("None"))
                    .onSubmit { model.updateManifest { $0.group = group.isEmpty ? nil : group } }
                Picker("Format", selection: Binding(get: { channel.manifest.format }, set: { value in model.updateManifest { $0.format = value } })) {
                    ForEach(ChannelFormat.allCases) { Text($0.title).tag($0) }
                }
                TextField("Language", text: $language)
                    .onSubmit { model.updateManifest { $0.language = language } }
                TextField("Main country", text: $country, prompt: Text("Any"))
                    .onSubmit { model.updateManifest { $0.country = country.isEmpty ? nil : country } }
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
