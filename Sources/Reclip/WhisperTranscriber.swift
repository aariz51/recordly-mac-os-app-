import Foundation
import AVFoundation

/// Local speech-to-caption transcription via a whisper.cpp binary (MIT). This wires the
/// pipeline: extract 16 kHz mono audio → run whisper-cli → parse its SRT into cues.
///
/// The parsing and audio-extraction halves are unit-tested. The transcription itself
/// requires a ggml model + real speech audio, so it is verified on-device, not in CI.
enum WhisperTranscriber {

    enum WhisperError: LocalizedError {
        case noAudioTrack
        case binaryMissing
        case modelMissing
        case runFailed(String)
        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "The recording has no audio to transcribe."
            case .binaryMissing: return "The whisper binary was not found."
            case .modelMissing: return "The whisper model was not found."
            case .runFailed(let m): return "Transcription failed: \(m)"
            }
        }
    }

    // MARK: - SRT parsing (whisper --output-srt)

    static func parseSRT(_ text: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
            guard let tc = lines.first(where: { $0.contains("-->") }),
                  let tcIndex = lines.firstIndex(of: tc) else { continue }
            let bounds = tc.components(separatedBy: "-->")
            guard bounds.count == 2 else { continue }
            let start = timecode(bounds[0].trimmingCharacters(in: .whitespaces))
            let end = timecode(bounds[1].trimmingCharacters(in: .whitespaces))
            let body = lines[(tcIndex + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { cues.append(CaptionCue(text: body, start: start, end: end)) }
        }
        return cues
    }

    static func timecode(_ s: String) -> Double {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3 else { return 0 }
        return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + (Double(parts[2]) ?? 0)
    }

    // MARK: - Audio extraction (16 kHz mono PCM WAV)

    static func extractAudioWAV(from video: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WhisperError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(out) else { throw WhisperError.runFailed("cannot read audio") }
        reader.add(out)
        reader.startReading()

        var pcm = Data()
        while reader.status == .reading, let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &ptr)
            if let ptr, length > 0 {
                pcm.append(Data(bytes: ptr, count: length))
            }
        }
        try wavData(pcm: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16).write(to: output)
    }

    /// Wraps raw little-endian PCM in a canonical 44-byte WAV header.
    static func wavData(pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        le32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        le32(16); le16(1)                                   // PCM
        le16(UInt16(channels)); le32(UInt32(sampleRate))
        le32(UInt32(byteRate)); le16(UInt16(blockAlign)); le16(UInt16(bitsPerSample))
        d.append("data".data(using: .ascii)!)
        le32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    // MARK: - Orchestration (device-only; needs whisper-cli + a ggml model)

    static func transcribe(video: URL, binary: URL, model: URL,
                           language: String = "auto") async throws -> [CaptionCue] {
        guard FileManager.default.fileExists(atPath: binary.path) else { throw WhisperError.binaryMissing }
        guard FileManager.default.fileExists(atPath: model.path) else { throw WhisperError.modelMissing }

        let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reclip-\(UUID().uuidString).wav")
        try await extractAudioWAV(from: video, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let srtBase = wav.deletingPathExtension()

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["-m", model.path, "-f", wav.path, "-l", language, "-osrt", "-of", srtBase.path]
        let pipe = Pipe(); proc.standardError = pipe; proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WhisperError.runFailed(err)
        }
        let srtURL = srtBase.appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: srtURL) }
        let srt = (try? String(contentsOf: srtURL, encoding: .utf8)) ?? ""
        return parseSRT(srt)
    }
}
