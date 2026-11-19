import ChannelStore
import Engines
import Foundation
import Media
import Support
import YouTubeData

/// The media chosen for one shot, with alternatives for the review board.
public struct PlannedShot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { shot }
    public var shot: String
    public var assetID: String?
    /// The file inside the video's Working files.
    public var file: String?
    /// Set when no good media was found: "textCard", "aiImage" or "ask".
    public var filler: String?
    public var alternatives: [MediaCandidate]
    public var note: String?
}

/// `media.json`: the review board's rows (section 8.4, Review board).
public struct MediaPlan: Codable, Equatable, Sendable {
    public static let file = "media.json"
    public var schemaVersion = 1
    public var videoID: String
    public var rankedBy: String
    public var shots: [PlannedShot]
}

/// Assets used in each video, so reuse across videos stays limited (`library/used-assets.json`).
public struct UsedAssets: Codable, Sendable {
    public static let path = "library/used-assets.json"
    public static let maxVideos = 2
    public var assets: [String: [String]] = [:]

    public static func load(_ folder: ChannelFolder) -> UsedAssets {
        (try? folder.readJSON(UsedAssets.self, path)) ?? UsedAssets()
    }

    public func tooOften(_ id: String, in video: String) -> Bool {
        (assets[id] ?? []).filter { $0 != video }.count >= Self.maxVideos
    }
}

/// Section 8.4, Finding media and Choosing: the app searches every source, keeps only accepted
/// licences and sizes, a vision model ranks the rest against the spoken line, and every chosen
/// asset gets a complete ledger entry.
public struct MediaRecipe: NodeRecipe {
    public static let perShot = 5
    public static let maxDownload = 400 * 1024 * 1024
    public var usesEngine: Bool { false }

    struct Rejection: Codable {
        var id: String
        var reason: String
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        let list = try folder.readJSON(ShotList.self, video.path(ShotList.file))
        let style = EditingStyle.load(folder)
        let config = folder.sources()
        let used = UsedAssets.load(folder)
        let order = (config.mediaOrder ?? MediaSources.order).filter { !(config.mediaOff ?? []).contains($0) }
        var sources: [MediaSource] = order.compactMap { id in
            MediaSources.make(id, http: context.http, key: MediaSources.needsKey.contains(id) ? context.mediaKey(id) : nil)
        }
        if !config.stockFootage { sources.removeAll { $0.id == "pexels" || $0.id == "pixabay" } }
        if !config.freeOnlineMedia { sources.removeAll { $0.id != "pexels" && $0.id != "pixabay" } }

        // Search: every shot gets up to five acceptable candidates.
        var rejected: [Rejection] = []
        var found: [String: [MediaCandidate]] = [:]
        var silenced: Set<String> = []
        for (number, shot) in list.shots.enumerated() {
            guard let media = shot.kind.media else { continue }
            if number % 5 == 0 { context.onProgress("\(node.title): searching for shot \(number + 1) of \(list.shots.count)") }
            var candidates: [MediaCandidate] = []
            search: for term in shot.terms {
                for source in sources where !silenced.contains(source.id) {
                    let results: [MediaCandidate]
                    do {
                        results = try await Self.cachedSearch(source, term: term, kind: MediaCandidate.Kind(rawValue: media), run: run, folder: folder)
                    } catch let error as YTAError where error.kind == .usageLimit {
                        silenced.insert(source.id)
                        context.onProgress("\(node.title): \(source.title) asked YTA to slow down, skipping it this run")
                        continue
                    } catch {
                        continue
                    }
                    for candidate in results where !candidates.contains(where: { $0.id == candidate.id }) {
                        if let reason = Self.problem(with: candidate, shot: shot, style: style, config: config, used: used, video: video.id) {
                            rejected.append(Rejection(id: candidate.id, reason: reason))
                        } else {
                            candidates.append(candidate)
                        }
                    }
                    if candidates.count >= Self.perShot { break search }
                }
            }
            found[shot.id] = Array(candidates.prefix(Self.perShot))
        }
        try folder.writeJSON(rejected, to: "\(run.folder)/rejected.json")

        // Rank with a model that can see the previews.
        var rankedBy = "search order"
        var ranking: [String: (order: [Int], watermarked: Set<Int>)] = [:]
        if context.settings.engine(.claude).enabled, found.values.contains(where: { !$0.isEmpty }) {
            do {
                ranking = try await Self.rank(list.shots, found: found, run: run, folder: folder, context: context, title: node.title)
                rankedBy = "Claude, from the previews"
            } catch let error as YTAError where error.kind == .usageLimit {
                throw error
            } catch {
                context.onProgress("\(node.title): ranking failed, using search order")
            }
        }

