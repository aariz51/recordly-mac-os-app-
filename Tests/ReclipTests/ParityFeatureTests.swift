import XCTest
import AVFoundation
import CoreGraphics
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
