import Foundation
import Support

/// Local speech recognition with whisper.cpp (`whisper-cli`), used to check each narration beat
/// and to time its words. It runs on the Mac with no network and no cost.
public struct WhisperTranscriber: Sendable {
    /// The multilingual model YTA downloads. Small is a good balance of accuracy and speed on Apple silicon.
    public static let modelName = "ggml-small.bin"
    public static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
    /// The real file is about 466 MB; anything far smaller is a failed download.
    public static let minimumModelBytes: Int64 = 400_000_000

    public let cli: URL
    public let model: URL
    /// Converts any audio to the 16 kHz mono WAV whisper.cpp reads.
    public let ffmpeg: URL

    public init(cli: URL, model: URL, ffmpeg: URL) {
        self.cli = cli
        self.model = model
        self.ffmpeg = ffmpeg
    }

    public static func modelIsPresent(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size >= minimumModelBytes
    }

    public func transcribe(_ file: URL, language: String) async throws -> [(word: String, start: Double, end: Double)] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yta-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let wav = scratch.appendingPathComponent("audio.wav")
        let convert = try await ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-y", "-i", file.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path],
                                                  timeout: 120)
        guard convert.succeeded else { throw YTAError(.checkFailed, "The audio check could not read this beat.") }
        let base = scratch.appendingPathComponent("words")
        let code = language.isEmpty ? "auto" : language
        let result = try await ProcessRunner.run(cli, arguments: ["-m", model.path, "-f", wav.path, "-l", code, "-ml", "1", "-sow", "-oj", "-of", base.path, "-np"],
                                                 timeout: 600)
        guard result.succeeded, let data = try? Data(contentsOf: base.appendingPathExtension("json")) else {
            throw YTAError(.checkFailed, "Whisper could not listen to this beat.", suggestion: String(result.stderr.suffix(300)))
        }
        return try Self.words(fromJSON: data)
    }

    /// Reads whisper.cpp's `-oj` output made with one word per segment (`-ml 1 -sow`).
    public static func words(fromJSON data: Data) throws -> [(word: String, start: Double, end: Double)] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let segments = value["transcription"]?.arrayValue else {
            throw YTAError(.fileFormat, "Whisper's answer could not be read.")
        }
        return segments.compactMap { segment in
            let text = (segment["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("["), let from = segment["offsets"]?["from"]?.doubleValue,
                  let to = segment["offsets"]?["to"]?.doubleValue else { return nil }
            return (text, from / 1000, to / 1000)
        }
    }
}
