import AppKit
import Brand
import DesignSystem
import SwiftUI
import Workflow

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

// MARK: Brand boards

/// The three boards of section 7.4. Picking one writes `brand/brand.json`.
struct BrandBoardsView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let file: BrandFile

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(file.directions.enumerated()), id: \.offset) { index, direction in
                BrandBoard(name: file.name, direction: direction) {
                    model.chooseBrand(index, for: node)
                }
            }
            HStack {
                Button("Discard") { model.discard(node) }
                Spacer()
                Button("Three More") { model.discard(node); model.run(node) }
            }
        }
    }
}

private struct BrandBoard: View {
    let name: String
    let direction: BrandDirection
    let pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // The board itself: the brand as it will look.
            VStack(spacing: Spacing.xs) {
                Text(direction.markStyle == .monogram ? initials(of: name) : name)
                    .font(.custom(direction.typeface, size: direction.markStyle == .monogram ? 44 : 30).weight(.bold))
                    .foregroundStyle(direction.text.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Rectangle().fill(direction.accent.color).frame(width: 36, height: 3)
                Text(direction.tagline)
                    .font(.custom(direction.typeface, size: 13))
                    .foregroundStyle(direction.text.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.l)
            .background(direction.background.color, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))

            HStack(spacing: Spacing.xs) {
                ForEach([direction.background, direction.text, direction.accent] + (direction.support.map { [$0] } ?? []), id: \.self) { colour in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4).fill(colour.color).frame(height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.border))
                        Text(colour.hex).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(direction.name).font(Typography.headline)
                    Text("\(direction.typeface) · \(direction.markStyle.title) · \(String(format: "%.1f", direction.textContrast)) to 1")
                        .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("Use This", action: pick)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
            if !direction.why.isEmpty {
                Text(direction.why).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            if direction.adjustedForContrast {
                Label("Text colour adjusted to reach 4.5 to 1", systemImage: "circle.lefthalf.filled")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
        }
        .card()
    }
}

// MARK: Profile picture

struct AvatarPickerView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let set: AvatarSet

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: Spacing.s)]

    var body: some View {
        let chosen = set.items.first { $0.variant.id == set.chosen } ?? set.items[0]
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let image = model.channelImage(chosen.file) {
                HStack(alignment: .bottom, spacing: Spacing.m) {
                    ForEach(AvatarGeometry.previewSizes, id: \.0) { label, size in
                        VStack(spacing: Spacing.xxs) {
                            Image(nsImage: image).resizable().interpolation(.high)
                                .frame(width: size / 2 + 8, height: size / 2 + 8)
                                .clipShape(Circle())
                            Text(label).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .card()
            }
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                ForEach(set.items, id: \.variant.id) { item in
                    Button {
                        model.chooseAvatar(item.variant.id, for: node)
                    } label: {
                        VStack(spacing: Spacing.xxs) {
                            Group {
                                if let image = model.channelImage(item.file) {
                                    Image(nsImage: image).resizable().interpolation(.high)
                                } else {
                                    Circle().fill(item.variant.background.color)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(item.variant.id == set.chosen ? Palette.accent : Palette.border,
                                                           lineWidth: item.variant.id == set.chosen ? 2.5 : 1))
                            Text(item.variant.label).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("800 × 800 PNG. The letters sit in the middle 70%, so YouTube's circle never cuts them. A 300 × 300 watermark is saved too.")
                .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            HStack {
                Button("Discard") { model.discard(node) }
                Spacer()
                Button("Approve") { model.approve(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
    }
}

// MARK: Banner

struct BannerPreviewView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let result: BannerResult
    let run: RunRecord

    @StateObject private var device = LocalState(BannerGeometry.Device.desktop)
    @StateObject private var name = LocalState("")
    @StateObject private var tagline = LocalState("")
    @StateObject private var schedule = LocalState("")
    @StateObject private var loaded = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Picker("Device", selection: $device.value) {
                ForEach(BannerGeometry.Device.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let image = model.channelImage(result.file), let cropped = crop(image, to: device.value.crop) {
                Image(nsImage: cropped).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.border))
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(result.checks, id: \.name) { check in
                    Label("\(check.name): \(check.detail)", systemImage: check.passed ? "checkmark.circle" : "xmark.circle")
                        .font(Typography.caption)
                        .foregroundStyle(check.passed ? Palette.success : Palette.danger)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                TextField("Name", text: $name.value).textFieldStyle(.roundedBorder)
                TextField("Tagline", text: $tagline.value).textFieldStyle(.roundedBorder)
                TextField("Schedule line (optional), for example “New videos every Friday”", text: $schedule.value)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Discard") { model.discard(node) }
                Button("Redraw") {
                    model.redrawBanner(node, text: BannerText(name: name.value, tagline: tagline.value.isEmpty ? nil : tagline.value,
                                                              schedule: schedule.value.isEmpty ? nil : schedule.value))
                }
                .disabled(name.value.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if run.stage == .awaitingApproval {
                    Button("Approve") { model.approve(node) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                }
            }
        }
        .onAppear {
            guard !loaded.value else { return }
            loaded.value = true
            name.value = result.text.name
            tagline.value = result.text.tagline ?? ""
            schedule.value = result.text.schedule ?? ""
        }
    }

    private func crop(_ image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let part = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: part, size: rect.size)
    }
}
