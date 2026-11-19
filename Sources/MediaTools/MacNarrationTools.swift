import AVFoundation
import Foundation
import Speech
import Support
import Voice

/// Transcription with on-device speech recognition, and audio joining with AVFoundation (section 8.3, step 5).
public struct MacNarrationTools: NarrationTools {
    /// Mono 48 kHz is what the editor reads.
    static let sampleRate = 48_000.0
    /// Below this level counts as silence when trimming.
    static let silence: Float = 0.003
    /// Silence kept at each end of a beat.
    static let keep = 0.12
    /// Loudness target, close to -16 LUFS for spoken word, with a ceiling of -1 dBFS.
    static let targetRMS: Float = 0.12
    static let ceiling: Float = 0.89

    /// whisper.cpp, preferred when installed: more accurate than the system recogniser on narration.
    let whisper: WhisperTranscriber?

    public init(whisper: WhisperTranscriber? = nil) {
        self.whisper = whisper
    }

    // MARK: Transcription

    public func transcribe(_ file: URL, language: String) async throws -> [(word: String, start: Double, end: Double)] {
        if let whisper {
            do {
                return try await whisper.transcribe(file, language: language)
            } catch {
                Log.shared.warning("Whisper failed on \(file.lastPathComponent), using the system recogniser: \(error)")
            }
        }
        try await Self.authorise()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw YTAError(.toolMissing, "Speech recognition is not available for this language on this Mac.")
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let once = Once()
        let segments: [Segment] = try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.run { continuation.resume(throwing: YTAError(.checkFailed, "The audio check could not listen to this beat.", suggestion: error.localizedDescription)) }
                    return
                }
                guard let result, result.isFinal else { return }
                let found = result.bestTranscription.segments.map { Segment(word: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
                once.run { continuation.resume(returning: found) }
            }
        }
        return segments.map { ($0.word, $0.start, $0.end) }
    }

    struct Segment: Sendable {
        var word: String
        var start: Double
        var end: Double
    }

    static func authorise() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw YTAError(.checkFailed, "YTA needs speech recognition to check the narration.",
                           suggestion: "Turn it on in System Settings → Privacy & Security → Speech Recognition.")
        }
    }

    // MARK: Length and joining

    public func duration(of file: URL) throws -> Double {
        let audio = try open(file)
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    /// Each returned start is where the beat's own second zero falls in the joined file,
    /// so word times from `transcribe` stay right after the silence is trimmed.
    public func join(_ files: [URL], gap: Double, to output: URL) throws -> [Double] {
        var samples: [Float] = []
        var starts: [Double] = []
        let gapFrames = Int(gap * Self.sampleRate)
        for (index, file) in files.enumerated() {
            let beat = try mono(file)
            let (first, last) = Self.voiced(beat)
            if index > 0 { samples += [Float](repeating: 0, count: gapFrames) }
            starts.append(Double(samples.count - first) / Self.sampleRate)
            if first < last { samples += beat[first..<last] }
        }
        Self.normalise(&samples)
        try write(samples, to: output)
        return starts
    }

    /// The range of a beat to keep: its voiced part plus a little air.
    static func voiced(_ samples: [Float]) -> (Int, Int) {
        let pad = Int(keep * sampleRate)
        guard let first = samples.firstIndex(where: { abs($0) > silence }),
              let last = samples.lastIndex(where: { abs($0) > silence }) else { return (0, 0) }
        return (max(0, first - pad), min(samples.count, last + pad + 1))
    }

    static func normalise(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let voiced = samples.filter { abs($0) > silence }
        guard !voiced.isEmpty else { return }
        let rms = (voiced.reduce(0) { $0 + $1 * $1 } / Float(voiced.count)).squareRoot()
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard rms > 0, peak > 0 else { return }
        let gain = min(targetRMS / rms, ceiling / peak)
        for index in samples.indices { samples[index] *= gain }
    }

    // MARK: Files

    func open(_ file: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: file)
        } catch {
            throw YTAError(.fileFormat, "\(file.lastPathComponent) is not audio YTA can read.")
        }
    }

    /// The file as mono samples at the editor's rate.
    func mono(_ file: URL) throws -> [Float] {
        let audio = try open(file)
        guard let source = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { return [] }
        try audio.read(into: source)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: audio.processingFormat, to: target) else {
            throw YTAError(.fileFormat, "\(file.lastPathComponent) could not be converted.")
        }
        let ratio = Self.sampleRate / audio.processingFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024) else { return [] }
        let fed = Once()
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if fed.claim() {
                status.pointee = .haveData
                return source
            }
            status.pointee = .endOfStream
            return nil
        }
        if failure != nil { throw YTAError(.fileFormat, "\(file.lastPathComponent) could not be converted.") }
        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    func write(_ samples: [Float], to output: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw YTAError(.fileFormat, "The narration could not be written.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// Lets a callback that may fire more than once act only the first time.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }

    func run(_ work: () -> Void) {
        if claim() { work() }
    }
}