        // Download the best usable candidate for each shot and record it.
        var plan = MediaPlan(videoID: video.id, rankedBy: rankedBy, shots: [])
        var ledger = Ledger()
        var copies: [String: String] = [:]
        for (number, shot) in list.shots.enumerated() {
            let candidates = found[shot.id] ?? []
            let rank = ranking[shot.id]
            let order = (rank?.order ?? []).filter { candidates.indices.contains($0) } + candidates.indices.filter { !(rank?.order ?? []).contains($0) }
            var planned = PlannedShot(shot: shot.id, alternatives: candidates)
            for index in order where !(rank?.watermarked.contains(index) ?? false) {
                if number % 5 == 0 { context.onProgress("\(node.title): downloading shot \(number + 1) of \(list.shots.count)") }
                guard let got = try? await Self.fetch(candidates[index], shot: shot, style: style, run: run, folder: folder, context: context) else { continue }
                planned.assetID = got.entry.id
                planned.file = got.entry.file
                ledger.add(got.entry)
                copies[video.path(got.entry.file)] = got.local
                break
            }
            if planned.assetID == nil {
                planned.filler = shot.kind == .textCard ? "textCard" : style.filler.rawValue
                planned.note = shot.kind == .textCard ? nil : candidates.isEmpty ? "Nothing usable was found." : "No candidate passed the checks."
            }
            plan.shots.append(planned)
        }

        if let (entry, fields) = ledger.incomplete.first {
            throw YTAError(.checkFailed, "The ledger entry for \(entry.title) is missing \(fields.joined(separator: ", ")).")
        }
        let filled = plan.shots.filter { $0.assetID != nil }.count
        var summary = "\(filled) of \(plan.shots.count) shots have media"
        let fillers = plan.shots.count - filled
        if fillers > 0 { summary += ", \(fillers) use \(style.filler.title.lowercased())s" }
        return RunDraft(files: [video.path(MediaPlan.file): try encodeJSON(plan), video.path(Ledger.file): try encodeJSON(ledger)],
                        summary: summary, copies: copies)
    }

    /// Why a candidate can't be used, or nil.
    static func problem(with candidate: MediaCandidate, shot: Shot, style: EditingStyle, config: SourcesConfig, used: UsedAssets, video: String) -> String? {
        if case .rejected(let reason) = LicenceCheck.classify(name: candidate.licenceName, url: candidate.licenceURL, allowShareAlike: config.allowShareAlike) {
            return reason
        }
        if let width = candidate.width, let height = candidate.height {
            if candidate.kind == .image, width < style.resolution.width * 2 / 3 { return "Too small: \(width) × \(height)." }
            if candidate.kind == .video, height < style.resolution.height * 2 / 3 { return "Too small: \(width) × \(height)." }
        }
        if candidate.kind == .video, let duration = candidate.duration, duration < shot.length { return "Shorter than the shot." }
        let text = [candidate.title, candidate.description ?? ""].joined(separator: " ").lowercased()
        if text.contains("watermark") { return "Marked as watermarked." }
        if used.tooOften(candidate.id, in: video) { return "Already used in \(UsedAssets.maxVideos) videos." }
        return nil
    }

    static func cachedSearch(_ source: MediaSource, term: String, kind: MediaCandidate.Kind?, run: RunRecord, folder: ChannelFolder) async throws -> [MediaCandidate] {
        let path = "\(run.folder)/searches/\(source.id)-\(fingerprint("\(term)|\(kind?.rawValue ?? "")")).json"
        if let saved = try? folder.readJSON([MediaCandidate].self, path) { return saved }
        let results = try await source.search(term, kind: kind, limit: 8)
        try folder.writeJSON(results, to: path)
        return results
    }

    static func rank(_ shots: [Shot], found: [String: [MediaCandidate]], run: RunRecord, folder: ChannelFolder,
                     context: RunContext, title: String) async throws -> [String: (order: [Int], watermarked: Set<Int>)] {
        let schema = JSONValue.parse(#"""
        {"type":"object","additionalProperties":false,"required":["picks"],
         "properties":{"picks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["shot","order","watermarked"],
           "properties":{"shot":{"type":"string"},"order":{"type":"array","items":{"type":"integer","minimum":0}},
             "watermarked":{"type":"array","items":{"type":"integer","minimum":0}}}}}}}
        """#)!
        let withCandidates = shots.filter { !(found[$0.id] ?? []).isEmpty }
        var result: [String: (order: [Int], watermarked: Set<Int>)] = [:]
        for (batch, start) in stride(from: 0, to: withCandidates.count, by: 12).enumerated() {
            let group = withCandidates[start..<min(start + 12, withCandidates.count)]
            var prompt = """
            You are choosing footage for a documentary YouTube video. For each shot below, look at every candidate's preview image \
            (open the file paths; they are inside your working directory) and rank the candidates from best to worst for what is \
            being said at that moment. Prefer media that shows exactly what is said, is sharp, and has no logos, captions or watermarks. \
            List the index of any candidate with a visible watermark, logo or burned-in text in "watermarked". Leave out candidates \
            that do not fit at all.

