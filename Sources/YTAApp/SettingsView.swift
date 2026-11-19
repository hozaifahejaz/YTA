import AppKit
import DesignSystem
import Engines
import Secrets
import Support
import SwiftUI
import YouTubeData

/// Settings: Engines and plan, Keys, Storage and disk, Automation defaults (section 6.4).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Engines", systemImage: "cpu") { EnginesSettings() }
            Tab("Keys", systemImage: "key") { KeysSettings() }
            Tab("Storage", systemImage: "externaldrive") { StorageSettings() }
            Tab("Automation", systemImage: "dial.medium") { AutomationSettings() }
        }
        .frame(width: 560, height: 520)
    }
}

struct EnginesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(EngineID.allCases) { engine in
                let current = model.settings.engine(engine)
                Section(engine.displayName) {
                    Toggle("Use \(engine.displayName)", isOn: binding(engine, \.enabled))
                    Picker("Plan", selection: binding(engine, \.plan)) {
                        ForEach(engine.plans, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!current.enabled)
                    TextField("Exact model", text: Binding(
                        get: { current.modelOverride ?? "" },
                        set: { value in model.updateSettings { $0.engines[engine.rawValue]?.modelOverride = value.isEmpty ? nil : value } }
                    ), prompt: Text("Use plan defaults"))
                    .disabled(!current.enabled)
                    if engine == .claude {
                        Toggle("Allow an API key", isOn: binding(engine, \.allowAPIKey))
                            .disabled(!current.enabled)
                            .help("Off means Claude Code always runs on your subscription login.")
                    }
                }
            }
            Section {
                Picker("Script writer", selection: Binding(get: { model.settings.defaultWriter }, set: { value in model.updateSettings { $0.defaultWriter = value } })) {
                    ForEach(EngineID.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("A channel or a single video can choose another writer.")
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ engine: EngineID, _ keyPath: WritableKeyPath<EngineSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings.engine(engine)[keyPath: keyPath] },
            set: { value in
                model.updateSettings {
                    var current = $0.engine(engine)
                    current[keyPath: keyPath] = value
                    $0.setEngine(engine, current)
                }
            }
        )
    }
}

struct KeysSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(SecretKey.allCases) { key in
                    KeyRow(key: key)
                }
            } footer: {
                Text("Keys are kept in your Keychain under “YTA”. They never go into a channel folder, a log or an LLM tool.")
            }
        }
        .formStyle(.grouped)
    }
}

struct KeyRow: View {
    @Environment(AppModel.self) private var model
    let key: SecretKey

