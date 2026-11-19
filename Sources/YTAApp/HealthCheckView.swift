import DesignSystem
import Engines
import SwiftUI

/// First-run and on-demand check for every tool YTA needs (section 6.4).
struct HealthCheckView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Health check").font(Typography.title)
                Text("YTA drives tools you already have. Here is what it found on this Mac.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(Spacing.l)

            ScrollView {
                VStack(spacing: Spacing.xs) {
                    ForEach(HealthItemID.allCases) { id in
                        HealthRow(id: id, item: model.health?.items.first { $0.id == id }, checking: model.isCheckingHealth)
                    }
                }
                .padding(.horizontal, Spacing.l)
            }
            .frame(minHeight: 360)

            HStack {
                if model.isCheckingHealth {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                } else if let date = model.health?.checkedAt {
                    Text("Checked \(date.formatted(date: .omitted, time: .shortened))")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                Button("Check Again") { Task { await model.runHealthCheck() } }
                    .disabled(model.isCheckingHealth)
                Button("Continue") {
                    model.finishFirstRun()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
            }
            .padding(Spacing.l)
        }
        .frame(width: 560, height: 560)
        .background(Palette.surface)
    }
}

struct HealthRow: View {
    let id: HealthItemID
    let item: HealthItem?
    let checking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            statusIcon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(id.title).font(Typography.headline)
                    if id.required {
                        Text("Required").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    if let version = item?.version {
                        Text(version).font(Typography.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    } else if let detail = item?.detail, item?.status != .missing {
                        Text(detail).font(Typography.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
                Text(id.purpose).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                if item?.status == .missing, let fix = id.fix {
                    if fix.hasPrefix("npm ") {
                        CopyableCommand(fix)
                    } else {
                        Text(fix).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .padding(Spacing.s)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item?.status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).accessibilityLabel("Found")
        case .missing:
            Image(systemName: "xmark.circle").foregroundStyle(Palette.danger).accessibilityLabel("Missing")
        case .warning:
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.caution).accessibilityLabel("Needs attention")
        case .checking, .none:
            if checking { ProgressView().controlSize(.small) } else {
                Image(systemName: "circle.dashed").foregroundStyle(Palette.textTertiary).accessibilityLabel("Not checked")
            }
        }
    }
}
