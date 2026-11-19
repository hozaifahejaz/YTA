import DesignSystem
import SwiftUI
import Workflow
import YouTubeData

extension AppModel {
    func pendingSkills(for node: Node) -> SkillReview? {
        guard let waiting = waitingRun(node, type: "skills") else { return nil }
        return SkillsRecipe.pending(in: waiting.0, folder: waiting.1)
    }

    func decideSkill(_ name: String, install: Bool, for node: Node) async {
        guard let waiting = waitingRun(node, type: "skills") else { return }
        do {
            try await SkillsRecipe.decide(name, install: install, in: waiting.0, folder: waiting.1, http: URLSessionHTTP())
            diskRevision += 1
        } catch {
            report(error)
        }
    }
}

/// One review card per proposed skill: source, what it adds, whether it has scripts, and its SKILL.md.
struct SkillReviewView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let review: SkillReview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if review.candidates.isEmpty {
                Text("Nothing worth adding was found. The shipped skills stay as they are.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            ForEach(review.candidates) { candidate in
                SkillCard(node: node, candidate: candidate)
            }
            HStack {
                Button("Discard") { model.discard(node) }
                Spacer()
                Button("Done") { model.approve(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(review.candidates.contains { $0.decision == nil && $0.problem == nil })
            }
            Text("Installs go into this channel's .agents/skills and .claude/skills folders, never your own setup.")
                .font(Typography.caption).foregroundStyle(Palette.textTertiary)
        }
    }
}

private struct SkillCard: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let candidate: SkillCandidate

    @StateObject private var working = LocalState(false)
    @StateObject private var showText = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.name).font(Typography.headline)
                if candidate.hasScripts {
                    Label("Contains scripts", systemImage: "terminal")
                        .font(Typography.caption).foregroundStyle(Palette.caution)
                }
                Spacer()
                if let url = URL(string: candidate.sourceURL) {
                    Link(candidate.repo, destination: url).font(Typography.caption)
                }
            }
            Text(candidate.adds).font(Typography.callout)
            Text(candidate.why).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            if let problem = candidate.problem {
                Label(problem, systemImage: "xmark.circle").font(Typography.caption).foregroundStyle(Palette.danger)
            } else {
                Text("\(candidate.files.count) files: \(candidate.files.map(\.path).prefix(6).joined(separator: ", "))")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
                if let preview = candidate.preview {
                    DisclosureGroup("SKILL.md", isExpanded: $showText.value) {
                        ScrollView {
                            Text(preview).font(Typography.mono).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                    .font(Typography.caption)
                }
                HStack {
                    if let decision = candidate.decision {
                        Text(decision == .install ? "Will be installed when you click Done" : "Skipped")
                            .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    if working.value { ProgressView().controlSize(.small) }
                    Button("Skip") { decide(false) }
                    Button("Install") { decide(true) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                }
                .disabled(working.value)
            }
        }
        .card()
    }

    private func decide(_ install: Bool) {
        working.value = true
        Task {
            await model.decideSkill(candidate.name, install: install, for: node)
            working.value = false
        }
    }
}
