import ChannelStore
import DesignSystem
import Support
import SwiftUI

/// New channel ("Find me a niche" or "I have a niche") and Import channel (section 6.4).
struct NewChannelSheet: View {
    enum Mode { case new, `import` }
    enum NicheChoice: String, CaseIterable, Identifiable {
        case have, find
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @StateObject private var form = NewChannelForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(mode == .new ? "New channel" : "Import a channel")
                    .font(Typography.title)
                Text(mode == .new
                     ? "You can rename it after the Name step."
                     : "YTA reads the channel's public record and drafts its profile.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding([.horizontal, .top], Spacing.l)

            Form {
                if mode == .new {
                    Section {
                        Picker("Niche", selection: $form.nicheChoice) {
                            Text("I have a niche").tag(NicheChoice.have)
                            Text("Find me a niche").tag(NicheChoice.find)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if form.nicheChoice == .have {
                            TextField("Niche", text: $form.niche, prompt: Text("Unsolved maritime mysteries"), axis: .vertical)
                                .lineLimit(2...4)
                        } else {
                            Text("The Niche step researches candidates with real YouTube numbers and gives you a shortlist.")
                                .font(Typography.callout)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Section {
                        TextField("Working name", text: $form.workingName, prompt: Text("Untitled channel"))
                    }
                } else {
                    Section {
                        TextField("Channel", text: $form.link, prompt: Text("@handle or a channel or video link"))
                        TextField("Working name", text: $form.workingName, prompt: Text("Used for the folder until the snapshot runs"))
                    }
                }
                Section {
                    Picker("Format", selection: $form.format) {
                        ForEach(ChannelFormat.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Language", text: $form.language)
                    TextField("Main country", text: $form.country, prompt: Text("Any, aimed at high ad rates"))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .new ? "Create Channel" : "Import") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(!canCreate)
            }
            .padding(Spacing.l)
        }
        .frame(width: 480)
        .background(Palette.surface)
    }

    private var canCreate: Bool {
        switch mode {
        case .new: form.nicheChoice == .find || !form.niche.trimmingCharacters(in: .whitespaces).isEmpty
        case .import: !form.link.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func create() {
        let trimmedName = form.workingName.trimmingCharacters(in: .whitespaces)
        let trimmedLink = form.link.trimmingCharacters(in: .whitespaces)
        let name: String
        if !trimmedName.isEmpty {
            name = trimmedName
        } else if mode == .import {
            name = Self.nameFromLink(trimmedLink)
        } else {
            name = "Untitled channel"
        }
        model.createChannel(NewChannelRequest(
            workingName: name,
            niche: mode == .new && form.nicheChoice == .have ? form.niche.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            format: format,
            language: form.language.trimmingCharacters(in: .whitespaces).isEmpty ? "English" : form.language,
            country: form.country.trimmingCharacters(in: .whitespaces).isEmpty ? nil : form.country,
            origin: mode == .new ? .new : .imported,
            importLink: mode == .import ? trimmedLink : nil,
            automation: model.settings.automationDefault
        ))
        dismiss()
    }

    /// "@deepwater" or "youtube.com/@deepwater" becomes "deepwater".
    static func nameFromLink(_ link: String) -> String {
        if let at = link.range(of: "@") {
            let handle = link[at.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
            if !handle.isEmpty { return String(handle) }
        }
        return "Imported channel"
    }
}

/// The sheet's fields. Kept in an object because `@State` needs Xcode (see LocalState).
@MainActor
final class NewChannelForm: ObservableObject {
    @Published var nicheChoice: NewChannelSheet.NicheChoice = .have
    @Published var workingName = ""
    @Published var niche = ""
    @Published var link = ""
    @Published var format: ChannelFormat = .longForm
    @Published var language = "English"
    @Published var country = ""
}
