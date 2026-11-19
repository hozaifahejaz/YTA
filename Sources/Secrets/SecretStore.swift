import Foundation
import Support

/// Every key YTA can hold. All live in the macOS Keychain under the service `YTA` (section 5.8).
public enum SecretKey: String, CaseIterable, Sendable, Identifiable {
    case ai33pro
    case youtubeDataAPI
    case pexels
    case pixabay
    case smithsonian
    case rijksmuseum
    case europeana

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ai33pro: "ai33pro"
        case .youtubeDataAPI: "YouTube Data API"
        case .pexels: "Pexels"
        case .pixabay: "Pixabay"
        case .smithsonian: "Smithsonian"
        case .rijksmuseum: "Rijksmuseum"
        case .europeana: "Europeana"
        }
    }

    public var purpose: String {
        switch self {
        case .ai33pro: "Narration, and images if you choose that route."
        case .youtubeDataAPI: "Niche research, name checks and channel import. Without it YTA reads public pages, slowly."
        case .pexels: "Free stock footage and photos."
        case .pixabay: "Free stock footage, photos and music."
        case .smithsonian: "Museum images and records."
        case .rijksmuseum: "Museum images."
        case .europeana: "European archive media."
        }
    }

    public var signupURL: URL {
        switch self {
        case .ai33pro: URL(string: "https://ai33.pro")!
        case .youtubeDataAPI: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!
        case .pexels: URL(string: "https://www.pexels.com/api/")!
        case .pixabay: URL(string: "https://pixabay.com/api/docs/")!
        case .smithsonian: URL(string: "https://api.data.gov/signup/")!
        case .rijksmuseum: URL(string: "https://data.rijksmuseum.nl/")!
        case .europeana: URL(string: "https://pro.europeana.eu/pages/get-api")!
        }
    }
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    func save(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

extension SecretStore {
    public func has(_ key: SecretKey) -> Bool {
        ((try? read(key)) ?? nil)?.isEmpty == false
    }

    /// Reads a key at the moment a request is made and registers it with the redactor
    /// so it can never reach a log.
    public func valueForRequest(_ key: SecretKey, redactor: Redactor = .shared) throws -> String {
        guard let value = try read(key), !value.isEmpty else {
            throw YTAError(.notFound, "No \(key.title) key is saved.", suggestion: "Add it in Settings, Keys.")
        }
        redactor.register(value)
        return value
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    public init(_ values: [SecretKey: String] = [:]) {
        self.values = values
    }

    public func read(_ key: SecretKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func save(_ value: String, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}
