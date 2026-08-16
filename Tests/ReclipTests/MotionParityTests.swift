import XCTest
import AVFoundation
import CoreImage
import CoreGraphics
@testable import Reclip

/// Covers the parity work that made the engine's motion + animation settings real:
/// the precomputed cursor motion track, the click-effect styles, caption animation,
/// and the split/connected zoom timing.
final class MotionParityTests: XCTestCase {

    // MARK: - Smoothed cursor track

    private func straightTrack(duration: Double = 2.0) -> CursorTrack {
        var t = CursorTrack()
        // A cursor crossing the frame left→right at constant speed.
        t.samples = stride(from: 0.0, through: duration, by: 1.0 / 30).map {
            CursorSample(t: $0, x: 0.1 + 0.8 * ($0 / duration), y: 0.5)
        }
        return t
    }

    func testSmoothedTrackCoversTheClipAtTheRequestedCadence() {
        let track = straightTrack()
        var style = CursorStyle(); style.enabled = true
        let m = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0, fps: 60)
        XCTAssertFalse(m.isEmpty)
        // 2s at 60fps, inclusive of both ends.
        XCTAssertEqual(m.samples.count, 121, accuracy: 1)
        XCTAssertEqual(m.samples.first?.t ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(m.samples.last?.t ?? -1, 2.0, accuracy: 0.02)
    }

    /// A spring chasing a *moving* target settles at a constant lag behind it — that is the
    /// defining behaviour, not a defect, and it is what makes the pointer glide. So the
    /// property to assert is that the lag is bounded and steady (the path is followed, never
    /// diverged from), not that the two coincide.
    func testSmoothedPathTrailsTheTargetByAConstantAmount() {
        let track = straightTrack()
        var style = CursorStyle(); style.enabled = true; style.smoothing = 0.67
        let m = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0)

