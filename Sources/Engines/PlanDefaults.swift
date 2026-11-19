import Foundation
import Support

/// What kind of work a step is, for choosing a model from the plan (section 5.4).
public enum StepKind: String, Codable, Sendable, CaseIterable {
    case general, research, scoring, writing
}

/// `plan-defaults.json`: model, effort and parallel runs per plan. The shipped table is below;
/// `~/Library/Application Support/YTA/plan-defaults.json` overrides it, so the owner can edit it.
/// (Kept in code rather than as a SwiftPM resource, because `Bundle.module` cannot find
/// resource bundles inside an app assembled without Xcode.)
public struct PlanDefaults: Sendable {
    public struct Choice: Codable, Sendable, Equatable {
        public var model: String?
        public var effort: Effort?
    }

    struct Plan: Codable, Sendable {
        var parallel: Int
        var kinds: [String: Choice]
    }

    struct File: Codable, Sendable {
        var plans: [String: [String: Plan]]
    }

    private let file: File

    public static func load(override: URL? = nil) -> PlanDefaults {
        let decoder = JSONCoding.decoder()
        if let override, let data = try? Data(contentsOf: override), let file = try? decoder.decode(File.self, from: data) {
            return PlanDefaults(file: file)
        }
        if let file = try? decoder.decode(File.self, from: Data(shippedPlanDefaults.utf8)) {
            return PlanDefaults(file: file)
        }
        return PlanDefaults(file: File(plans: [:]))
    }

    /// Writes the shipped table to `url` if no file is there, so the owner has one to edit.
    public static func installEditableCopy(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? AtomicFile.write(shippedPlanDefaults, to: url)
    }

    public func choice(engine: EngineID, plan: String, kind: StepKind) -> Choice {
        file.plans[engine.rawValue]?[plan]?.kinds[kind.rawValue] ?? Choice(model: nil, effort: nil)
    }

    public func parallelRuns(engine: EngineID, plan: String) -> Int {
        max(1, file.plans[engine.rawValue]?[plan]?.parallel ?? 1)
    }
}

private let shippedPlanDefaults = #"""
{
  "schemaVersion": 1,
  "note": "Model, effort and parallel runs per plan and kind of step. Edit freely; usage limits are not kept here because they change.",
  "plans": {
    "claude": {
      "Pro":     { "parallel": 1, "kinds": { "general": { "model": "sonnet", "effort": "medium" }, "research": { "model": "sonnet", "effort": "medium" }, "scoring": { "model": "sonnet", "effort": "high" }, "writing": { "model": "sonnet", "effort": "high" } } },
      "Max 5x":  { "parallel": 2, "kinds": { "general": { "model": "sonnet", "effort": "medium" }, "research": { "model": "sonnet", "effort": "high" }, "scoring": { "model": "opus", "effort": "high" }, "writing": { "model": "opus", "effort": "high" } } },
      "Max 20x": { "parallel": 3, "kinds": { "general": { "model": "sonnet", "effort": "high" }, "research": { "model": "opus", "effort": "high" }, "scoring": { "model": "opus", "effort": "xhigh" }, "writing": { "model": "opus", "effort": "xhigh" } } },
      "API":     { "parallel": 2, "kinds": { "general": { "model": "sonnet", "effort": "medium" }, "research": { "model": "sonnet", "effort": "medium" }, "scoring": { "model": "opus", "effort": "high" }, "writing": { "model": "opus", "effort": "high" } } }
    },
    "codex": {
      "Plus": { "parallel": 1, "kinds": { "general": { "effort": "medium" }, "research": { "effort": "medium" }, "scoring": { "effort": "high" }, "writing": { "effort": "high" } } },
      "Pro":  { "parallel": 2, "kinds": { "general": { "effort": "medium" }, "research": { "effort": "high" }, "scoring": { "effort": "xhigh" }, "writing": { "effort": "xhigh" } } },
      "API":  { "parallel": 2, "kinds": { "general": { "effort": "medium" }, "research": { "effort": "medium" }, "scoring": { "effort": "high" }, "writing": { "effort": "high" } } }
    },
    "opencode": {
      "Default": { "parallel": 1, "kinds": {} }
    }
  }
}
"""#