    @StateObject private var value = LocalState("")
    @StateObject private var saved = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(key.title).font(Typography.headline)
                if saved.value {
                    Pill("Saved", foreground: Palette.success, background: Palette.successSoft)
                }
                Spacer()
                Link("Get a key", destination: key.signupURL)
                    .font(Typography.callout)
            }
            Text(key.purpose)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            if key == .youtubeDataAPI && saved.value {
                QuotaLine(usage: model.quotaUsage, hasKey: true)
            }
            HStack {
                SecureField(saved.value ? "Replace the saved key" : "Paste the key", text: $value.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(value.value.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved.value {
                    Button("Remove", role: .destructive) {
                        do {
                            try model.secrets.delete(key)
                            saved.value = false
                        } catch {
                            model.report(error)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .onAppear { saved.value = model.secrets.has(key) }
    }

    private func save() {
        let trimmed = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try model.secrets.save(trimmed, for: key)
            value.value = ""
            saved.value = true
        } catch {
            model.report(error)
        }
    }
}

struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @StateObject private var usage = LocalState<[(String, Int64)]>([])

    var body: some View {
        Form {
            Section {
                LabeledContent("Channels folder") {
                    Text(model.paths.storageRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Typography.mono)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change…", action: choose)
                    Button("Show in Finder") { model.revealStorage() }
                    Spacer()
                    if model.settings.storagePath != nil {
                        Button("Use Default") { model.updateSettings { $0.storagePath = nil } }
                    }
                }
            } footer: {
                Text("Moving storage does not move existing channels. Move the folder in Finder first, then choose its new place here.")
            }
            Section("Space used") {
                if usage.value.isEmpty {
                    Text("No channels yet").foregroundStyle(Palette.textTertiary)
                }
                ForEach(usage.value, id: \.0) { name, bytes in
                    LabeledContent(name, value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
            }
            Section {
                Picker("Clear working files", selection: Binding(
                    get: { model.settings.clearWorkingFilesAfterDays ?? 0 },
                    set: { value in model.updateSettings { $0.clearWorkingFilesAfterDays = value == 0 ? nil : value } }
                )) {
                    Text("Never").tag(0)
                    Text("7 days after finishing").tag(7)
                    Text("30 days after finishing").tag(30)
                    Text("90 days after finishing").tag(90)
                }
            } footer: {
                Text("Clears downloaded media, renders and per-beat audio. The ledger, script, timeline and kit are always kept.")
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = model.paths.storageRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.updateSettings { $0.storagePath = url.path }
        }
    }

    private func measure() async {
        let channels = model.channels.map { ($0.manifest.name, $0.folder.root) }
        usage.value = await Task.detached {
            channels.map { name, root in (name, Self.size(of: root)) }
        }.value
    }

    nonisolated static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

struct AutomationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("New channels", selection: Binding(get: { model.settings.automationDefault }, set: { value in model.updateSettings { $0.automationDefault = value } })) {
                    ForEach(AutomationLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Automation")
            } footer: {
                Text("Each channel can change this. The final check always runs.")
            }
            Section {
                CapField(title: "Engine spend per video", unit: "USD", value: Binding(get: { model.settings.caps.perVideoUSD }, set: { value in model.updateSettings { $0.caps.perVideoUSD = value } }))
                CapField(title: "Engine spend per day", unit: "USD", value: Binding(get: { model.settings.caps.perDayUSD }, set: { value in model.updateSettings { $0.caps.perDayUSD = value } }))
                CapField(title: "Narration per video", unit: "characters", value: Binding(get: { model.settings.caps.perVideoVoiceCharacters.map(Double.init) }, set: { value in model.updateSettings { $0.caps.perVideoVoiceCharacters = value.map { Int($0) } } }))
                CapField(title: "Narration per day", unit: "characters", value: Binding(get: { model.settings.caps.perDayVoiceCharacters.map(Double.init) }, set: { value in model.updateSettings { $0.caps.perDayVoiceCharacters = value.map { Int($0) } } }))
            } header: {
                Text("Spending caps")
            } footer: {
                Text("The queue stops when a cap is reached. Engine spend is what the tools report for each run; on a subscription it counts against your plan, not your card. Leave a cap empty for no limit.")
            }
            Section {
                Toggle("Keep tools up to date", isOn: Binding(get: { model.settings.autoUpdateTools }, set: { value in model.updateSettings { $0.autoUpdateTools = value } }))
                if !model.outdatedTools.isEmpty {
                    Text("Updates waiting: " + model.outdatedTools.map { "\($0.id.title) \($0.latest ?? "")" }.joined(separator: ", "))
                        .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Once a day YTA checks Claude Code, Codex, OpenCode, Node.js, Remotion, ffmpeg and Whisper for updates and installs them while nothing is running, using Homebrew, npm or the tool's own updater.")
            }
            Section("Images") {
                Picker("Image route", selection: Binding(get: { model.settings.imageRoute }, set: { value in model.updateSettings { $0.imageRoute = value } })) {
                    ForEach(ImageRoute.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// An optional number: empty means no cap.
private struct CapField: View {
    let title: String
    let unit: String
    @Binding var value: Double?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Spacing.xs) {
                TextField("No cap", value: $value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text(unit).font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}
