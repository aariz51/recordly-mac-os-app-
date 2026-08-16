import XCTest
import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import AppKit
@testable import Reclip

/// Functional tests for the parity features added this session: crop, background blur,
/// aspect-ratio canvas, webcam mirror/roundness/shadow/margin, export quality, GIF loop.
final class ParityFeatureTests: XCTestCase {

    private func tmp(_ n: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reclip-parity-\(n)")
    }

    private func makeVideo(_ url: URL, size: CGSize = CGSize(width: 640, height: 400),
                           seconds: Double = 1.2, fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        let total = Int(Double(fps) * seconds)
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { usleep(400) }
            var pb: CVPixelBuffer!
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width),
                                height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1); ctx.fill(CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pb, [])
            ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished(); await w.finishWriting()
    }

    private func dims(_ url: URL) async throws -> CGSize {
        let a = AVURLAsset(url: url)
        guard let t = try await a.loadTracks(withMediaType: .video).first else { return .zero }
        let n = try await t.load(.naturalSize)
        return CGSize(width: abs(n.width), height: abs(n.height))
    }

    private func assertValid(_ url: URL) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThan(d, 0.5)
    }

    /// Counts decoded video frames in a file (ground truth for the output frame-rate).
    private func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        reader.add(out); reader.startReading()
        var n = 0
        while reader.status == .reading, out.copyNextSampleBuffer() != nil { n += 1 }
        return n
    }

    func testCropExports() async throws {
        let src = tmp("crop-src.mp4"); try await makeVideo(src)
        let out = tmp("crop.mp4")
        var s = StyleOptions(); s.crop = .init(top: 0.1, bottom: 0.1, left: 0.15, right: 0.05)
        try await StyledExport.export(source: src, to: out, style: s)
        try await assertValid(out)
    }

    func testBackgroundBlurExports() async throws {
        let src = tmp("blur-src.mp4"); try await makeVideo(src)
        let out = tmp("blur.mp4")
        var s = StyleOptions(); s.backgroundBlur = 4
        try await StyledExport.export(source: src, to: out, style: s)
        try await assertValid(out)
    }

    func testAspectSquareChangesCanvas() async throws {
        let src = tmp("aspect-src.mp4"); try await makeVideo(src, size: CGSize(width: 640, height: 400))
        let out = tmp("aspect.mp4")
        var s = StyleOptions(); s.aspect = .square
        try await StyledExport.export(source: src, to: out, style: s)
        let d = try await dims(out)
        // Square aspect → equal-ish width and height (H.264 even-rounded).
        XCTAssertEqual(d.width, d.height, accuracy: 4, "square aspect should produce a square canvas")
    }

    func testAspectVerticalIsPortrait() async throws {
        let src = tmp("vert-src.mp4"); try await makeVideo(src, size: CGSize(width: 640, height: 400))
        let out = tmp("vert.mp4")
        var s = StyleOptions(); s.aspect = .vertical  // 9:16
        try await StyledExport.export(source: src, to: out, style: s)
        let d = try await dims(out)
        XCTAssertGreaterThan(d.height, d.width, "9:16 should be taller than wide")
    }

    func testWebcamMirrorRoundnessShadow() async throws {
        let src = tmp("wc-src.mp4"); try await makeVideo(src)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 300, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        var wc = WebcamSettings()
        wc.enabled = true; wc.mirror = true; wc.roundness = 0.4; wc.shadow = true; wc.marginFraction = 0.08
        let out = tmp("wc.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      webcam: frames, webcamSettings: wc)
        try await assertValid(out)
    }

    func testExportQualityLevels() async throws {
        let src = tmp("q-src.mp4"); try await makeVideo(src)
        for q in ExportQuality.allCases {
            let out = tmp("q-\(q.rawValue).mp4")
            try await StyledExport.export(source: src, to: out, style: StyleOptions(), quality: q)
            try await assertValid(out)
        }
    }

    func testGifLoopToggleBothProduceGifs() async throws {
        let src = tmp("gl-src.mp4"); try await makeVideo(src)
        for loop in [true, false] {
            let out = tmp("gl-\(loop).gif")
            try await GifExport.export(source: src, to: out, style: StyleOptions(), fps: 8, loop: loop)
            let s = CGImageSourceCreateWithURL(out as CFURL, nil)
            XCTAssertNotNil(s)
            XCTAssertGreaterThan(CGImageSourceGetCount(s!), 1)
        }
    }

    func testWebcamNonSquareAspect() async throws {
        let src = tmp("wcna-src.mp4"); try await makeVideo(src)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 400, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        var wc = WebcamSettings()
        wc.enabled = true; wc.aspectRatio = 0.6; wc.roundness = 0.3; wc.sizeFraction = 0.3
        let out = tmp("wcna.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      webcam: frames, webcamSettings: wc)
        try await assertValid(out)
    }

    func testGifBounceRoughlyDoublesFrames() async throws {
        let src = tmp("bounce-src.mp4"); try await makeVideo(src, seconds: 1.0, fps: 30)
        let plain = tmp("bounce-off.gif")
        try await GifExport.export(source: src, to: plain, style: StyleOptions(), fps: 8, bounce: false)
        let bounced = tmp("bounce-on.gif")
        try await GifExport.export(source: src, to: bounced, style: StyleOptions(), fps: 8, bounce: true)
        let n1 = CGImageSourceGetCount(CGImageSourceCreateWithURL(plain as CFURL, nil)!)
        let n2 = CGImageSourceGetCount(CGImageSourceCreateWithURL(bounced as CFURL, nil)!)
        XCTAssertGreaterThan(n1, 1)
        // forward (n) + interior reversed (n-2) = 2n-2
        XCTAssertEqual(n2, 2 * n1 - 2, "ping-pong appends the interior frames reversed")
    }

    func testGifSizePresetCapsWidth() async throws {
        let src = tmp("gs-src.mp4"); try await makeVideo(src, size: CGSize(width: 1600, height: 1000))
        let out = tmp("gs.gif")
        try await GifExport.export(source: src, to: out, style: StyleOptions(),
                                   fps: 6, maxWidth: GifSize.medium.maxWidth)
        let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        XCTAssertLessThanOrEqual(w, 720, "720p preset caps width, got \(w)")
        XCTAssertGreaterThan(w, 100)
    }

    func testSystemCursorExtraction() {
        // The real macOS arrow cursor extracts to a non-empty sprite.
        let sprite = SystemCursor.arrowSprite(size: 40)
        XCTAssertNotNil(sprite)
        if let e = sprite?.extent {
            XCTAssertGreaterThan(e.width, 2)
            XCTAssertGreaterThan(e.height, 2)
        }
        XCTAssertTrue(CursorStyle.Kind.allCases.contains(.system))
    }

    func testCursorSpotlightDimsAwayFromCursor() {
        // Bright base; cursor at center. Spotlight should darken the corner but keep center bright.
        let base = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        var track = CursorTrack(); track.samples = [CursorSample(t: 0, x: 0.5, y: 0.5)]
        var cs = CursorStyle(); cs.enabled = true; cs.spotlight = true; cs.spotlightRadius = 0.12; cs.spotlightDim = 0.6
        let lit = CursorRenderer.applySpotlight(on: base, track: track, time: 0, style: cs)

        let ctx = CIContext()
        func luma(_ img: CIImage, _ x: Int, _ y: Int) -> Int {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Int(px[0])
        }
        let center = luma(lit, 100, 100)
        let corner = luma(lit, 4, 4)
        XCTAssertGreaterThan(center, corner + 40, "spotlight keeps the cursor area brighter than the corner")
        XCTAssertGreaterThan(center, 150, "cursor area stays near full brightness")
    }

    func testCursorOverlayExports() async throws {
        let src = tmp("cur-src.mp4"); try await makeVideo(src)
        var track = CursorTrack()
        for i in 0..<40 { track.samples.append(CursorSample(t: Double(i) / 30.0, x: Double(i) / 40.0, y: 0.5)) }
        for kind in CursorStyle.Kind.allCases {
            var cs = CursorStyle(); cs.enabled = true; cs.kind = kind; cs.size = 1.5
            let out = tmp("cur-\(kind.rawValue).mp4")
            try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                          cursor: track, cursorStyle: cs)
            try await assertValid(out)
        }
    }

    func testRichAnnotationsExport() async throws {
        let src = tmp("ann-src.mp4"); try await makeVideo(src)
        var blur = Annotation(text: "", start: 0.1, end: 1.0)
        blur.kind = .blur; blur.position = CGPoint(x: 0.3, y: 0.3)
        blur.regionSize = CGSize(width: 0.2, height: 0.2); blur.blurRadius = 30
        var box = Annotation(text: "", start: 0.1, end: 1.0)
        box.kind = .box; box.position = CGPoint(x: 0.7, y: 0.3); box.colorRGBA = [0, 0, 0, 0.9]
        var arrow = Annotation(text: "", start: 0.1, end: 1.0)
        arrow.kind = .arrow; arrow.position = CGPoint(x: 0.5, y: 0.7); arrow.colorRGBA = [1, 0.3, 0.3, 1]
        let out = tmp("ann.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      annotations: [blur, box, arrow])
        try await assertValid(out)
    }

    func testImageAnnotationExport() async throws {
        let src = tmp("img-src.mp4"); try await makeVideo(src)
        let img = NSImage(size: NSSize(width: 60, height: 40))
        img.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 60, height: 40).fill(); img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        var ann = Annotation(text: "", start: 0.1, end: 1.0)
        ann.kind = .image; ann.imageData = png
        ann.position = CGPoint(x: 0.5, y: 0.5); ann.regionSize = CGSize(width: 0.25, height: 0.25)
        let out = tmp("img.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), annotations: [ann])
        try await assertValid(out)
    }

    func testBlendAveragesFramesToGray() {
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        guard let blended = MotionBlur.blend([(black, 0.5), (white, 0.5)], extent: extent) else {
            return XCTFail("blend returned nil")
        }
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(blended, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        // Equal blend of black + white → mid gray (~128) on each channel.
        XCTAssertEqual(Int(px[0]), 128, accuracy: 8, "got \(px[0])")
        XCTAssertEqual(Int(px[1]), 128, accuracy: 8)
        XCTAssertEqual(Int(px[2]), 128, accuracy: 8)
    }

    func testMotionBlurExportIsValid() async throws {
        let src = tmp("mb-src.mp4"); try await makeVideo(src, size: CGSize(width: 480, height: 320), seconds: 1.5)
        let out = tmp("mb.mp4")
        try await StyledExport.exportReencoded(source: src, to: out, style: StyleOptions(),
                                               frameRate: .fps30, motionBlur: 1.0)
        try await assertValid(out)
    }

    /// Writes a short clip that has BOTH a video and an audio track (silent, or a 440Hz tone).
    private func makeVideoWithAudio(_ url: URL, seconds: Double = 1.0, tone: Bool = false) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let size = CGSize(width: 320, height: 240)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        aIn.expectsMediaDataInRealTime = false
        w.add(vIn); w.add(aIn); w.startWriting(); w.startSession(atSourceTime: .zero)
        let fps: Int32 = 30, total = Int(Double(fps) * seconds)
        for i in 0..<total {
            while !vIn.isReadyForMoreMediaData { usleep(400) }
            var pb: CVPixelBuffer!
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
            ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        vIn.markAsFinished()
        // Silent 16-bit mono PCM buffers, 44.1kHz.
        let sr = 44100.0, chunk = 4410
        var asbd = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var t = 0
        while Double(t) / sr < seconds {
            while !aIn.isReadyForMoreMediaData { usleep(400) }
            let bytes = chunk * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            if tone {
                var samples = [Int16](repeating: 0, count: chunk)
                for i in 0..<chunk {
                    let phase = 2.0 * Double.pi * 440.0 * Double(t + i) / sr
                    samples[i] = Int16(sin(phase) * 16000)
                }
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                                                      offsetIntoDestination: 0, dataLength: bytes)
                }
            } else {
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sr)),
                presentationTimeStamp: CMTime(value: CMTimeValue(t), timescale: CMTimeScale(sr)),
                decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                sampleCount: chunk, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sb)
            if let sb { aIn.append(sb) }
            t += chunk
        }
        aIn.markAsFinished()
        await w.finishWriting()
    }

    /// Decodes a file's audio and returns its RMS level (0 if no audio), optionally windowed.
    private func audioRMS(_ url: URL, from: Double? = nil, to: Double? = nil) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        if let from, let to {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                           duration: CMTime(seconds: to - from, preferredTimescale: 600))
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(out); reader.startReading()
        var sumSq = 0.0, n = 0
        while reader.status == .reading, let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            if let ptr, len > 1 {
                ptr.withMemoryRebound(to: Int16.self, capacity: len / 2) { p in
                    for i in 0..<(len / 2) { let v = Double(p[i]); sumSq += v * v; n += 1 }
                }
            }
        }
        return n > 0 ? (sumSq / Double(n)).squareRoot() : 0
    }

    func testAudioVolumeScalesLevel() async throws {
        let src = tmp("vol-src.mp4"); try await makeVideoWithAudio(src, seconds: 1.0, tone: true)
        var loud = StyleOptions(); loud.audioVolume = 1.0
        let loudURL = tmp("vol-loud.mp4"); try await StyledExport.export(source: src, to: loudURL, style: loud)
        var quiet = StyleOptions(); quiet.audioVolume = 0.25
        let quietURL = tmp("vol-quiet.mp4"); try await StyledExport.export(source: src, to: quietURL, style: quiet)
        let loudRMS = try await audioRMS(loudURL)
        let quietRMS = try await audioRMS(quietURL)
        XCTAssertGreaterThan(loudRMS, 100, "full-volume export should carry an audible tone")
        XCTAssertLessThan(quietRMS, loudRMS * 0.6, "0.25 gain should be clearly quieter than 1.0")
    }

    func testAudioVolumeRegionsDuckFirstHalf() async throws {
        // 2s tone; duck the first 1s to near-silent, keep the second 1s at full.
        let src = tmp("avr-src.mp4"); try await makeVideoWithAudio(src, seconds: 2.0, tone: true)
        var s = StyleOptions(); s.audioVolumeRegions = [AudioVolumeRegion(start: 0, end: 1.0, volume: 0.05)]
        let out = tmp("avr.mp4")
        try await StyledExport.export(source: src, to: out, style: s)
        let firstRMS = try await audioRMS(out, from: 0.1, to: 0.9)
        let secondRMS = try await audioRMS(out, from: 1.1, to: 1.9)
        XCTAssertGreaterThan(secondRMS, 50, "second half stays audible")
        XCTAssertLessThan(firstRMS, secondRMS * 0.5, "first half ducked well below the second")
    }

    func testNormalizeAudioBoostsQuietTrack() async throws {
        let src = tmp("norm-src.mp4"); try await makeVideoWithAudio(src, seconds: 1.0, tone: true)  // ~half-scale tone
        let plainURL = tmp("norm-plain.mp4")
        try await StyledExport.export(source: src, to: plainURL, style: StyleOptions())
        var s = StyleOptions(); s.normalizeAudio = true
        let normURL = tmp("norm-on.mp4")
        try await StyledExport.export(source: src, to: normURL, style: s)
        let plainRMS = try await audioRMS(plainURL)
        let normRMS = try await audioRMS(normURL)
        XCTAssertGreaterThan(plainRMS, 50)
        XCTAssertGreaterThan(normRMS, plainRMS * 1.3, "normalize should lift the half-scale tone toward full scale")
    }

    func testMuteAudioDropsTrack() async throws {
        let src = tmp("mute-src.mp4"); try await makeVideoWithAudio(src)
        let srcAudio = try await AVURLAsset(url: src).loadTracks(withMediaType: .audio).count
        XCTAssertEqual(srcAudio, 1, "source must have an audio track to test muting")
        // Passthrough keeps the audio…
        let keep = tmp("mute-keep.mp4")
        try await StyledExport.export(source: src, to: keep, style: StyleOptions())
        let keepAudio = try await AVURLAsset(url: keep).loadTracks(withMediaType: .audio).count
        XCTAssertEqual(keepAudio, 1)
        // …mute drops it.
        var s = StyleOptions(); s.muteAudio = true
        let muted = tmp("mute-off.mp4")
        try await StyledExport.export(source: src, to: muted, style: s)
        let mutedAudio = try await AVURLAsset(url: muted).loadTracks(withMediaType: .audio).count
        XCTAssertEqual(mutedAudio, 0, "muteAudio must drop the audio track")
    }

    func testWebcamCropZoomExports() async throws {
        let src = tmp("wcz-src.mp4"); try await makeVideo(src)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 400, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        var wc = WebcamSettings(); wc.enabled = true; wc.cropZoom = 2.0; wc.sizeFraction = 0.25
        let out = tmp("wcz.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      webcam: frames, webcamSettings: wc)
        try await assertValid(out)
    }

    func testWebcamReactToZoom() async throws {
        // Direct check: with reactToZoom on, a zoomed frame yields a larger bubble than 1x.
        // With reactToZoom, run the full export with a zoom region to exercise the scaling path.
        let src = tmp("wcz2-src.mp4"); try await makeVideo(src)
        let camURL = WebcamRecorder.sidecarURL(for: src); try await makeVideo(camURL, size: CGSize(width: 300, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        var wc = WebcamSettings(); wc.enabled = true; wc.reactToZoom = true; wc.sizeFraction = 0.2
        var z = ZoomTimeline(); z.addRegion(start: 0.2, end: 1.0, depth: .strong, focus: CGPoint(x: 0.5, y: 0.5))
        let out = tmp("wcz2.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), zoom: z,
                                      webcam: frames, webcamSettings: wc)
        try await assertValid(out)
    }

    func testWebcamPanOffsetExports() async throws {
        let src = tmp("wcpan-src.mp4"); try await makeVideo(src)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 400, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        var wc = WebcamSettings(); wc.enabled = true; wc.cropZoom = 2.0
        wc.cropOffsetX = -0.8; wc.cropOffsetY = 0.6; wc.sizeFraction = 0.25   // pan to a corner
        wc.timeOffset = 0.15                                                  // small sync shift
        let out = tmp("wcpan.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      webcam: frames, webcamSettings: wc)
        try await assertValid(out)
    }

    func testWebcamCropZoomProjectRoundTrip() throws {
        var wc = WebcamSettings(); wc.cropZoom = 1.75; wc.cropOffsetX = -0.4; wc.cropOffsetY = 0.3; wc.timeOffset = -0.25
        let project = ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"),
                                            style: StyleOptions(), zoom: ZoomTimeline(), webcam: wc,
                                            annotations: [], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wcz.reclip")
        try project.save(to: url)
        let w = try ReclipProject.load(from: url).webcamSettings()
        XCTAssertEqual(w.cropZoom, 1.75, accuracy: 1e-9)
        XCTAssertEqual(w.cropOffsetX, -0.4, accuracy: 1e-9)
        XCTAssertEqual(w.cropOffsetY, 0.3, accuracy: 1e-9)
        XCTAssertEqual(w.timeOffset, -0.25, accuracy: 1e-9)
    }

    func testDirectionalArrowsExport() async throws {
        let src = tmp("arr-src.mp4"); try await makeVideo(src)
        // 8 compass directions, all should composite validly.
        for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
            var a = Annotation(text: "", start: 0.1, end: 1.0)
            a.kind = .arrow; a.arrowAngle = angle; a.position = CGPoint(x: 0.5, y: 0.5)
            a.regionSize = CGSize(width: 0.25, height: 0.25); a.colorRGBA = [1, 0.3, 0.3, 1]
            let out = tmp("arr-\(Int(angle)).mp4")
            try await StyledExport.export(source: src, to: out, style: StyleOptions(), annotations: [a])
            try await assertValid(out)
        }
    }

    func testArrowAngleProjectRoundTrip() throws {
        var a = Annotation(text: "", start: 0, end: 1); a.kind = .arrow; a.arrowAngle = 135
        let project = ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"),
                                            style: StyleOptions(), zoom: ZoomTimeline(), webcam: WebcamSettings(),
                                            annotations: [a], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arr.reclip")
        try project.save(to: url)
        XCTAssertEqual(try ReclipProject.load(from: url).annotationList().first?.arrowAngle ?? -1, 135, accuracy: 1e-9)
    }

    func testAspectPresetCount() {
        XCTAssertEqual(StyleOptions.Aspect.allCases.count, 9, "8 ratio presets + Source")
        // Every non-source preset yields a positive ratio; portrait ones are < 1.
        for a in StyleOptions.Aspect.allCases where a != .source {
            XCTAssertNotNil(a.ratio)
            XCTAssertGreaterThan(a.ratio ?? 0, 0)
        }
        XCTAssertLessThan(StyleOptions.Aspect.portrait.ratio ?? 9, 1)
        XCTAssertGreaterThan(StyleOptions.Aspect.ultrawide.ratio ?? 0, 2)
    }

    func testNewAspectPresetsExport() async throws {
        let src = tmp("asp-src.mp4"); try await makeVideo(src, size: CGSize(width: 800, height: 500))
        for a in [StyleOptions.Aspect.photo, .portrait, .ultrawide] {
            var s = StyleOptions(); s.aspect = a
            let out = tmp("asp-\(a.rawValue.replacingOccurrences(of: ":", with: "-")).mp4")
            try await StyledExport.export(source: src, to: out, style: s)
            let d = try await dims(out)
            let expected = a.ratio!
            XCTAssertEqual(d.width / d.height, expected, accuracy: 0.06, "\(a.rawValue) canvas ratio")
        }
    }

    func testTextAnnotationTypography() async throws {
        let src = tmp("type-src.mp4"); try await makeVideo(src)
        var a = Annotation(text: "Styled", start: 0.1, end: 1.0)
        a.kind = .text; a.bold = false; a.textColorRGBA = [1, 0.9, 0.2, 1]
        a.showBackground = false                       // no pill
        let out = tmp("type.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), annotations: [a])
        try await assertValid(out)
        // Renders differently with vs without a background pill (bigger canvas with pill padding).
        let plain = Annotations.render("Hi", fontSize: 40, showBackground: false)
        let boxed = Annotations.render("Hi", fontSize: 40, showBackground: true)
        XCTAssertNotNil(plain); XCTAssertNotNil(boxed)
    }

    func testTextTypographyProjectRoundTrip() throws {
        var a = Annotation(text: "Hi", start: 0, end: 1)
        a.kind = .text; a.bold = false; a.textColorRGBA = [0.1, 0.2, 0.3, 1]
        a.showBackground = false; a.bgColorRGBA = [0.5, 0, 0, 0.7]
        let project = ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"),
                                            style: StyleOptions(), zoom: ZoomTimeline(), webcam: WebcamSettings(),
                                            annotations: [a], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("type.reclip")
        try project.save(to: url)
        let back = try XCTUnwrap(try ReclipProject.load(from: url).annotationList().first)
        XCTAssertFalse(back.bold)
        XCTAssertFalse(back.showBackground)
        XCTAssertEqual(back.textColorRGBA, [0.1, 0.2, 0.3, 1])
        XCTAssertEqual(back.bgColorRGBA, [0.5, 0, 0, 0.7])
    }

    func testWebcamNineCellPositions() async throws {
        XCTAssertEqual(WebcamSettings.Corner.allCases.count, 9, "full 9-cell position grid")
        let src = tmp("wc9-src.mp4"); try await makeVideo(src)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 300, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        // Exercise the new center positions end-to-end.
        for corner in [WebcamSettings.Corner.center, .topCenter, .centerTrailing, .bottomCenter] {
            var wc = WebcamSettings(); wc.enabled = true; wc.corner = corner; wc.sizeFraction = 0.25
            let out = tmp("wc9-\(corner.rawValue).mp4")
            try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                          webcam: frames, webcamSettings: wc)
            try await assertValid(out)
        }
    }

    func testPerSidePaddingExports() async throws {
        let src = tmp("pad-src.mp4"); try await makeVideo(src)
        var s = StyleOptions()
        s.paddingInsets = .init(top: 0.02, bottom: 0.20, left: 0.15, right: 0.05)  // asymmetric
        let out = tmp("pad.mp4")
        try await StyledExport.export(source: src, to: out, style: s)
        let d = try await dims(out)
        try await assertValid(out)
        XCTAssertGreaterThan(d.width, 0)   // canvas unchanged; footage repositioned within it
    }

    func testPerSidePaddingProjectRoundTrip() throws {
        var s = StyleOptions(); s.paddingInsets = .init(top: 0.03, bottom: 0.11, left: 0.07, right: 0.02)
        let project = ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"),
                                            style: s, zoom: ZoomTimeline(), webcam: WebcamSettings(),
                                            annotations: [], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pad.reclip")
        try project.save(to: url)
        let loaded = try ReclipProject.load(from: url).style().paddingInsets
        XCTAssertEqual(loaded?.bottom ?? -1, 0.11, accuracy: 1e-9)
        XCTAssertEqual(loaded?.left ?? -1, 0.07, accuracy: 1e-9)
    }

    func testCutRemovesMiddleSegment() async throws {
        // 2s source; keep [0,0.5] and [1.5,2.0] → output ≈ 1.0s (cut out the middle 1s).
        let src = tmp("cut-src.mp4"); try await makeVideo(src, seconds: 2.0)
        let out = tmp("cut.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), keepRanges: [0...0.5, 1.5...2.0])
        let dur = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(dur, 1.0, accuracy: 0.15, "kept ranges total ~1s, got \(dur)s")
        XCTAssertLessThan(dur, 1.6, "middle segment actually removed")
        // Round-trips through the project file.
        let project = ReclipProject.capture(source: src, style: StyleOptions(), zoom: ZoomTimeline(),
                                            webcam: WebcamSettings(), annotations: [],
                                            trimStart: 0, trimEnd: 0, speed: 1, keepRanges: [0...0.5, 1.5...2.0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cut.reclip")
        try project.save(to: url)
        let back = try ReclipProject.load(from: url).keepRangeList()
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.first?.upperBound ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(back.last?.lowerBound ?? 0, 1.5, accuracy: 1e-9)
    }

    func testSpeedRegionsChangeOutputDuration() async throws {
        // 2s source; first 1s played at 2×, rest at 1× → output ≈ 0.5 + 1.0 = 1.5s.
        let src = tmp("speedreg-src.mp4"); try await makeVideo(src, seconds: 2.0)
        let regions = [SpeedSegment(start: 0, end: 1.0, speed: 2.0)]
        let expected = SpeedMap(regions: regions, sourceDuration: 2.0).outputDuration
        let out = tmp("speedreg.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), speedRegions: regions)
        let dur = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(dur, expected, accuracy: 0.15, "speed-region output duration should match the SpeedMap (\(expected)s), got \(dur)s")
        // Sanity: it is shorter than the untouched 2s source.
        XCTAssertLessThan(dur, 1.85)

        // Round-trips through the project file.
        let project = ReclipProject.capture(source: src, style: StyleOptions(), zoom: ZoomTimeline(),
                                            webcam: WebcamSettings(), annotations: [],
                                            trimStart: 0, trimEnd: 0, speed: 1, speedRegions: regions)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speedreg.reclip")
        try project.save(to: url)
        let back = try ReclipProject.load(from: url).speedRegions
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.speed ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(back.first?.end ?? 0, 1.0, accuracy: 1e-9)
    }

    func testMaxOutputHeightCapsResolution() async throws {
        let src = tmp("cap-src.mp4"); try await makeVideo(src, size: CGSize(width: 1280, height: 800))
        var s = StyleOptions(); s.maxOutputHeight = 480
        let out = tmp("cap.mp4")
        try await StyledExport.export(source: src, to: out, style: s)
        let d = try await dims(out)
        XCTAssertLessThanOrEqual(d.height, 482, "output height capped near 480, got \(d.height)")
        XCTAssertGreaterThan(d.height, 400, "still a real downscale, not collapsed")
        // Uncapped keeps the native size.
        let out2 = tmp("uncap.mp4")
        try await StyledExport.export(source: src, to: out2, style: StyleOptions())
        let d2 = try await dims(out2)
        XCTAssertGreaterThan(d2.height, 700, "uncapped stays near source height")
    }

    func testRecordingValidation() async throws {
        // A real recording validates…
        let good = tmp("val-good.mp4"); try await makeVideo(good)
        let goodStatus = await RecordingValidator.validate(good)
        XCTAssertTrue(goodStatus.isValid)
        // …a zero-byte file is 'empty'…
        let empty = tmp("val-empty.mp4"); FileManager.default.createFile(atPath: empty.path, contents: Data())
        let emptyStatus = await RecordingValidator.validate(empty)
        XCTAssertEqual(emptyStatus, .empty)
        // …and garbage bytes are 'unreadable'.
        let junk = tmp("val-junk.mp4"); try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: junk)
        let junkStatus = await RecordingValidator.validate(junk)
        XCTAssertFalse(junkStatus.isValid)
        for u in [good, empty, junk] { try? FileManager.default.removeItem(at: u) }
    }

    func testDiscardRemovesRecordingAndSidecars() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("Reclip-take.mp4")
        try await makeVideo(movie)
        let cursor = movie.deletingPathExtension().appendingPathExtension("cursor")
        let project = movie.deletingPathExtension().appendingPathExtension("reclip")
        try "c".data(using: .utf8)!.write(to: cursor)
        try "p".data(using: .utf8)!.write(to: project)
        RecordingValidator.discard(movie)
        for u in [movie, cursor, project] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: u.path), "\(u.lastPathComponent) should be gone")
        }
    }

    func testPruneRemovesIncompleteAndOrphans() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let goodMovie = dir.appendingPathComponent("Reclip-good.mp4")
        try await makeVideo(goodMovie)
        try Data().write(to: dir.appendingPathComponent("Reclip-crashed.mp4"))          // empty → prune
        try "cursor".data(using: .utf8)!.write(to: goodMovie.deletingPathExtension().appendingPathExtension("cursor")) // keep (matches good)
        try "orphan".data(using: .utf8)!.write(to: dir.appendingPathComponent("Reclip-gone.cursor"))  // orphan → prune

        let removed = await RecordingValidator.prune(in: dir)
        let names = Set(removed.map { $0.lastPathComponent })
        XCTAssertTrue(names.contains("Reclip-crashed.mp4"), "empty recording pruned")
        XCTAssertTrue(names.contains("Reclip-gone.cursor"), "orphaned sidecar pruned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: goodMovie.path), "valid recording kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: goodMovie.deletingPathExtension().appendingPathExtension("cursor").path),
                      "sidecar of a valid recording kept")
    }

    func testDeviceFrameExports() async throws {
        let src = tmp("frame-src.mp4"); try await makeVideo(src)
        for frame in [DeviceFrame.macOS, .browser] {
            var s = StyleOptions(); s.deviceFrame = frame
            let out = tmp("frame-\(frame.rawValue).mp4")
            try await StyledExport.export(source: src, to: out, style: s)
            try await assertValid(out)
        }
    }

    func testDeviceFrameAddsChromeBar() {
        // The renderer must return a strictly taller image (bar added above the footage).
        let footage = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let framed = DeviceFrameRenderer.apply(footage, frame: .macOS)
        XCTAssertGreaterThan(framed.extent.height, 300, "chrome bar should increase height")
        XCTAssertEqual(framed.extent.width, 400, accuracy: 1, "width is unchanged")
        // `.none` is a passthrough.
        let none = DeviceFrameRenderer.apply(footage, frame: .none)
        XCTAssertEqual(none.extent.height, 300, accuracy: 1)
    }

    func testDeviceFrameProjectRoundTrip() throws {
        var s = StyleOptions(); s.deviceFrame = .browser
        let project = ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"),
                                            style: s, zoom: ZoomTimeline(), webcam: WebcamSettings(),
                                            annotations: [], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frame.reclip")
        try project.save(to: url)
        XCTAssertEqual(try ReclipProject.load(from: url).style().deviceFrame, .browser)
    }

    func testBackgroundPresetLibrary() {
        let all = BackgroundPresets.all
        XCTAssertGreaterThanOrEqual(all.count, 12, "should offer a full preset gallery")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "preset ids must be unique")
        XCTAssertNotNil(BackgroundPresets.preset(id: "aurora"))
        XCTAssertNil(BackgroundPresets.preset(id: "nope"))
    }

    func testPresetBackgroundExports() async throws {
        let src = tmp("preset-src.mp4"); try await makeVideo(src)
        for id in ["aurora", "graphite", "ocean"] {
            var s = StyleOptions(); s.background = try XCTUnwrap(BackgroundPresets.preset(id: id)).background
            let out = tmp("preset-\(id).mp4")
            try await StyledExport.export(source: src, to: out, style: s)
            try await assertValid(out)
        }
    }

    func testImageBackgroundExports() async throws {
        let src = tmp("imgbg-src.mp4"); try await makeVideo(src)
        // Build a small PNG to use as the wallpaper background.
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 200, height: 200).fill(); img.unlockFocus()
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        var s = StyleOptions(); s.backgroundImage = png; s.paddingFraction = 0.1
        let out = tmp("imgbg.mp4")
        try await StyledExport.export(source: src, to: out, style: s)
        try await assertValid(out)
    }

    func testImageBackgroundProjectRoundTrip() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])   // arbitrary bytes; round-trip is byte-exact
        var s = StyleOptions(); s.backgroundImage = png
        let project = ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"),
                                            style: s, zoom: ZoomTimeline(), webcam: WebcamSettings(),
                                            annotations: [], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imgbg.reclip")
        try project.save(to: url)
        let loaded = try ReclipProject.load(from: url)
        XCTAssertEqual(loaded.style().backgroundImage, png)
    }

    func testSquircleCornerIsFullerThanCircle() {
        let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
        let sq = try! XCTUnwrap(StyledExport.squircleMask(extent: extent, radius: 40))
        // Circular reference mask of the same radius.
        let gen = CIFilter.roundedRectangleGenerator()
        gen.color = .white; gen.extent = extent; gen.radius = 40
        let circ = gen.outputImage!.cropped(to: extent)

        let ctx = CIContext()
        func alpha(_ img: CIImage, _ x: Int, _ y: Int) -> Int {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Int(px[3])
        }
        // (8,8) sits inside the squircle bulge but outside the circle of radius 40 at (40,40).
        XCTAssertGreaterThan(alpha(sq, 8, 8), 200, "squircle corner covers the near-corner pixel")
        XCTAssertLessThan(alpha(circ, 8, 8), 60, "the circle does not")
        // Deep interior is opaque for both; far outside is clear for both.
        XCTAssertGreaterThan(alpha(sq, 50, 50), 200)
        XCTAssertLessThan(alpha(sq, 1, 1), 60)
    }

    func testSquircleExportsAndRoundTrips() async throws {
        let src = tmp("squ-src.mp4"); try await makeVideo(src)
        var s = StyleOptions(); s.squircleCorners = true; s.cornerRadiusFraction = 0.06
        let out = tmp("squ.mp4")
        try await StyledExport.export(source: src, to: out, style: s)
        try await assertValid(out)
        let project = ReclipProject.capture(source: src, style: s, zoom: ZoomTimeline(), webcam: WebcamSettings(),
                                            annotations: [], trimStart: 0, trimEnd: 0, speed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("squ.reclip")
        try project.save(to: url)
        XCTAssertTrue(try ReclipProject.load(from: url).style().squircleCorners)
    }

    func testShadowProfilesDecreasePerLayer() {
        let p = StyledExport.videoShadowProfiles
        XCTAssertEqual(p.count, 3)                                    // Recordly's 3-layer video shadow
        XCTAssertGreaterThan(p[0].blurScale, p[1].blurScale)         // wide base → tighter layers
        XCTAssertGreaterThan(p[1].blurScale, p[2].blurScale)
        XCTAssertGreaterThan(p[0].alphaScale, p[2].alphaScale)      // and progressively fainter
        XCTAssertGreaterThan(p[0].offsetScale, p[2].offsetScale)
    }

    func testLayeredShadowExports() async throws {
        let src = tmp("shadow-src.mp4"); try await makeVideo(src)
        var s = StyleOptions(); s.shadowOpacity = 0.6; s.shadowRadius = 30
        let out = tmp("shadow.mp4")
        try await StyledExport.export(source: src, to: out, style: s)
        try await assertValid(out)
    }

    func testBitrateTiers() {
        XCTAssertEqual(ExportBitrate.base(width: 1280, height: 720), 10_000_000)
        XCTAssertEqual(ExportBitrate.base(width: 1920, height: 1080), 20_000_000)
        XCTAssertEqual(ExportBitrate.base(width: 3840, height: 2160), 30_000_000)
        XCTAssertEqual(ExportBitrate.mp4(width: 1920, height: 1080, quality: .high), 20_000_000)
        XCTAssertLessThan(ExportBitrate.mp4(width: 1920, height: 1080, quality: .low),
                          ExportBitrate.mp4(width: 1920, height: 1080, quality: .high))
        XCTAssertGreaterThanOrEqual(ExportBitrate.mp4(width: 320, height: 240, quality: .low),
                                    ExportBitrate.minimum)   // never below the floor
        // Source is the max tier — above High at every resolution.
        XCTAssertEqual(ExportQuality.allCases.count, 4)
        XCTAssertGreaterThan(ExportBitrate.mp4(width: 3840, height: 2160, quality: .source),
                             ExportBitrate.mp4(width: 3840, height: 2160, quality: .high))
        XCTAssertEqual(ExportBitrate.mp4(width: 3840, height: 2160, quality: .source), 80_000_000)
        // Encoding mode scales the bitrate (Recordly's 0.1/0.75/1.0 multipliers).
        let q = ExportBitrate.mp4(width: 1920, height: 1080, quality: .high, encoding: .quality)
        let b = ExportBitrate.mp4(width: 1920, height: 1080, quality: .high, encoding: .balanced)
        let f = ExportBitrate.mp4(width: 1920, height: 1080, quality: .high, encoding: .fast)
        XCTAssertEqual(Double(b), Double(q) * 0.75, accuracy: 1)
        XCTAssertLessThan(f, b)
        XCTAssertGreaterThanOrEqual(f, ExportBitrate.minimum)   // floor still applies
    }

    /// The re-encode path must actually change the output frame-rate — this is the gap
    /// the preset exporter couldn't close, so it's verified by counting real frames.
    func testReencodedFrameRateIsApplied() async throws {
        let src = tmp("fps-src.mp4")
        try await makeVideo(src, size: CGSize(width: 640, height: 400), seconds: 2.0, fps: 30)
        for target in [MP4FrameRate.fps24, .fps60] {
            let out = tmp("fps-\(target.rawValue).mp4")
            try await StyledExport.exportReencoded(source: src, to: out, style: StyleOptions(),
                                                   frameRate: target)
            try await assertValid(out)
            let count = try await frameCount(out)
            let dur = try await AVURLAsset(url: out).load(.duration).seconds
            let fps = Double(count) / dur
            XCTAssertEqual(fps, Double(target.rawValue), accuracy: 4,
                           "expected ~\(target.rawValue)fps, got \(fps) (\(count) frames / \(dur)s)")
        }
    }

    func testReencodedWithStyleAndAudioIsValid() async throws {
        let src = tmp("reenc-src.mp4"); try await makeVideo(src)
        var s = StyleOptions(); s.aspect = .square; s.backgroundBlur = 3
        let out = tmp("reenc.mp4")
        try await StyledExport.exportReencoded(source: src, to: out, style: s,
                                               quality: .medium, frameRate: .fps30)
        try await assertValid(out)
        let d = try await dims(out)
        XCTAssertEqual(d.width, d.height, accuracy: 4, "square aspect survives the re-encode path")
    }

    func testCaptionRenderExports() async throws {
        let src = tmp("cap-src.mp4"); try await makeVideo(src)
        let cues = [CaptionCue(text: "Hello there", start: 0.1, end: 1.0)]
        var cs = CaptionSettings(); cs.enabled = true; cs.fontFraction = 0.06
        let out = tmp("cap.mp4")
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      captions: cues, captionSettings: cs)
        try await assertValid(out)
    }
}