        var lags: [Double] = []
        for t in stride(from: 0.8, through: 1.8, by: 0.1) {
            let raw = track.interpolated(at: t)!
            let s = m.sample(at: t)!
            let lag = raw.x - s.x
            XCTAssertGreaterThan(lag, 0, "the smoothed cursor trails the target, never leads it")
            lags.append(lag)
            // Motion is purely horizontal, so y has nothing to lag behind.
            XCTAssertEqual(s.y, raw.y, accuracy: 0.01)
        }
        // Steady state: the lag has stopped changing, so the path is tracked, not lost.
        let spread = lags.max()! - lags.min()!
        XCTAssertLessThan(spread, 0.01, "the lag should settle to a constant, got a spread of \(spread)")
    }

    func testLessSmoothingMeansLessLag() {
        let track = straightTrack()
        func lag(smoothing: Double) -> Double {
            var style = CursorStyle(); style.enabled = true; style.smoothing = smoothing
            let m = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0)
            return track.interpolated(at: 1.5)!.x - m.sample(at: 1.5)!.x
        }
        XCTAssertLessThan(lag(smoothing: 0), lag(smoothing: 0.67))
        XCTAssertLessThan(lag(smoothing: 0.67), lag(smoothing: 2.0))
    }

    func testSpringSettlesExactlyOnAStationaryTarget() {
        // Once the cursor stops, the smoothed path must converge on it — a permanent offset
        // would leave the drawn pointer beside the real one.
        var track = CursorTrack()
        track.samples = [CursorSample(t: 0, x: 0.2, y: 0.3), CursorSample(t: 0.1, x: 0.8, y: 0.7),
                         CursorSample(t: 3.0, x: 0.8, y: 0.7)]
        var style = CursorStyle(); style.enabled = true; style.smoothing = 0.67
        let m = SmoothedCursorTrack.build(track: track, style: style, duration: 3.0)
        let end = m.sample(at: 2.9)!
        XCTAssertEqual(end.x, 0.8, accuracy: 0.002)
        XCTAssertEqual(end.y, 0.7, accuracy: 0.002)
    }

    func testSwayStaysWithinItsBoundAndIsOffWhenZero() {
        let track = straightTrack()
        var style = CursorStyle(); style.enabled = true; style.sway = 2.0
        let swung = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0)
        // CursorSway caps at maxRotation × sway × intensityScale; nothing may exceed it.
        let cap = CursorSway.maxRotation * 2.0 * CursorSway.intensityScale
        for s in swung.samples {
            XCTAssertLessThanOrEqual(abs(s.rotation), cap + 1e-6)
        }

        style.sway = 0
        let straight = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0)
        for s in straight.samples { XCTAssertEqual(s.rotation, 0, accuracy: 1e-9) }
    }

    func testClickBounceDipsThenRecovers() {
        var track = straightTrack()
        track.clicks = [1.0]
        var style = CursorStyle(); style.enabled = true
        style.clickBounce = 2.5
        style.clickBounceDuration = 350
        let m = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0)

        // Before the click: at rest.
        XCTAssertEqual(m.sample(at: 0.9)!.scale, 1.0, accuracy: 1e-9)
        // Mid-bounce: visibly smaller (the sine dip peaks partway through the window).
        let dipped = m.sample(at: 1.09)!.scale
        XCTAssertLessThan(dipped, 0.99, "the cursor should dip on a click")
        XCTAssertGreaterThanOrEqual(dipped, CursorClickEffect.bounceScaleFloor)
        // After the window: back to rest.
        XCTAssertEqual(m.sample(at: 1.6)!.scale, 1.0, accuracy: 1e-9)
    }

    func testNoBounceWhenTheSettingIsZero() {
        var track = straightTrack()
        track.clicks = [1.0]
        var style = CursorStyle(); style.enabled = true; style.clickBounce = 0
        let m = SmoothedCursorTrack.build(track: track, style: style, duration: 2.0)
        for s in m.samples { XCTAssertEqual(s.scale, 1.0, accuracy: 1e-9) }
    }

    func testEmptyTrackProducesNoMotion() {
        let m = SmoothedCursorTrack.build(track: CursorTrack(), style: CursorStyle(), duration: 2)
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.sample(at: 1))
    }

    func testRendererFallsBackToTheRawPathWithoutMotion() {
        let track = straightTrack()
        let resolved = CursorRenderer.resolve(track: track, motion: nil, time: 1.0)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved!.x, track.interpolated(at: 1.0)!.x, accuracy: 1e-9)
        XCTAssertEqual(resolved!.rotation, 0)
        XCTAssertEqual(resolved!.scale, 1)
    }

    // MARK: - Click effect styles

    /// Brightest pixel along a horizontal scan line through the click point.
    private func peakLuma(_ image: CIImage, y: Int, xs: Range<Int>) -> Int {
        let ctx = CIContext()
        var peak = 0
        for x in xs {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(image, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            peak = max(peak, Int(px[0]))
        }
        return peak
    }

    private func clickScene() -> (CIImage, CursorTrack) {
        let base = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
        var track = CursorTrack()
        track.samples = [CursorSample(t: 0, x: 0.5, y: 0.5), CursorSample(t: 1, x: 0.5, y: 0.5)]
        track.clicks = [0.5]
        return (base, track)
    }

    func testEachClickEffectStyleDrawsSomething() {
        let (base, track) = clickScene()
        for effect in [CursorClickEffectStyle.ripple, .spotlight, .echo] {
            var cs = CursorStyle()
            cs.enabled = true; cs.showClicks = true; cs.size = 2.0
            cs.clickBounceDuration = 200
            cs.clickEffectDurationMs = 500
            cs.clickEffect = effect
            let drawn = CursorRenderer.drawClicks(on: base, track: track, time: 0.62, style: cs)
            XCTAssertGreaterThan(peakLuma(drawn, y: 150, xs: 150..<215), 40,
                                 "\(effect.rawValue) should brighten the frame near the click")
        }
    }

    func testNoneDrawsNothing() {
        let (base, track) = clickScene()
        var cs = CursorStyle()
        cs.enabled = true; cs.showClicks = true; cs.size = 2.0
        cs.clickEffect = .none
        let drawn = CursorRenderer.drawClicks(on: base, track: track, time: 0.62, style: cs)
        XCTAssertLessThan(peakLuma(drawn, y: 150, xs: 150..<215), 40)
    }

    func testClickEffectOpacityScalesTheGraphic() {
        let (base, track) = clickScene()
        func peak(opacity: Double) -> Int {
            var cs = CursorStyle()
            cs.enabled = true; cs.showClicks = true; cs.size = 2.0
            cs.clickBounceDuration = 200; cs.clickEffectDurationMs = 500
            cs.clickEffectOpacity = opacity
            let drawn = CursorRenderer.drawClicks(on: base, track: track, time: 0.62, style: cs)
            return peakLuma(drawn, y: 150, xs: 150..<215)
        }
        XCTAssertGreaterThan(peak(opacity: 1.0), peak(opacity: 0.25),
                             "a fainter effect must render dimmer")
    }

    // MARK: - Caption animation

    func testCaptionAnimationOffIsAlwaysFullyVisible() {
        var s = CaptionSettings(); s.animation = .off
        let cue = CaptionCue(text: "hi", start: 1, end: 3)
        for t in [1.0, 1.5, 2.0, 3.0] {
            let x = CaptionTransform.at(time: t, cue: cue, settings: s)
            XCTAssertEqual(x.opacity, 1, accuracy: 1e-9)
            XCTAssertEqual(x.offsetY, 0, accuracy: 1e-9)
            XCTAssertEqual(x.scale, 1, accuracy: 1e-9)
        }
    }

    func testFadeRampsInAndOut() {
        var s = CaptionSettings(); s.animation = .fade; s.animationDuration = 0.2
        let cue = CaptionCue(text: "hi", start: 1, end: 3)
        XCTAssertEqual(CaptionTransform.at(time: 1.0, cue: cue, settings: s).opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(CaptionTransform.at(time: 2.0, cue: cue, settings: s).opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(CaptionTransform.at(time: 3.0, cue: cue, settings: s).opacity, 0, accuracy: 1e-9)
        // Monotonic through the entrance.
        let a = CaptionTransform.at(time: 1.05, cue: cue, settings: s).opacity
        let b = CaptionTransform.at(time: 1.15, cue: cue, settings: s).opacity
        XCTAssertLessThan(a, b)
    }

    func testRiseStartsBelowAndSettles() {
        var s = CaptionSettings(); s.animation = .rise; s.animationDuration = 0.2
        let cue = CaptionCue(text: "hi", start: 1, end: 3)
        XCTAssertLessThan(CaptionTransform.at(time: 1.0, cue: cue, settings: s).offsetY, 0)
        XCTAssertEqual(CaptionTransform.at(time: 2.0, cue: cue, settings: s).offsetY, 0, accuracy: 1e-9)
    }

    func testPopStartsSmallAndSettlesAtFullSize() {
        var s = CaptionSettings(); s.animation = .pop; s.animationDuration = 0.2
        let cue = CaptionCue(text: "hi", start: 1, end: 3)
        XCTAssertLessThan(CaptionTransform.at(time: 1.0, cue: cue, settings: s).scale, 0.9)
        XCTAssertEqual(CaptionTransform.at(time: 2.0, cue: cue, settings: s).scale, 1, accuracy: 1e-9)
    }

    // MARK: - Zoom timing

    private func twoRegions(gap: Double) -> ZoomTimeline {
        var tl = ZoomTimeline()
        tl.regions = [
            ZoomRegion(start: 0, end: 2, scale: 2, focus: CGPoint(x: 0.2, y: 0.2)),
            ZoomRegion(start: 2 + gap, end: 5, scale: 2, focus: CGPoint(x: 0.8, y: 0.8)),
        ]
        return tl
    }

    func testSplitInOutDurationsAreUsedIndependently() {
        var tl = ZoomTimeline()
        tl.regions = [ZoomRegion(start: 0, end: 4, scale: 2, focus: CGPoint(x: 0.5, y: 0.5))]
        tl.inDuration = 0.5
        tl.outDuration = 2.0
        tl.inEasing = .linear
        tl.outEasing = .linear
        // Halfway through a 0.5s entrance.
        XCTAssertEqual(tl.value(at: 0.25).scale, 1.5, accuracy: 0.01)
        // Halfway through a 2.0s exit (t = 4 - 1.0).
        XCTAssertEqual(tl.value(at: 3.0).scale, 1.5, accuracy: 0.01)
    }

    func testFallsBackToTheLegacyRampWhenUnset() {
        var tl = ZoomTimeline()
        tl.ramp = 1.0
        tl.easing = .linear
        tl.regions = [ZoomRegion(start: 0, end: 4, scale: 3, focus: CGPoint(x: 0.5, y: 0.5))]
        XCTAssertEqual(tl.effectiveInDuration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tl.effectiveOutDuration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tl.value(at: 0.5).scale, 2.0, accuracy: 0.01)
    }

    func testDisconnectedZoomsReturnToNoZoomBetweenRegions() {
        var tl = twoRegions(gap: 1.0)
        tl.connectZooms = false
        XCTAssertEqual(tl.value(at: 2.5).scale, 1.0, accuracy: 1e-9)
    }

    func testConnectedZoomsHoldDepthAndPanAcrossTheGap() {
        var tl = twoRegions(gap: 1.0)
        tl.connectZooms = true
        tl.connectedGap = 1.5
        tl.connectedDuration = 1.0
        tl.connectedEasing = .linear

        let mid = tl.value(at: 2.5)
        // Depth is held rather than dropping to 1×…
        XCTAssertEqual(mid.scale, 2.0, accuracy: 0.01)
        // …and the focus travels from the first region's point to the second's.
        XCTAssertEqual(mid.focus.x, 0.5, accuracy: 0.05)
        XCTAssertEqual(mid.focus.y, 0.5, accuracy: 0.05)
    }

    func testConnectionIsSkippedWhenTheGapIsTooLong() {
        var tl = twoRegions(gap: 3.0)
        tl.connectZooms = true
        tl.connectedGap = 1.5     // gap of 3s exceeds it
        XCTAssertEqual(tl.value(at: 3.5).scale, 1.0, accuracy: 1e-9)
    }

    func testConnectedEdgesDoNotRampOut() {
        var tl = twoRegions(gap: 0.5)
        tl.connectZooms = true
        tl.connectedGap = 1.5
        tl.outDuration = 1.0
        tl.inDuration = 1.0
        // Just inside the end of the first region: without connection this would be ramping
        // down; connected, it stays at full depth.
        XCTAssertEqual(tl.value(at: 1.9).scale, 2.0, accuracy: 0.01)
        // And just inside the start of the second.
        XCTAssertEqual(tl.value(at: 2.6).scale, 2.0, accuracy: 0.01)
    }

    func testMotionPresetsSetEveryTiming() {
        var tl = ZoomTimeline()
        tl.apply(preset: .focused)
        let focusedIn = tl.effectiveInDuration
        tl.apply(preset: .smooth)
        XCTAssertGreaterThan(tl.effectiveInDuration, focusedIn,
                             "the smooth preset should ease in more slowly than focused")
        XCTAssertEqual(tl.effectiveInEasing, .recordly)
    }

    // MARK: - Project round-trip

    func testNewSettingsSurviveAProjectRoundTrip() throws {
        var style = CursorStyle()
        style.enabled = true
        style.smoothing = 1.25
        style.sway = 0.8
        style.clickBounce = 3.0
        style.clickBounceDuration = 275
        style.clickEffect = .echo
        style.clickEffectRGB = [0.2, 0.4, 0.9]
        style.clickEffectScale = 1.75
        style.clickEffectOpacity = 0.6
        style.clickEffectDurationMs = 820

        var captions = CaptionSettings()
        captions.enabled = true
        captions.animation = .pop
        captions.animationDuration = 0.31
        captions.fontName = "Helvetica"
        captions.maxWidthFraction = 0.55

        var zoom = ZoomTimeline()
        zoom.regions = [ZoomRegion(start: 1, end: 3, scale: 2.2, focus: CGPoint(x: 0.3, y: 0.7))]
        zoom.inDuration = 0.9
        zoom.outDuration = 1.4
        zoom.inEasing = .snappy
        zoom.outEasing = .glide
        zoom.connectZooms = true
        zoom.connectedGap = 2.25
        zoom.connectedDuration = 0.8
        zoom.connectedEasing = .linear

        let project = ReclipProject.capture(
            source: URL(fileURLWithPath: "/tmp/clip.mp4"),
            style: StyleOptions(), zoom: zoom, webcam: WebcamSettings(), annotations: [],
            trimStart: 0, trimEnd: 5, speed: 1,
            cursorStyle: style,
            captionCues: [CaptionCue(text: "hello", start: 0, end: 1)],
            captionsEnabled: true,
            captionSettings: captions)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclip-motion-\(UUID().uuidString).reclip")
        defer { try? FileManager.default.removeItem(at: url) }
        try project.save(to: url)
        let loaded = try ReclipProject.load(from: url)

        let cs = loaded.cursorStyleValue()
        XCTAssertEqual(cs.smoothing, 1.25, accuracy: 1e-9)
        XCTAssertEqual(cs.sway, 0.8, accuracy: 1e-9)
        XCTAssertEqual(cs.clickBounce, 3.0, accuracy: 1e-9)
        XCTAssertEqual(cs.clickBounceDuration, 275, accuracy: 1e-9)
        XCTAssertEqual(cs.clickEffect, .echo)
        XCTAssertEqual(cs.clickEffectRGB, [0.2, 0.4, 0.9])
        XCTAssertEqual(cs.clickEffectScale, 1.75, accuracy: 1e-9)
        XCTAssertEqual(cs.clickEffectOpacity, 0.6, accuracy: 1e-9)
        XCTAssertEqual(cs.clickEffectDurationMs, 820, accuracy: 1e-9)

        let cap = loaded.captionSettingsValue()
        XCTAssertTrue(cap.enabled)
        XCTAssertEqual(cap.animation, .pop)
        XCTAssertEqual(cap.animationDuration, 0.31, accuracy: 1e-9)
        XCTAssertEqual(cap.fontName, "Helvetica")
        XCTAssertEqual(cap.maxWidthFraction, 0.55, accuracy: 1e-9)

        let z = loaded.zoomTimeline()
        XCTAssertEqual(z.inDuration ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(z.outDuration ?? -1, 1.4, accuracy: 1e-9)
        XCTAssertEqual(z.inEasing, .snappy)
        XCTAssertEqual(z.outEasing, .glide)
        XCTAssertTrue(z.connectZooms)
        XCTAssertEqual(z.connectedGap, 2.25, accuracy: 1e-9)
        XCTAssertEqual(z.connectedDuration, 0.8, accuracy: 1e-9)
        XCTAssertEqual(z.connectedEasing, .linear)
    }

    /// An older project file — one written before these fields existed — must still load.
    func testLegacyProjectFileStillDecodes() throws {
        let legacy = """
        {
          "version": 1, "sourceFileName": "clip.mp4",
          "background": { "kind": "solid", "solid": [0.1, 0.1, 0.1] },
          "paddingFraction": 0.06, "cornerRadiusFraction": 0.03,
          "shadowOpacity": 0.35, "shadowRadius": 24, "backgroundBlur": 0,
          "aspect": "Source",
          "crop": { "top": 0, "bottom": 0, "left": 0, "right": 0 },
          "zoomRegions": [], "webcam": {
            "enabled": false, "corner": "Bottom right", "size": 0.22, "margin": 0.04,
            "roundness": 1, "mirror": true, "shadow": true
          },
          "captions": [], "trimStart": 0, "trimEnd": 10, "speed": 1
        }
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclip-legacy-\(UUID().uuidString).reclip")
        defer { try? FileManager.default.removeItem(at: url) }
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ReclipProject.load(from: url)
        // Defaults fill in for everything the old file didn't know about.
        XCTAssertEqual(loaded.cursorStyleValue().clickEffect, .ripple)
        XCTAssertEqual(loaded.captionSettingsValue().animation, .fade)
        XCTAssertFalse(loaded.zoomTimeline().connectZooms)
        XCTAssertNil(loaded.zoomTimeline().inDuration)
        XCTAssertEqual(loaded.trimEnd, 10, accuracy: 1e-9)
    }
}

/// End-to-end checks that the settings the editor now exposes actually reach the rendered
/// frame. These build their own clip, so they need no GUI or screen-recording permission.
final class MotionPipelineTests: XCTestCase {

    private func makeClip(_ url: URL, size: CGSize = CGSize(width: 640, height: 480),
                          seconds: Double = 3.0, fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
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
            var pb: CVPixelBuffer!
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            // A mid-grey field, so both brightening and darkening effects are measurable.
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func cursorTrack(duration: Double = 3.0) -> CursorTrack {
        var t = CursorTrack()
        t.samples = stride(from: 0.0, through: duration, by: 1.0 / 30).map {
            CursorSample(t: $0, x: 0.2 + 0.6 * ($0 / duration), y: 0.5)
        }
        t.clicks = [1.0]
        return t
    }

    private func render(_ clip: URL, at time: Double,
                        style: StyleOptions = StyleOptions(),
                        cursor: CursorTrack? = nil,
                        cursorStyle: CursorStyle = CursorStyle(),
                        captions: [CaptionCue] = [],
                        captionSettings: CaptionSettings = CaptionSettings()) async throws -> [UInt8] {
        let tl = try await StyledExport.makeTimeline(source: clip, style: style, cursor: cursor,
                                                     cursorStyle: cursorStyle,
                                                     captions: captions, captionSettings: captionSettings)
        let gen = AVAssetImageGenerator(asset: tl.asset)
        gen.videoComposition = tl.video
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let img = try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private func differingPixels(_ a: [UInt8], _ b: [UInt8], threshold: Int = 12) -> Int {
        guard a.count == b.count else { return .max }
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) where abs(Int(a[i]) - Int(b[i])) > threshold { n += 1 }
        return n
    }

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reclip-motion-\(name)-\(UUID().uuidString).mp4")
    }

    func testEnablingTheCursorChangesTheRenderedFrame() async throws {
        let clip = tmp("cursor")
        try await makeClip(clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let track = cursorTrack()

        var on = CursorStyle(); on.enabled = true; on.kind = .arrow; on.size = 2
        var off = on; off.enabled = false

        let a = try await render(clip, at: 1.5, cursor: track, cursorStyle: on)
        let b = try await render(clip, at: 1.5, cursor: track, cursorStyle: off)
        XCTAssertGreaterThan(differingPixels(a, b), 100,
                             "the drawn cursor must reach the composed frame")
    }

    func testSmoothingMovesWhereTheCursorIsDrawn() async throws {
        let clip = tmp("smooth")
        try await makeClip(clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let track = cursorTrack()

        var tight = CursorStyle(); tight.enabled = true; tight.size = 2; tight.smoothing = 0
        var floaty = tight; floaty.smoothing = 2.0

        // Different smoothing lags the pointer differently, so the sprite lands elsewhere.
        let a = try await render(clip, at: 1.5, cursor: track, cursorStyle: tight)
        let b = try await render(clip, at: 1.5, cursor: track, cursorStyle: floaty)
        XCTAssertGreaterThan(differingPixels(a, b), 50,
                             "smoothing should change where the cursor is drawn")
    }

    func testClickEffectReachesTheFrame() async throws {
        let clip = tmp("click")
        try await makeClip(clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let track = cursorTrack()

        var on = CursorStyle()
        on.enabled = true; on.size = 2
        on.showClicks = true; on.clickEffect = .ripple
        on.clickBounceDuration = 200; on.clickEffectDurationMs = 600
        var off = on; off.clickEffect = .none

        // Shortly after the click at t=1.0, inside the ripple window.
        let a = try await render(clip, at: 1.3, cursor: track, cursorStyle: on)
        let b = try await render(clip, at: 1.3, cursor: track, cursorStyle: off)
        XCTAssertGreaterThan(differingPixels(a, b), 50, "the click graphic must reach the frame")
    }

    func testCaptionAnimationChangesTheFrameMidTransition() async throws {
        let clip = tmp("caption")
        try await makeClip(clip)
        defer { try? FileManager.default.removeItem(at: clip) }

        let cues = [CaptionCue(text: "Hello there", start: 1.0, end: 2.5)]
        var popped = CaptionSettings()
        popped.enabled = true; popped.animation = .pop; popped.animationDuration = 0.4
        var plain = popped; plain.animation = .off

        // Part-way into the entrance the two must differ (one is small and faded)…
        let midA = try await render(clip, at: 1.1, captions: cues, captionSettings: popped)
        let midB = try await render(clip, at: 1.1, captions: cues, captionSettings: plain)
        XCTAssertGreaterThan(differingPixels(midA, midB), 50,
                             "an animating caption should differ from a static one mid-transition")

        // …and converge once the animation has settled.
        let restA = try await render(clip, at: 1.8, captions: cues, captionSettings: popped)
        let restB = try await render(clip, at: 1.8, captions: cues, captionSettings: plain)
        XCTAssertLessThan(differingPixels(restA, restB), 50,
                          "a settled caption should match the un-animated one")
    }
}

/// The shortcut store is the adapter between the pure `Shortcuts` model and UserDefaults.
final class ShortcutStoreTests: XCTestCase {
    override func setUp() { super.setUp(); ShortcutStore.reset() }
    override func tearDown() { ShortcutStore.reset(); super.tearDown() }

    func testLoadsDefaultsWhenNothingSaved() {
        let loaded = ShortcutStore.load()
        XCTAssertEqual(loaded.count, ShortcutAction.allCases.count)
        XCTAssertTrue(Shortcuts.bindingsEqual(loaded[.addZoom]!, Shortcuts.defaults[.addZoom]!))
    }

    func testRoundTripsACustomBinding() {
        var config = Shortcuts.defaults
        config[.addZoom] = ShortcutBinding(key: "q", ctrl: true, shift: true, alt: false)
        ShortcutStore.save(config)

        let loaded = ShortcutStore.load()
        let z = loaded[.addZoom]!
        XCTAssertEqual(z.key, "q")
        XCTAssertTrue(z.ctrl)
        XCTAssertTrue(z.shift)
        XCTAssertFalse(z.alt)
        // Untouched actions keep their defaults.
        XCTAssertTrue(Shortcuts.bindingsEqual(loaded[.splitClip]!, Shortcuts.defaults[.splitClip]!))
    }

    func testPartialSaveIsBackfilledWithDefaults() {
        ShortcutStore.save([.addZoom: ShortcutBinding(key: "q")])
        let loaded = ShortcutStore.load()
        XCTAssertEqual(loaded.count, ShortcutAction.allCases.count,
                       "every action should be bound after loading a partial save")
        XCTAssertEqual(loaded[.addZoom]?.key, "q")
    }

    func testRebindingRejectsAFixedCombination() {
        // Tab is reserved for annotation cycling, so the config sheet must refuse it.
        let proposed = ShortcutBinding(key: "tab")
        let clash = Shortcuts.findConflict(proposed, forAction: .addZoom, config: Shortcuts.defaults)
        guard case .fixed = clash else {
            return XCTFail("expected a fixed-shortcut conflict, got \(String(describing: clash))")
        }
    }

    func testRebindingRejectsAnotherActionsCombination() {
        let splitKey = Shortcuts.defaults[.splitClip]!
        let clash = Shortcuts.findConflict(splitKey, forAction: .addZoom, config: Shortcuts.defaults)
        XCTAssertEqual(clash, .configurable(.splitClip))
    }

    func testAFreeCombinationHasNoConflict() {
        XCTAssertNil(Shortcuts.findConflict(ShortcutBinding(key: "q", ctrl: true),
                                            forAction: .addZoom, config: Shortcuts.defaults))
    }
}
