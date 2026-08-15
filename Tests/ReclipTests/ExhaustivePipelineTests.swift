import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import Reclip

/// Exhaustive functional coverage of the editor + export engine across every feature
/// and combination that does not require the live screen-capture GUI. Runs headlessly.
final class ExhaustivePipelineTests: XCTestCase {

    private func tmp(_ n: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reclip-ex-\(n)")
    }

    private func makeVideo(_ url: URL, size: CGSize = CGSize(width: 640, height: 400),
                           seconds: Double = 1.5, fps: Int32 = 30) async throws {
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
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1); ctx.fill(CGRect(origin: .zero, size: size))
            let x = CGFloat(i) / CGFloat(max(total, 1)) * (size.width - 60)
            ctx.setFillColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)
            ctx.fill(CGRect(x: x, y: size.height / 2 - 30, width: 60, height: 60))
            CVPixelBufferUnlockBaseAddress(pb, [])
            ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished(); await w.finishWriting()
    }

    private func validVideo(_ url: URL, minDur: Double) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        let a = AVURLAsset(url: url)
        let tracks = try await a.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "no video track in \(url.lastPathComponent)")
        let d = try await a.load(.duration).seconds
        XCTAssertGreaterThan(d, minDur, "too short \(url.lastPathComponent)")
    }

    // Every background preset must export a valid video.
    func testAllBackgroundPresets() async throws {
        let src = tmp("bg-src.mp4"); try await makeVideo(src)
        let backgrounds: [StyleOptions.Background] = [
            .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97)),
            .gradient(topRGB: (1.0, 0.42, 0.42), bottomRGB: (0.99, 0.79, 0.34)),
            .gradient(topRGB: (0.15, 0.55, 0.95), bottomRGB: (0.10, 0.20, 0.45)),
            .solid(red: 0.11, green: 0.12, blue: 0.14),
            .solid(red: 0.96, green: 0.96, blue: 0.97)
        ]
        for (i, bg) in backgrounds.enumerated() {
            let out = tmp("bg-\(i).mp4")
            var style = StyleOptions(); style.background = bg
            try await StyledExport.export(source: src, to: out, style: style)
            try await validVideo(out, minDur: 1.0)
        }
    }

    // Webcam bubble in every corner.
    func testWebcamAllCorners() async throws {
        let src = tmp("wc-src.mp4"); try await makeVideo(src)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 300, height: 300))
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty)
        for corner in WebcamSettings.Corner.allCases {
            let out = tmp("wc-\(corner.rawValue).mp4")
            var s = WebcamSettings(); s.enabled = true; s.corner = corner
            try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                          webcam: frames, webcamSettings: s)
            try await validVideo(out, minDur: 1.0)
        }
    }

    // Everything at once: zoom + webcam + multiple captions + trim + speed -> MP4 and GIF.
    func testAllFeaturesCombinedMP4AndGIF() async throws {
        let src = tmp("all-src.mp4"); try await makeVideo(src, seconds: 2.0)
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeVideo(cam, size: CGSize(width: 300, height: 300), seconds: 2.0)
        let frames = await WebcamOverlay.load(for: src)

        var track = CursorTrack()
        for i in 0..<60 { track.samples.append(CursorSample(t: Double(i) / 30.0, x: 0.5, y: 0.5)) }
        let zoom = ZoomTimeline.autoZoom(from: track, duration: 2.0, segment: 1.0)

        var webcam = WebcamSettings(); webcam.enabled = true
        let captions = [Annotation(text: "Intro", start: 0.1, end: 0.8),
                        Annotation(text: "Detail", start: 0.9, end: 1.6)]
        let trim = CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 600),
                               duration: CMTime(seconds: 1.4, preferredTimescale: 600))

        let mp4 = tmp("all.mp4")
        try await StyledExport.export(source: src, to: mp4, style: StyleOptions(), zoom: zoom,
                                      trim: trim, webcam: frames, webcamSettings: webcam,
                                      annotations: captions, speed: 1.5)
        try await validVideo(mp4, minDur: 0.5)

        let gif = tmp("all.gif")
        try await GifExport.export(source: src, to: gif, style: StyleOptions(), zoom: zoom,
                                   trim: trim, webcam: frames, webcamSettings: webcam,
                                   annotations: captions, speed: 1.5, fps: 8)
        let cgSrc = CGImageSourceCreateWithURL(gif as CFURL, nil)
        XCTAssertNotNil(cgSrc)
        XCTAssertGreaterThan(CGImageSourceGetCount(cgSrc!), 1)
    }

    // Speed extremes both produce valid output with expected duration direction.
    func testSpeedExtremes() async throws {
        let src = tmp("spd-src.mp4"); try await makeVideo(src, seconds: 2.0)
        let fast = tmp("fast.mp4")
        try await StyledExport.export(source: src, to: fast, style: StyleOptions(), speed: 4.0)
        let fastDur = try await AVURLAsset(url: fast).load(.duration).seconds
        XCTAssertLessThan(fastDur, 1.0)          // 2s / 4x -> ~0.5s

        let slow = tmp("slow.mp4")
        try await StyledExport.export(source: src, to: slow, style: StyleOptions(), speed: 0.5)
        let slowDur = try await AVURLAsset(url: slow).load(.duration).seconds
        XCTAssertGreaterThan(slowDur, 3.0)       // 2s / 0.5x -> ~4s
    }

    // No cursor data must not crash auto-zoom or export.
    func testExportWithoutCursorOrWebcam() async throws {
        let src = tmp("bare-src.mp4"); try await makeVideo(src)
        let out = tmp("bare.mp4")
        let zoom = ZoomTimeline.autoZoom(from: CursorTrack(), duration: 1.5)
        XCTAssertTrue(zoom.regions.isEmpty)
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), zoom: zoom)
        try await validVideo(out, minDur: 1.0)
    }
}
