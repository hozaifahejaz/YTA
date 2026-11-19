import ChannelStore
import DesignSystem
import Support
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                if let channel = model.selectedChannel {
                    ChannelView(channel: channel)
                } else {
                    WelcomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActivityStrip()
        }
        .sheet(isPresented: $model.showNewChannel) {
            NewChannelSheet(mode: .new)
        }
        .sheet(isPresented: $model.showImportChannel) {
            NewChannelSheet(mode: .import)
        }
        .sheet(isPresented: $model.showHealthCheck) {
            HealthCheckView()
        }
        .alert(
            model.alert?.message ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            if let suggestion = error.suggestion { Text(suggestion) }
        }
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.title ?? "this step")?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { node in
            Button("Remove", role: .destructive) { model.remove(node, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            let broken = model.setupRow?.nodesBroken(byRemoving: node.id).map(\.title) ?? []
            Text("These steps use its result and will not be able to run: \(broken.joined(separator: ", ")).")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.xs) {
                Text("Start your first channel")
                    .font(Typography.largeTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text("Each channel is one folder in \(model.paths.storageRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")), with everything that channel needs.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: Spacing.s) {
                Button("New Channel") { model.showNewChannel = true }
                    .primaryAction()
                Button("Import a Channel") { model.showImportChannel = true }
                    .controlSize(.large)
            }
        }
        .padding(Spacing.xxl)
    }
}

struct ActivityStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: model.isCheckingHealth ? "arrow.triangle.2.circlepath" : "circle.fill")
                .font(.system(size: model.isCheckingHealth ? 11 : 6))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
            Text(statusText)
                .font(Typography.callout)
                .foregroundStyle(lastIsError ? Palette.danger : Palette.textSecondary)
                .lineLimit(1)
            Spacer()
            if let summary = healthSummary {
                Button(summary) { model.showHealthCheck = true }
                    .buttonStyle(.borderless)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            Button {
                NSWorkspace.shared.open(model.paths.logs)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.textSecondary)
            .help("Open logs")
            .accessibilityLabel("Open logs")
        }
        .padding(.horizontal, Spacing.m)
        .frame(height: 30)
        .background(Palette.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var lastIsError: Bool { model.activity.last?.isError ?? false }

    private var statusText: String {
        if model.isCheckingHealth { return "Checking tools…" }
        if let last = model.activity.last, Date().timeIntervalSince(last.date) < 600 { return last.text }
        return "Nothing is running"
    }

    private var healthSummary: String? {
        guard let items = model.health?.items else { return nil }
        let missing = items.filter { $0.status == .missing }.count
        return missing == 0 ? "All tools found" : "\(missing) tool\(missing == 1 ? "" : "s") missing"
    }
}
