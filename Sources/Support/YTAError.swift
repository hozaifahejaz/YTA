import Foundation

/// Typed errors from section 5.10 of the specification.
/// Each carries a plain-language message and a suggested action for the owner.
public enum YTAErrorKind: String, Codable, Sendable, CaseIterable {
    case toolMissing
    case notSignedIn
    case usageLimit
    case schemaMismatch
    case network
    case quotaExhausted
    case licenceRejected
    case checkFailed
    case diskFull
    case pathOutsideChannel
    case fileFormat
    case notFound
    case alreadyExists
    case locked
}

public struct YTAError: Error, Equatable, Sendable, CustomStringConvertible {
    public let kind: YTAErrorKind
    public let message: String
    public let suggestion: String?
    /// For usage limits: when the engine said it resets, if it said.
    public let resetsAt: Date?

    public init(_ kind: YTAErrorKind, _ message: String, suggestion: String? = nil, resetsAt: Date? = nil) {
        self.kind = kind
        self.message = message
        self.suggestion = suggestion ?? YTAError.defaultSuggestion(for: kind)
        self.resetsAt = resetsAt
    }

    public var description: String {
        if let suggestion { return "\(message) \(suggestion)" }
        return message
    }

    static func defaultSuggestion(for kind: YTAErrorKind) -> String? {
        switch kind {
        case .toolMissing: "Open the health check to install it or point YTA at it."
        case .notSignedIn: "Sign in to the tool in Terminal, then check again."
        case .usageLimit: "The queue for this engine pauses until the limit resets."
        case .schemaMismatch: "Redo the step. If it fails again, try a stronger model."
        case .network: "Check the connection and retry."
        case .quotaExhausted: "YouTube quota resets at midnight Pacific time."
        case .licenceRejected: "Pick another asset for this shot."
        case .checkFailed: "Open the step to see which check failed."
        case .diskFull: "Free some space or clear old working files in Settings."
        case .pathOutsideChannel: "Runs may only touch their own channel folder."
        case .fileFormat: "The file could not be read. Restore it from history or fix it by hand."
        case .notFound: nil
        case .alreadyExists: nil
        case .locked: nil
        }
    }
}
