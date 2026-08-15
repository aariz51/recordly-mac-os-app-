import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
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
}
