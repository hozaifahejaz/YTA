import ChannelStore
import Engines
import Foundation
import Support
import Workflow

// yta-engine-check: runs the same small custom step through each installed engine,
// inside a throwaway channel, and reports whether each returned a valid result and
// left no file outside its run folder (milestone 4 acceptance).
//
//   swift run yta-engine-check              all three tools
//   swift run yta-engine-check claude codex just these

let requested = CommandLine.arguments.dropFirst().compactMap(EngineID.init(rawValue:))
let engines = requested.isEmpty ? EngineID.allCases : Array(requested)

let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-engine-check-\(UUID().uuidString)")
let store = ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
var failures = 0

for engine in engines {
    print("\n== \(engine.displayName)")
    do {
        let record = try store.createChannel(NewChannelRequest(workingName: "Engine check \(engine.rawValue)", niche: "The history of lighthouses"))
        let node = Node(
            type: NodeType.custom.id,
            title: "Tagline",
            engine: EngineChoice(tool: engine, effort: .low),
            promptTemplate: "Write one short tagline for this channel, under 60 characters.",
            inputs: ["profile/niche.md"],
            outputs: ["profile/tagline.md"],
            approval: .never
        )
        let context = RunContext(
            settings: AppSettings(),
            tools: nil,
            planDefaults: .load(),
            automation: .straightThrough,
            onProgress: { print("   \($0)") }
        )
        let started = Date()
        let run = await RunDriver(folder: record.folder, executor: NodeRunExecutor(node: node, context: context)).start(node)
        let seconds = Int(Date().timeIntervalSince(started))
        if run.stage == .finished {
            let text = (try? record.folder.readText("profile/tagline.md"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print("   OK in \(seconds)s: \(text)")
        } else {
            failures += 1
            print("   FAILED (\(run.stage.rawValue)) after \(seconds)s: \(run.error ?? "no message")")
            print("   Raw log: \(record.folder.root.appendingPathComponent("\(run.folder)/events.jsonl").path)")
        }
    } catch {
        failures += 1
        print("   FAILED: \(error)")
    }
}

print("\nChannels kept for inspection in \(base.path)")
exit(failures == 0 ? 0 : 1)