            """
            for shot in group {
                prompt += "\n## Shot \(shot.id)\nSaid: \"\(shot.text)\"\nShould show: \(shot.see)\n"
                for (index, candidate) in (found[shot.id] ?? []).enumerated() {
                    let preview = await Self.preview(candidate, shot: shot.id, index: index, run: run, folder: folder, context: context)
                    let size = candidate.width.map { "\($0) × \(candidate.height ?? 0)" } ?? "size unknown"
                    prompt += "\(index). \(candidate.kind.rawValue), \(candidate.title) (\(candidate.source), \(size))"
                    prompt += preview.map { ", preview: \($0)" } ?? ", no preview"
                    prompt += "\n"
                }
            }
            prompt += "\nReturn JSON: {\"picks\": [{\"shot\": \"s001\", \"order\": [best index first], \"watermarked\": [indexes]}]}."
            let ids = Set(group.map(\.id))
            let answer = try await EngineAsk(tool: .claude, kind: .scoring).run(
                label: "rank-\(batch + 1)", title: title, prompt: prompt, schema: schema, run: run, folder: folder, context: context,
                check: { value in
                    let named = Set((value["picks"]?.arrayValue ?? []).compactMap { $0["shot"]?.stringValue })
                    return ids.isSubset(of: named) ? nil : "Rank every shot: \(ids.subtracting(named).sorted().joined(separator: ", ")) are missing."
                })
            for pick in answer["picks"]?.arrayValue ?? [] {
                guard let shot = pick["shot"]?.stringValue else { continue }
                result[shot] = ((pick["order"]?.arrayValue ?? []).compactMap(\.intValue),
                                Set((pick["watermarked"]?.arrayValue ?? []).compactMap(\.intValue)))
            }
        }
        return result
    }

    /// Saves a small preview in the run folder for the ranking model to look at.
    static func preview(_ candidate: MediaCandidate, shot: String, index: Int, run: RunRecord, folder: ChannelFolder, context: RunContext) async -> String? {
        let path = "\(run.folder)/previews/\(shot)-\(index).jpg"
        if folder.exists(path) { return path }
        guard let address = candidate.previewURL ?? (candidate.kind == .image ? candidate.fileURL : nil), let url = URL(string: address),
              let response = try? await context.http.get(url, headers: ["User-Agent": MediaSources.userAgent]),
              (200..<300).contains(response.status), !response.data.isEmpty, response.data.count < 20_000_000 else { return nil }
        guard (try? folder.write(response.data, to: path)) != nil else { return nil }
        return path
    }

    /// Downloads the full file into the run folder, checks it, and builds its ledger entry.
    static func fetch(_ candidate: MediaCandidate, shot: Shot, style: EditingStyle, run: RunRecord, folder: ChannelFolder,
                      context: RunContext) async throws -> (entry: LedgerEntry, local: String) {
        guard case .accepted(let licence) = LicenceCheck.classify(name: candidate.licenceName, url: candidate.licenceURL,
                                                                  allowShareAlike: folder.sources().allowShareAlike) else {
            throw YTAError(.checkFailed, "Licence not accepted.")
        }
        guard let url = URL(string: candidate.fileURL) else { throw YTAError(.fileFormat, "Broken link.") }
        let response = try await context.http.get(url, headers: ["User-Agent": MediaSources.userAgent])
        guard (200..<300).contains(response.status), !response.data.isEmpty, response.data.count <= maxDownload else {
            throw YTAError(.network, "\(candidate.title) could not be downloaded.")
        }
        if candidate.kind == .image {
            guard let size = ImageSize.read(response.data) else { throw YTAError(.fileFormat, "Not an image YTA can read.") }
            guard size.width >= style.resolution.width * 2 / 3 else { throw YTAError(.checkFailed, "Too small.") }
        }
        let file = "media/\(shot.id).\(candidate.fileExtension)"
        let local = "\(run.folder)/\(file)"
        try folder.write(response.data, to: local)
        let entry = LedgerEntry(id: candidate.id, source: candidate.source, title: candidate.title, pageURL: candidate.pageURL,
                                fileURL: candidate.fileURL, author: candidate.author ?? "", licence: licence,
                                licenceName: candidate.licenceName ?? licence.title, licenceURL: candidate.licenceURL,
                                retrieved: Date(), sha256: SHA256.hex(response.data), file: file, shots: [shot.id])
        return (entry, local)
    }

    // MARK: Review board

    public static func pending(in run: RunRecord, folder: ChannelFolder) -> (plan: MediaPlan, ledger: Ledger, shots: ShotList?)? {
        guard let draft = RunStore(folder: folder).draft(for: run),
              let planText = draft.files.first(where: { $0.key.hasSuffix("/" + MediaPlan.file) }),
              let ledgerText = draft.files.first(where: { $0.key.hasSuffix("/" + Ledger.file) }),
              let plan = try? JSONCoding.decoder().decode(MediaPlan.self, from: Data(planText.value.utf8)),
              let ledger = try? JSONCoding.decoder().decode(Ledger.self, from: Data(ledgerText.value.utf8)) else { return nil }
        let shotsPath = planText.key.replacingOccurrences(of: MediaPlan.file, with: ShotList.file)
        return (plan, ledger, try? folder.readJSON(ShotList.self, shotsPath))
    }

    /// The local file of a shot's chosen asset, for the board's thumbnails.
    public static func localFile(for shot: PlannedShot, in run: RunRecord) -> String? {
        shot.file.map { "\(run.folder)/\($0)" }
    }

    /// Swaps a shot's asset for one of its alternatives, or for the filler when `candidateID` is nil.
    public static func swap(_ shotID: String, to candidateID: String?, in run: RunRecord, folder: ChannelFolder, context: RunContext) async throws {
        guard var draft = RunStore(folder: folder).draft(for: run), let pending = pending(in: run, folder: folder),
              let planKey = draft.files.keys.first(where: { $0.hasSuffix("/" + MediaPlan.file) }),
              let ledgerKey = draft.files.keys.first(where: { $0.hasSuffix("/" + Ledger.file) }),
              let index = pending.plan.shots.firstIndex(where: { $0.shot == shotID }) else {
            throw YTAError(.notFound, "That shot is not on the board.")
        }
        var plan = pending.plan
        var ledger = pending.ledger
        let videoPrefix = String(planKey.dropLast(MediaPlan.file.count))
        let old = plan.shots[index]
        if let oldID = old.assetID, let entry = ledger.entries.firstIndex(where: { $0.id == oldID }) {
            ledger.entries[entry].shots.removeAll { $0 == shotID }
            if ledger.entries[entry].shots.isEmpty { ledger.entries.remove(at: entry) }
            if let file = old.file { draft.copies?[videoPrefix + file] = nil }
        }
        plan.shots[index].assetID = nil
        plan.shots[index].file = nil
        plan.shots[index].filler = EditingStyle.load(folder).filler.rawValue
        if let candidateID {
            guard let candidate = old.alternatives.first(where: { $0.id == candidateID }) else { throw YTAError(.notFound, "That alternative is gone.") }
            let shot = pending.shots?.shots.first { $0.id == shotID }
                ?? Shot(id: shotID, beat: 0, text: "", see: "", terms: [], kind: candidate.kind == .video ? .archiveFootage : .photo, start: 0, end: 0)
            let got = try await fetch(candidate, shot: shot, style: EditingStyle.load(folder), run: run, folder: folder, context: context)
            ledger.add(got.entry)
            plan.shots[index].assetID = got.entry.id
            plan.shots[index].file = got.entry.file
            plan.shots[index].filler = nil
            plan.shots[index].note = nil
            var copies = draft.copies ?? [:]
            copies[videoPrefix + got.entry.file] = got.local
            draft.copies = copies
        }
        draft.files[planKey] = try encodeJSON(plan)
        draft.files[ledgerKey] = try encodeJSON(ledger)
        let filled = plan.shots.filter { $0.assetID != nil }.count
        draft.summary = "\(filled) of \(plan.shots.count) shots have media"
        try folder.writeJSON(draft, to: "\(run.folder)/draft.json")
    }

    public func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws {
        guard let text = draft.files.first(where: { $0.key.hasSuffix("/" + MediaPlan.file) })?.value,
              let plan = try? JSONCoding.decoder().decode(MediaPlan.self, from: Data(text.utf8)) else { return }
        var used = UsedAssets.load(folder)
        for id in Set(plan.shots.compactMap(\.assetID)) where !(used.assets[id] ?? []).contains(plan.videoID) {
            used.assets[id, default: []].append(plan.videoID)
        }
        try folder.writeJSON(used, to: UsedAssets.path)
    }
}
