import Foundation
import AVFoundation

/// Microphone processing profiles (Recordly offers raw/voice/music-style processing).
enum MicProfile: String, CaseIterable, Identifiable, Codable {
    case raw        // no processing
    case voice      // high-pass rumble removal + gentle noise gate
    case music      // light high-pass only, preserves dynamics
    var id: String { rawValue }
}

/// Real audio DSP for the mic track: a biquad high-pass (RBJ cookbook) and a noise gate.
/// Pure sample math — unit-tested — so the processing is verifiable independent of muxing.
enum MicProcessor {
    /// Second-order Butterworth-ish high-pass. Removes low-frequency rumble below `cutoff`.
    static func highPass(_ x: [Float], cutoff: Double, sampleRate: Double, q: Double = 0.707) -> [Float] {
        guard cutoff > 0, sampleRate > 0, !x.isEmpty else { return x }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let b0 = (1 + cosw) / 2, b1 = -(1 + cosw), b2 = (1 + cosw) / 2
        let a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha
        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0, na1 = a1 / a0, na2 = a2 / a0
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xn = Double(x[i])
            let yn = nb0 * xn + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
            y[i] = Float(yn)
            x2 = x1; x1 = xn; y2 = y1; y1 = yn
        }
        return y
    }

    /// Silences samples quieter than `threshold` (a simple downward gate).
    static func noiseGate(_ x: [Float], threshold: Float) -> [Float] {
        x.map { abs($0) < threshold ? 0 : $0 }
    }

    /// Applies a profile's chain to a mono float buffer.
    static func apply(_ profile: MicProfile, to x: [Float], sampleRate: Double) -> [Float] {
        switch profile {
        case .raw:   return x
        case .voice: return noiseGate(highPass(x, cutoff: 90, sampleRate: sampleRate), threshold: 0.012)
        case .music: return highPass(x, cutoff: 35, sampleRate: sampleRate)
        }
    }

    /// Processes 16-bit little-endian mono PCM through a profile, returning new PCM bytes.
    static func processPCM16(_ pcm: Data, profile: MicProfile, sampleRate: Double) -> Data {
        guard profile != .raw, !pcm.isEmpty else { return pcm }
        let count = pcm.count / 2
        var floats = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(p[i]) / Float(Int16.max) }
        }
        let out = apply(profile, to: floats, sampleRate: sampleRate)
        var result = Data(count: count * 2)
        result.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = max(-1, min(1, out[i]))
                p[i] = Int16(v * Float(Int16.max))
            }
        }
        return result
    }

    /// Extracts an asset's audio (mono 44.1kHz PCM) over `range`, runs the profile, and
    /// writes a processed WAV; returns its URL (nil for `raw`, no audio, or on failure).
    static func processedAudioFile(from asset: AVAsset, range: CMTimeRange, profile: MicProfile) async -> URL? {
        guard profile != .raw,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = range
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var pcm = Data()
        while reader.status == .reading, let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            if let ptr, len > 0 { pcm.append(Data(bytes: ptr, count: len)) }
        }
        guard !pcm.isEmpty else { return nil }
        let processed = processPCM16(pcm, profile: profile, sampleRate: 44100)
        return await writeM4A(processed, sampleRate: 44100)
    }

    /// Encodes 16-bit mono PCM to an AAC .m4a file (mp4-muxable, unlike raw LPCM WAV).
    private static func writeM4A(_ pcm: Data, sampleRate: Double) async -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reclip-mic-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return nil }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let chunk = 4096, totalFrames = pcm.count / 2
        var frame = 0
        while frame < totalFrames {
            let n = min(chunk, totalFrames - frame)
            let bytes = n * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            pcm.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!.advanced(by: frame * 2),
                                                  blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sb)
            while !input.isReadyForMoreMediaData { usleep(400) }
            if let sb { input.append(sb) }
            frame += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
}
