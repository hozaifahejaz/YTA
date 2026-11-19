import AVFoundation
import DesignSystem
import SwiftUI
import Voice
import Workflow

extension AppModel {
    func pendingVoices(for node: Node) -> [VoiceOption]? {
        guard let waiting = waitingRun(node, type: "voice") else { return nil }
        return VoicePickRecipe.pending(in: waiting.0, folder: waiting.1)
    }

    func chooseVoice(_ id: String, speed: Double, for node: Node) {
        guard let waiting = waitingRun(node, type: "voice") else { return }
        do {
            try VoicePickRecipe.choose(id, speed: speed, in: waiting.0, folder: waiting.1)
            diskRevision += 1
        } catch {
            report(error)
        }
    }

    func chosenVoiceID(for node: Node) -> String? {
        guard let waiting = waitingRun(node, type: "voice"), let draft = RunStore(folder: waiting.1).draft(for: waiting.0),
              let text = draft.files[VoiceChoice.path],
              let choice = try? JSONDecoder().decode(VoiceChoice.self, from: Data(text.utf8)) else { return nil }
        return choice.voiceID
    }
}

/// Plays one preview at a time.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published var playing: String?
    private var player: AVPlayer?

    func toggle(_ voice: VoiceOption) {
        if playing == voice.id {
            player?.pause()
            playing = nil
            return
        }
        guard let address = voice.previewURL, let url = URL(string: address) else { return }
        player = AVPlayer(url: url)
        player?.play()
        playing = voice.id
    }

    func stop() {
        player?.pause()
        playing = nil
    }
}

/// Voices for the channel's language, each with a sample. Only v4 voices are listed (section 7.5).
struct VoicePickView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let voices: [VoiceOption]

    @StateObject private var player = PreviewPlayer()
    @StateObject private var speed = LocalState(1.0)
    @StateObject private var filter = LocalState("")

    private var shown: [VoiceOption] {
        let query = filter.value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return voices }
        return voices.filter { voice in
            [voice.name, voice.gender, voice.accent, voice.category, voice.provider].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }
    }

    var body: some View {
        let chosen = model.chosenVoiceID(for: node)
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField("Filter by name, accent or style", text: $filter.value)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: Spacing.xxs) {
                    ForEach(shown) { voice in
                        row(voice, chosen: voice.id == chosen)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)
            HStack {
                Text("Speed").font(Typography.callout)
                Slider(value: $speed.value, in: 0.8...1.2, step: 0.05)
                Text(String(format: "%.2f×", speed.value)).font(Typography.mono).foregroundStyle(Palette.textSecondary)
            }
            HStack {
                Button("Discard") { player.stop(); model.discard(node) }
                Spacer()
                Button("Use This Voice") {
                    player.stop()
                    if let chosen { model.chooseVoice(chosen, speed: speed.value, for: node) }
                    model.approve(node)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(chosen == nil)
            }
            Text("Every narration for this channel uses this voice, generated in v4 only.")
                .font(Typography.caption).foregroundStyle(Palette.textTertiary)
        }
    }

    private func row(_ voice: VoiceOption, chosen: Bool) -> some View {
        HStack(spacing: Spacing.s) {
            Button {
                player.toggle(voice)
            } label: {
                Image(systemName: player.playing == voice.id ? "stop.circle" : "play.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .disabled(voice.previewURL == nil)
            .help("Play a sample")
            .accessibilityLabel(player.playing == voice.id ? "Stop sample of \(voice.name)" : "Play sample of \(voice.name)")
            VStack(alignment: .leading, spacing: 0) {
                Text(voice.name).font(Typography.body)
                Text([voice.provider, voice.gender, voice.accent, voice.category].compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            if chosen { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
        }
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(chosen ? Palette.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.chooseVoice(voice.id, speed: speed.value, for: node) }
    }
}
