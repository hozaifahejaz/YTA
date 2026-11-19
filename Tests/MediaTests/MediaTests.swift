import ChannelStore
import Foundation
import Support
import Testing
@testable import Media
@testable import YouTubeData

/// Canned answers keyed by host and path.
final class CannedHTTP: HTTPClient, @unchecked Sendable {
    var answers: [String: String]
    var files: [String: Data] = [:]
    private(set) var asked: [URL] = []
    private(set) var agents: [String] = []

    init(_ answers: [String: String]) {
        self.answers = answers
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        asked.append(url)
        agents.append(headers["User-Agent"] ?? "")
        if let data = files[url.absoluteString] { return HTTPResponse(status: 200, data: data) }
        let key = (url.host ?? "") + url.path
        guard let text = answers[key] else { return HTTPResponse(status: 404, data: Data()) }
        return HTTPResponse(status: 200, data: Data(text.utf8))
    }
}

@Suite struct LicenceTests {
    @Test func acceptedAndRejectedLicences() {
        #expect(LicenceCheck.classify(name: "CC BY-SA 4.0") == .accepted(.ccBySa))
        #expect(LicenceCheck.classify(name: "CC BY 2.0") == .accepted(.ccBy))
        #expect(LicenceCheck.classify(name: "CC0") == .accepted(.cc0))
        #expect(LicenceCheck.classify(name: "Public domain") == .accepted(.publicDomain))
        #expect(LicenceCheck.classify(name: nil, url: "http://creativecommons.org/publicdomain/mark/1.0/") == .accepted(.publicDomain))
        #expect(LicenceCheck.classify(name: "Pexels License") == .accepted(.pexels))
        #expect(LicenceCheck.classify(name: "CC BY-NC 4.0") == .rejected("Non-commercial licence."))
        #expect(LicenceCheck.classify(name: nil, url: "https://creativecommons.org/licenses/by-nc-sa/3.0/") == .rejected("Non-commercial licence."))
        #expect(LicenceCheck.classify(name: "CC BY-ND 2.0") == .rejected("No-derivatives licence."))
        #expect(LicenceCheck.classify(name: "CC BY-SA 3.0", allowShareAlike: false) != .accepted(.ccBySa))
        if case .rejected = LicenceCheck.classify(name: "GFDL") {} else { Issue.record("GFDL must not be guessed") }
        if case .rejected = LicenceCheck.classify(name: nil) {} else { Issue.record("A missing licence must be rejected") }
    }

    @Test func hashesMatchKnownValues() {
        #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data(String(repeating: "a", count: 1000).utf8)
        #expect(SHA256.hex(long) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func imageSizesAreReadFromHeaders() {
        var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38]) + Data(count: 16)
        #expect(ImageSize.read(png)! == (1920, 1080))
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 17, 8, 0x02, 0xd0, 0x05, 0x00, 3]) + Data(count: 20)
        #expect(ImageSize.read(jpeg)! == (1280, 720))
    }

    @Test func aLedgerEntryIsCompleteOnlyWithEveryField() {
        var entry = LedgerEntry(id: "commons:1", source: "Wikimedia Commons", title: "Vasa", pageURL: "https://commons.wikimedia.org/wiki/File:Vasa.jpg",
                                fileURL: "https://upload.wikimedia.org/Vasa.jpg", author: "Jane", licence: .ccBy, licenceName: "CC BY 4.0",
                                licenceURL: "https://creativecommons.org/licenses/by/4.0", retrieved: Date(), sha256: SHA256.hex(Data("x".utf8)), file: "media/s001.jpg")
        #expect(entry.missing.isEmpty)
        #expect(entry.creditRequired)
        entry.author = ""
        #expect(entry.missing == ["author"])
    }
}

@Suite struct SourceTests {
    @Test func commonsResultsCarryLicenceAndAuthor() async throws {
        let http = CannedHTTP(["commons.wikimedia.org/w/api.php": #"""
        {"query":{"pages":{"5":{"pageid":5,"index":1,"title":"File:Vasa ship.jpg","imageinfo":[{"url":"https://upload.wikimedia.org/a/Vasa_ship.jpg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Vasa_ship.jpg","thumburl":"https://upload.wikimedia.org/thumb/a.jpg","width":4000,"height":3000,"mime":"image/jpeg","extmetadata":{"Artist":{"value":"<a href=\"x\">Jane &amp; Co</a>"},"LicenseShortName":{"value":"CC BY-SA 4.0"},"LicenseUrl":{"value":"https://creativecommons.org/licenses/by-sa/4.0"}}}]}}}}
        """#])
        let results = try await CommonsSource(http: http).search("Vasa ship", kind: .image, limit: 5)
        #expect(results.count == 1)
        #expect(results[0].author == "Jane & Co")
        #expect(results[0].title == "Vasa ship")
        #expect(results[0].licenceName == "CC BY-SA 4.0")
        #expect(http.agents.allSatisfy { $0 == MediaSources.userAgent })
    }

    @Test func metListsOnlyPublicDomainObjects() async throws {
        let http = CannedHTTP([
            "collectionapi.metmuseum.org/public/collection/v1/search": #"{"objectIDs":[1,2]}"#,
            "collectionapi.metmuseum.org/public/collection/v1/objects/1": #"{"isPublicDomain":true,"primaryImage":"https://images.met/1.jpg","title":"Ship","artistDisplayName":"","objectURL":"https://met/1"}"#,
            "collectionapi.metmuseum.org/public/collection/v1/objects/2": #"{"isPublicDomain":false,"primaryImage":"https://images.met/2.jpg","title":"Not free"}"#,
        ])
        let results = try await MetSource(http: http).search("ship", kind: nil, limit: 5)
        #expect(results.map(\.id) == ["met:1"])
        #expect(results[0].author == "The Metropolitan Museum of Art")
    }

    @Test func musicNeedsAnAcceptedLicence() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-music-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base).createChannel(NewChannelRequest(workingName: "Keel", niche: "Ships")).folder
        let library = MusicLibrary(folder: folder)
        var refused = false
        do {
            try library.add(Data("mp3".utf8), fileName: "calm.mp3", title: "Calm", author: "A", licence: "CC BY-NC 4.0", licenceURL: nil, sourcePage: "https://x.example")
        } catch { refused = true }
        #expect(refused)
        let track = try library.add(Data("mp3".utf8), fileName: "calm.mp3", title: "Calm", author: "A", licence: "CC BY 4.0",
                                    licenceURL: "https://creativecommons.org/licenses/by/4.0", sourcePage: "https://x.example/calm")
        #expect(!track.approved && library.approved().isEmpty)
        try library.setApproved(track.file, true)
        #expect(library.approved().first?.ledger.missing == [])
    }
}
