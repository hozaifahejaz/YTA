import AppKit
import Engines
import Foundation
import Support
import Voice
import Workflow

/// Installing, checking and updating the tools YTA drives (ffmpeg, Node, Remotion, Whisper, the AI tools).
extension AppModel {
    var toolUpdatesURL: URL { paths.support.appendingPathComponent("tool-updates.json") }
    var whisperModelURL: URL { paths.support.appendingPathComponent("whisper/\(WhisperTranscriber.modelName)") }

    func status(of id: HealthItemID) -> ToolStatus? {
        toolUpdates?.tools.first { $0.id == id }
    }

    var outdatedTools: [ToolStatus] {
        toolUpdates?.tools.filter(\.updateAvailable) ?? []
    }

    /// On launch: check once a day, and if Settings allows, update what is out of date while nothing runs.
    func maintainTools() async {
        if toolUpdates == nil, let data = try? Data(contentsOf: toolUpdatesURL) {
            toolUpdates = try? JSONCoding.decoder().decode(ToolUpdatesFile.self, from: data)
        }
        let stale = toolUpdates.map { Date().timeIntervalSince($0.checkedAt) > 20 * 3600 } ?? true
        guard stale else { return }
        await checkToolUpdates()
        guard settings.autoUpdateTools, runTasks.isEmpty else { return }
        for tool in outdatedTools where tool.updateCommand != nil || tool.id == .remotion {
            guard runTasks.isEmpty else { break }
            await updateTool(tool.id, quietly: true)
        }
        if health?.items.first(where: { $0.id == .whisper })?.status == .ok || health?.items.first(where: { $0.id == .whisper })?.path != nil {
            await ensureWhisperModel()
        }
    }

    func checkToolUpdates() async {
        if health == nil { await runHealthCheck() }
        guard let health else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let remotion = remotionProject?.installedVersion ?? RemotionProject.shippedVersion
        let tools = await ToolMaintenance().check(health, remotionVersion: remotion)
        let file = ToolUpdatesFile(checkedAt: Date(), tools: tools)
        toolUpdates = file
        try? AtomicFile.writeJSON(file, to: toolUpdatesURL)
        let count = file.tools.filter(\.updateAvailable).count
        if count > 0 { Log.shared.info("Tool updates available: \(count)") }
    }

    func updateTool(_ id: HealthItemID, quietly: Bool = false) async {
        guard let tool = status(of: id), !busyTools.contains(id) else { return }
        busyTools.insert(id)
        defer { busyTools.remove(id) }
        do {
            if id == .remotion {
                guard let latest = tool.latest, let project = remotionProject else { return }
                try await project.upgrade(to: latest)
            } else {
                guard let command = tool.updateCommand else { return }
                if !quietly { note("Updating \(id.title)…") }
                _ = try await ToolMaintenance().run(command)
            }
            note("\(id.title) is up to date")
            await runHealthCheck()
            await checkToolUpdates()
        } catch {
            if quietly { Log.shared.warning("\(id.title) update failed: \(error)") } else { report(error) }
        }
    }

    func installTool(_ id: HealthItemID) async {
        if id == .remotion {
            guard let project = remotionProject else {
                note("Remotion needs Node.js first.", isError: true)
                return
            }
            busyTools.insert(id)
            defer { busyTools.remove(id) }
            do { try await project.install() } catch { report(error) }
            await runHealthCheck()
            return
        }
        guard let command = status(of: id)?.installCommand ?? ToolMaintenance.fallbackInstall(id) else {
            if let hint = status(of: id)?.manualHint { note(hint, isError: true) }
            return
        }
        busyTools.insert(id)
        defer { busyTools.remove(id) }
        note("Installing \(id.title)…")
        do {
            _ = try await ToolMaintenance().run(command)
            await runHealthCheck()
            if id == .whisper { await ensureWhisperModel() }
            await checkToolUpdates()
            note("\(id.title) is installed")
        } catch {
            report(error)
        }
    }

    /// Downloads Whisper's speech model once, into Application Support.
    func ensureWhisperModel() async {
        let target = whisperModelURL
        guard !WhisperTranscriber.modelIsPresent(target), !busyTools.contains(.whisper) else { return }
        busyTools.insert(.whisper)
        defer { busyTools.remove(.whisper) }
        note("Downloading Whisper's speech model (about 470 MB)")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (file, response) = try await URLSession.shared.download(from: WhisperTranscriber.modelURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, WhisperTranscriber.modelIsPresent(file) else {
                throw YTAError(.network, "Whisper's model did not download completely.")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            note("Whisper is ready to check voiceovers")
            await runHealthCheck()
        } catch {
            report(error)
        }
    }

    /// Whisper for the voiceover check, when it, its model and ffmpeg are all on the Mac.
    var whisper: WhisperTranscriber? {
        guard let cli = health?.items.first(where: { $0.id == .whisper })?.path,
              let ffmpeg = health?.items.first(where: { $0.id == .ffmpeg })?.path,
              WhisperTranscriber.modelIsPresent(whisperModelURL) else { return nil }
        return WhisperTranscriber(cli: URL(fileURLWithPath: cli), model: whisperModelURL, ffmpeg: URL(fileURLWithPath: ffmpeg))
    }
}
