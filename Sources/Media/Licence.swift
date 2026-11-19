import Foundation

/// The licences the app accepts (section 8.4). Pexels and Pixabay have their own licences and are
/// recorded under their own names, since they are not Creative Commons.
public enum LicenceKind: String, Codable, Sendable, CaseIterable {
    case publicDomain, cc0, ccBy, ccBySa, pexels, pixabay, owner, generated

    public var title: String {
        switch self {
        case .publicDomain: "Public domain"
        case .cc0: "CC0"
        case .ccBy: "CC BY"
        case .ccBySa: "CC BY-SA"
        case .pexels: "Pexels License"
        case .pixabay: "Pixabay Content License"
        case .owner: "Owner's own"
        case .generated: "Generated"
        }
    }

    public var creditRequired: Bool { self == .ccBy || self == .ccBySa }
    public var shareAlike: Bool { self == .ccBySa }

    public var defaultURL: String? {
        switch self {
        case .cc0: "https://creativecommons.org/publicdomain/zero/1.0/"
        case .publicDomain: "https://creativecommons.org/publicdomain/mark/1.0/"
        case .pexels: "https://www.pexels.com/license/"
        case .pixabay: "https://pixabay.com/service/license-summary/"
        default: nil
        }
    }
}

public enum LicenceCheck {
    public enum Verdict: Equatable, Sendable {
        case accepted(LicenceKind)
        case rejected(String)
    }

    /// Reads a licence name or link. Anything it cannot read is rejected, not guessed.
    public static func classify(name: String?, url: String? = nil, allowShareAlike: Bool = true) -> Verdict {
        let text = [name, url].compactMap { $0 }.joined(separator: " ").lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .rejected("No licence was given.") }

        if text.contains("-nc") || text.contains("nc-") || text.contains("noncommercial") || text.contains("non-commercial") || text.contains(" nc ") {
            return .rejected("Non-commercial licence.")
        }
        if text.contains("-nd") || text.contains("nd-") || text.contains("noderiv") || text.contains("no derivatives") || text.contains(" nd ") {
            return .rejected("No-derivatives licence.")
        }
        if text.contains("pexels") { return .accepted(.pexels) }
        if text.contains("pixabay") { return .accepted(.pixabay) }
        if text.contains("cc0") || text.contains("publicdomain/zero") || text.contains("cc-zero") {
            return .accepted(.cc0)
        }
        if text.contains("public domain") || text.contains("publicdomain/mark") || text.contains("pdm") || text.hasPrefix("pd-") || text == "pd"
            || text.contains("no known copyright") || text.contains("no known restrictions") || text.contains("not in copyright") {
            return .accepted(.publicDomain)
        }
        if text.contains("by-sa") || text.contains("by sa") || text.contains("sharealike") || text.contains("share alike") {
            return allowShareAlike ? .accepted(.ccBySa) : .rejected("Share-alike media is switched off for this channel.")
        }
        if text.contains("cc by") || text.contains("cc-by") || text.contains("licenses/by/") || text.contains("attribution") {
            return .accepted(.ccBy)
        }
        return .rejected("The licence \"\(name ?? url ?? "")\" could not be read.")
    }
}
