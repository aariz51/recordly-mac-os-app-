import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import Reclip

/// End-to-end functional tests of the editor + export pipeline on a synthetic clip.
/// These need no screen-recording permission or GUI, so they run headlessly in CI.
final class PipelineTests: XCTestCase {

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reclip-test-\(name)")
    }

    /// Write a short synthetic H.264 clip (moving square) to `url`.
    private func makeTestVideo(_ url: URL,
                               size: CGSize = CGSize(width: 640, height: 480),
                               seconds: Double = 2.0, fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let total = Int(Double(fps) * seconds)
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { usleep(500) }
            let pb = makePixelBuffer(size: size, frame: i, total: total)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func makePixelBuffer(size: CGSize, frame: Int, total: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer!
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                            width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        let x = CGFloat(frame) / CGFloat(max(total, 1)) * (size.width - 80)
        ctx.setFillColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: x, y: size.height / 2 - 40, width: 80, height: 80))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func assertValidVideo(_ url: URL, minDuration: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "output missing", file: file, line: line)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "no video track", file: file, line: line)
        let dur = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(dur, minDuration, "duration too short", file: file, line: line)
    }

    // MARK: - Tests

    func testStyledMP4ExportWithZoomAndCaptions() async throws {
        let src = tmp("src1.mp4"); let out = tmp("out1.mp4")
        try await makeTestVideo(src)

        var track = CursorTrack()
        for i in 0..<60 { track.samples.append(CursorSample(t: Double(i) / 30.0, x: 0.5, y: 0.5)) }
        let zoom = ZoomTimeline.autoZoom(from: track, duration: 2.0, segment: 1.5)

        let captions = [Annotation(text: "Hello", start: 0.2, end: 1.5)]
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      zoom: zoom, annotations: captions)
        try await assertValidVideo(out, minDuration: 1.5)
    }

    func testSpeedHalvesDuration() async throws {
        let src = tmp("src2.mp4"); let out = tmp("out2.mp4")
        try await makeTestVideo(src, seconds: 2.0)
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), speed: 2.0)
        // 2s at 2x -> ~1s
        let dur = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(dur, 1.0, accuracy: 0.25)
    }

    func testTrimShortensOutput() async throws {
        let src = tmp("src3.mp4"); let out = tmp("out3.mp4")
        try await makeTestVideo(src, seconds: 2.0)
        let trim = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                               duration: CMTime(seconds: 1.0, preferredTimescale: 600))
        try await StyledExport.export(source: src, to: out, style: StyleOptions(), trim: trim)
        let dur = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(dur, 1.0, accuracy: 0.25)
    }

    func testWebcamOverlayComposites() async throws {
        let src = tmp("src4.mp4"); let out = tmp("out4.mp4")
        try await makeTestVideo(src)
        // synthetic webcam sidecar
        let cam = WebcamRecorder.sidecarURL(for: src)
        try await makeTestVideo(cam, size: CGSize(width: 320, height: 320), seconds: 2.0)
        let frames = await WebcamOverlay.load(for: src)
        XCTAssertFalse(frames.isEmpty, "webcam frames should load")
        var settings = WebcamSettings(); settings.enabled = true
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      webcam: frames, webcamSettings: settings)
        try await assertValidVideo(out, minDuration: 1.5)
    }

    func testGifExportProducesMultiFrameGif() async throws {
        let src = tmp("src5.mp4"); let out = tmp("out5.gif")
        try await makeTestVideo(src, seconds: 1.5)
        try await GifExport.export(source: src, to: out, style: StyleOptions(), fps: 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let source = CGImageSourceCreateWithURL(out as CFURL, nil)
        XCTAssertNotNil(source)
        XCTAssertGreaterThan(CGImageSourceGetCount(source!), 1, "GIF should have multiple frames")
    }
}
