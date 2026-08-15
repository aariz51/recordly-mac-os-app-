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
