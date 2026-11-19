import AppKit
import ChannelStore
import Foundation
import Support
import UniformTypeIdentifiers
import Workflow

/// The channel's video queue (section 8.1). One video at a time, top to bottom.
extension AppModel {
    private var videoStore: VideoStore? { selectedChannel.map { VideoStore(folder: $0.folder) } }

    func addVideo(title: String, script: String? = nil, settings: VideoSettings? = nil) {
        guard let store = videoStore else { return }
        do {
            let video = try store.add(title: title, script: script, settings: settings)
            loadSetupRow()
            expandedVideoID = video.id
            note("Added \(video.title) to the queue")
        } catch {
            report(error)
        }
    }

    func addVideos(fromList text: String, csv: Bool = false) {
        guard let store = videoStore else { return }
        let titles = VideoStore.titles(fromList: text, csv: csv)
        do {
            try store.addMany(titles)
            loadSetupRow()
            note("Added \(titles.count) videos to the queue")
        } catch {
            report(error)
        }
    }

    /// `.csv` adds a list of titles; `.txt`, `.md` and `.docx` add one video with the owner's script.
    func importVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["csv", "txt", "md", "docx"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                switch url.pathExtension.lowercased() {
                case "csv":
                    addVideos(fromList: try String(contentsOf: url, encoding: .utf8), csv: true)
                case "docx":
                    let text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                      documentAttributes: nil).string
                    addVideo(title: url.deletingPathExtension().lastPathComponent, script: text)
                default:
                    addVideo(title: url.deletingPathExtension().lastPathComponent, script: try String(contentsOf: url, encoding: .utf8))
                }
            } catch {
                report(YTAError(.fileFormat, "Could not read \(url.lastPathComponent).", suggestion: "Use .csv for titles or .txt, .md or .docx for a script."))
            }
        }
    }

    func moveVideo(_ id: String, by offset: Int) {
        guard let store = videoStore, let index = videos.firstIndex(where: { $0.id == id }) else { return }
        do {
            try store.move(id, to: index + offset)
            loadSetupRow()
        } catch {
            report(error)
        }
    }

    func setVideoStatus(_ id: String, _ status: VideoStatus) {
        guard let store = videoStore else { return }
        do {
            try store.setStatus(id, status)
            loadSetupRow()
        } catch {
            report(error)
        }
    }

    func updateVideoSettings(_ id: String, _ settings: VideoSettings) {
        guard let store = videoStore else { return }
        do {
            try store.update(id) { $0.settings = settings }
            loadSetupRow()
        } catch {
            report(error)
        }
    }

    func retitleVideo(_ id: String, to title: String) {
        guard let store = videoStore else { return }
        do {
            _ = try store.retitle(id, to: title)
            loadSetupRow()
        } catch {
            report(error)
        }
    }

    func revealVideo(_ video: VideoFile) {
        guard let url = try? selectedChannel?.folder.url("\(ChannelLayout.videos)/\(video.folderName)") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Running the queue

    func isQueueRunning(_ channel: ChannelRecord?) -> Bool {
        guard let channel else { return false }
        return runningQueues.contains(channel.manifest.id)
    }

    func toggleQueue() {
        guard let channel = selectedChannel else { return }
        if runningQueues.remove(channel.manifest.id) == nil {
            runningQueues.insert(channel.manifest.id)
            note("Queue started for \(channel.manifest.name)")
            advanceQueue(channel)
        } else {
            note("Queue paused for \(channel.manifest.name). Steps already running finish.")
        }
    }

    /// Starts the next step of the first unfinished video. Stops at anything that needs the owner.
    func advanceQueue(_ channel: ChannelRecord) {
        guard runningQueues.contains(channel.manifest.id) else { return }
        let store = VideoStore(folder: channel.folder)
        guard var video = store.next() else {
            runningQueues.remove(channel.manifest.id)
            note("The queue for \(channel.manifest.name) is empty")
            return
        }
        guard let node = video.row.nextNode else { return }
        if video.row.nodes.contains(where: { runTasks[$0.id] != nil }) { return }
        switch node.state {
        case .needsYou:
            note("\(video.title): \(node.title) is waiting for you")
            return
        case .failed:
            note("\(video.title): \(node.title) failed. Fix it and start the queue again.", isError: true)
            runningQueues.remove(channel.manifest.id)
            return
        default:
            break
        }
        if node.type == "researchNotes", !video.settings.researchNotes {
            setState(of: node.id, in: channel.folder, to: .done, summary: "Switched off for this video")
            advanceQueue(channel)
            return
        }
        guard NodeRunExecutor.canRun(node), node.nodeType?.lockedReason == nil || node.state == .done else {
            note("\(video.title): the queue stopped at \(node.title), which can't run yet.")
            runningQueues.remove(channel.manifest.id)
            return
        }
        if video.status == .queued {
            video.status = .working
            try? store.save(video)
        }
        run(node, in: channel)
    }
}
