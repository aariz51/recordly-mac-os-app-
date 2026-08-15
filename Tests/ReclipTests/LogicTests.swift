import XCTest
import CoreGraphics
@testable import Reclip

final class ZoomTimelineTests: XCTestCase {

    func testNoZoomOutsideRegions() {
        let tl = ZoomTimeline(regions: [
            ZoomRegion(start: 2, end: 4, scale: 2, focus: CGPoint(x: 0.5, y: 0.5))
        ])
        XCTAssertEqual(tl.value(at: 0).scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(tl.value(at: 6).scale, 1.0, accuracy: 0.001)
    }

    func testEasingCurvesAreDistinctAndBounded() {
        let x = 0.25
        let lin = ZoomEasing.linear.apply(x)
        let smo = ZoomEasing.smooth.apply(x)
        let gli = ZoomEasing.glide.apply(x)
        let sna = ZoomEasing.snappy.apply(x)
        XCTAssertEqual(lin, 0.25, accuracy: 0.001)
        XCTAssertLessThan(smo, lin, "smooth eases in below linear in the first half")
        XCTAssertLessThan(gli, smo, "glide is gentler than smooth")
        XCTAssertGreaterThan(sna, lin, "snappy (ease-out) is ahead of linear")
        // Every curve is pinned at the endpoints.
        for e in ZoomEasing.allCases {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-9)
        }
    }

    func testManualRegionWithDepth() {
        var tl = ZoomTimeline()
        tl.addRegion(start: 1, end: 5, depth: .medium, focus: CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(tl.regions.count, 1)
        let v = tl.value(at: 3)   // mid-region, past the ramp
        XCTAssertEqual(v.scale, ZoomDepth.medium.scale, accuracy: 0.02)
        XCTAssertEqual(v.focus.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(v.focus.y, 0.7, accuracy: 0.001)
    }

    func testFullZoomMidRegion() {
        let tl = ZoomTimeline(regions: [
            ZoomRegion(start: 0, end: 10, scale: 2, focus: CGPoint(x: 0.3, y: 0.4))
        ], ramp: 0.5)
        let v = tl.value(at: 5)
        XCTAssertEqual(v.scale, 2.0, accuracy: 0.01)
        XCTAssertEqual(v.focus.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(v.focus.y, 0.4, accuracy: 0.001)
    }

    func testRampEasesInFromNoZoom() {
        let tl = ZoomTimeline(regions: [
            ZoomRegion(start: 0, end: 10, scale: 3, focus: CGPoint(x: 0.5, y: 0.5))
        ], ramp: 1.0)
        // At the very start the eased envelope is ~0, so scale ~1.
        XCTAssertEqual(tl.value(at: 0).scale, 1.0, accuracy: 0.05)
        // Fully ramped in by t = ramp.
        XCTAssertEqual(tl.value(at: 1.0).scale, 3.0, accuracy: 0.05)
    }

    func testAutoZoomGeneratesRegionOnDwell() {
        var track = CursorTrack()
        for i in 0..<90 {   // 3s of dwell at (0.5, 0.5) at 30Hz
            track.samples.append(CursorSample(t: Double(i) / 30.0, x: 0.5, y: 0.5))
        }
        let tl = ZoomTimeline.autoZoom(from: track, duration: 3.0, segment: 3.0)
        XCTAssertFalse(tl.regions.isEmpty)
        if let r = tl.regions.first {
            XCTAssertEqual(r.focus.x, 0.5, accuracy: 0.05)
            XCTAssertGreaterThan(r.scale, 1.0)
        }
    }

    func testAutoZoomSkipsHighMovement() {
        var track = CursorTrack()
        for i in 0..<90 {   // cursor sweeps across the whole screen (high spread)
            let x = Double(i) / 90.0
            track.samples.append(CursorSample(t: Double(i) / 30.0, x: x, y: 1 - x))
        }
        let tl = ZoomTimeline.autoZoom(from: track, duration: 3.0, segment: 3.0)
        XCTAssertTrue(tl.regions.isEmpty, "high-movement windows should not auto-zoom")
    }
}

final class CursorTrackTests: XCTestCase {

    func testNearestSample() {
        var t = CursorTrack()
        t.samples = [
            CursorSample(t: 0, x: 0, y: 0),
            CursorSample(t: 1, x: 0.5, y: 0.5),
            CursorSample(t: 2, x: 1, y: 1)
        ]
        XCTAssertEqual(t.position(at: 1.4)?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(t.position(at: 2.9)?.x ?? -1, 1.0, accuracy: 0.001)
    }

    func testEmptyTrackReturnsNil() {
        XCTAssertNil(CursorTrack().position(at: 1.0))
    }

    func testInterpolatedPosition() {
        var t = CursorTrack()
        t.samples = [CursorSample(t: 0, x: 0, y: 0), CursorSample(t: 2, x: 1, y: 0.5)]
        let mid = t.interpolated(at: 1.0)   // halfway → (0.5, 0.25)
        XCTAssertEqual(mid?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid?.y ?? -1, 0.25, accuracy: 1e-9)
        // clamps outside the range
        XCTAssertEqual(t.interpolated(at: -1)?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(t.interpolated(at: 9)?.x ?? -1, 1, accuracy: 1e-9)
        XCTAssertNil(CursorTrack().interpolated(at: 1))
    }
}

final class TimeMapTests: XCTestCase {

    /// The pipeline maps output time -> source time as `trimStart + out * speed`.
    func testOutputToSourceMapping() {
        let trimStart = 2.0
        let speed = 2.0
        func srcTime(_ out: Double) -> Double { trimStart + out * speed }
        XCTAssertEqual(srcTime(0), 2.0, accuracy: 0.0001)   // first output frame -> trim start
        XCTAssertEqual(srcTime(1), 4.0, accuracy: 0.0001)   // 2x speed advances source twice as fast
    }
}

final class CaptionExportTests: XCTestCase {
    func testSRTAndVTTFormat() {
        let cues = [CaptionCue(text: "Hello", start: 1.0, end: 3.5),
                    CaptionCue(text: "World", start: 4.0, end: 5.0)]
        let srt = CaptionExport.srt(cues)
        XCTAssertTrue(srt.contains("1\n00:00:01,000 --> 00:00:03,500\nHello"), srt)
        XCTAssertTrue(srt.contains("2\n00:00:04,000 --> 00:00:05,000\nWorld"))
        let vtt = CaptionExport.vtt(cues)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:03.500"))
    }

    func testTimecode() {
        XCTAssertEqual(CaptionExport.timecode(3661.25, sep: ","), "01:01:01,250")
        XCTAssertEqual(CaptionExport.timecode(0, sep: "."), "00:00:00.000")
    }
}

final class WhisperTranscriberTests: XCTestCase {
    func testSRTParseRoundTrip() {
        let cues = [CaptionCue(text: "Hello world", start: 1.0, end: 3.5),
                    CaptionCue(text: "Second line", start: 4.0, end: 5.25)]
        let parsed = WhisperTranscriber.parseSRT(CaptionExport.srt(cues))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first?.text, "Hello world")
        XCTAssertEqual(parsed.first?.start ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(parsed.first?.end ?? -1, 3.5, accuracy: 0.001)
        XCTAssertEqual(parsed.last?.text, "Second line")
        XCTAssertEqual(parsed.last?.end ?? -1, 5.25, accuracy: 0.001)
    }

    func testTimecodeParse() {
        XCTAssertEqual(WhisperTranscriber.timecode("01:02:03,500"), 3723.5, accuracy: 0.001)
        XCTAssertEqual(WhisperTranscriber.timecode("00:00:00.000"), 0, accuracy: 0.001)
    }

    func testWavHeader() {
        let pcm = Data(repeating: 7, count: 320)   // 160 int16 samples
        let wav = WhisperTranscriber.wavData(pcm: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        XCTAssertEqual(wav.count, 44 + 320)
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")
    }

    func testTranscribeThrowsWhenBinaryMissing() async {
        do {
            _ = try await WhisperTranscriber.transcribe(
                video: URL(fileURLWithPath: "/tmp/none.mp4"),
                binary: URL(fileURLWithPath: "/tmp/no-whisper-\(UUID().uuidString)"),
                model: URL(fileURLWithPath: "/tmp/no-model"))
            XCTFail("expected a thrown error for a missing binary")
        } catch { /* expected */ }
    }

    func testLanguageOptions() {
        XCTAssertEqual(WhisperLanguage.allCases.count, 10)          // Recordly's 10 languages
        XCTAssertEqual(WhisperLanguage.en.rawValue, "en")
        XCTAssertEqual(WhisperLanguage.auto.displayName, "Auto Detect")
        XCTAssertEqual(WhisperLanguage.ja.displayName, "Japanese")
        // rawValues are unique language codes usable directly as whisper -l args.
        XCTAssertEqual(Set(WhisperLanguage.allCases.map(\.rawValue)).count, 10)
    }

    func testModelMappings() {
        XCTAssertEqual(WhisperModel.allCases.count, 3)
        XCTAssertEqual(WhisperModel.small.fileName, "ggml-small.bin")
        XCTAssertTrue(WhisperModel.base.downloadURL.absoluteString.hasSuffix("ggml-base.bin"))
        XCTAssertTrue(WhisperModel.tiny.downloadURL.absoluteString.hasPrefix("https://"))
        XCTAssertTrue(WhisperModel.small.localURL.path.hasSuffix("Reclip/models/ggml-small.bin"))
    }
}

final class ExportDimensionsTests: XCTestCase {
    func testAspectFitsWithinSourceBox() {
        // Square export of a 1080p clip fits the short side (1080²), never upscales to 1920².
        let sq = ExportDimensions.canvas(sourceWidth: 1920, sourceHeight: 1080, ratio: 1.0)
        XCTAssertEqual(sq.width, 1080); XCTAssertEqual(sq.height, 1080)
        // 9:16 vertical → 1080×1920.
        let v = ExportDimensions.canvas(sourceWidth: 1920, sourceHeight: 1080, ratio: 9.0 / 16.0)
        XCTAssertEqual(v.width, 1080); XCTAssertEqual(v.height, 1920)
        // 16:9 from a square source → 1080×606 (even-floored).
        let w = ExportDimensions.canvas(sourceWidth: 1080, sourceHeight: 1080, ratio: 16.0 / 9.0)
        XCTAssertEqual(w.width, 1080); XCTAssertEqual(w.height, 606)
        // Native passthrough floors odd dimensions to even.
        let n = ExportDimensions.canvas(sourceWidth: 1921, sourceHeight: 1081, ratio: nil)
        XCTAssertEqual(n.width, 1920); XCTAssertEqual(n.height, 1080)
    }

    func testEvenFloorFloorAndMinimum() {
        XCTAssertEqual(ExportDimensions.evenFloor(607.5), 606)
        XCTAssertEqual(ExportDimensions.evenFloor(1), 2)     // never below 2
        XCTAssertEqual(ExportDimensions.evenFloor(0), 2)
    }
}

final class MotionBlurTests: XCTestCase {
    func testConfigOffBelowMinimum() {
        XCTAssertNil(MotionBlur.config(amount: 0))
        XCTAssertNil(MotionBlur.config(amount: nil))
        XCTAssertNil(MotionBlur.config(amount: 0.0005))
        XCTAssertNotNil(MotionBlur.config(amount: 0.5))
    }

    func testConfigResolvesLikeRecordly() {
        // amount = maxAmount → normalized 1 → weightCurvePower 1.2 + 0.9 = 2.1,
        // shutter = autoMax (0.62), sampleCount = 3 + 2*round(1*((5-3)/2)) = 5.
        let c = MotionBlur.config(amount: 2.0)!
        XCTAssertEqual(c.weightCurvePower, 2.1, accuracy: 1e-9)
        XCTAssertEqual(c.shutterFraction, 0.62, accuracy: 1e-9)
        XCTAssertEqual(c.sampleCount, 5)
        // Sample count overrides snap to the nearest odd value in range.
        XCTAssertEqual(MotionBlur.normalizeSampleCount(12), 13)
        XCTAssertEqual(MotionBlur.normalizeSampleCount(11), 11)
        XCTAssertEqual(MotionBlur.normalizeSampleCount(1000), 61)
        XCTAssertEqual(MotionBlur.normalizeSampleCount(-5), 3)
    }

    func testSamplePlanIsSymmetricAndNormalized() {
        let c = MotionBlur.config(amount: 1.0)!
        let plan = MotionBlur.samplePlanUs(frameDurationUs: 33_333, config: c)
        XCTAssertEqual(plan.count, c.sampleCount)
        // Weights sum to 1.
        XCTAssertEqual(plan.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-9)
        // Offsets are symmetric about zero and centred (middle sample at 0).
        XCTAssertEqual(plan.first!.offsetUs, -plan.last!.offsetUs, accuracy: 1e-6)
        XCTAssertEqual(plan[plan.count / 2].offsetUs, 0, accuracy: 1e-6)
        // Centre weight is the heaviest (cosine taper peaks at the middle).
        XCTAssertGreaterThan(plan[plan.count / 2].weight, plan.first!.weight)
        // Weight mirror symmetry.
        XCTAssertEqual(plan.first!.weight, plan.last!.weight, accuracy: 1e-9)
    }

    func testSingleSamplePlan() {
        let c = MotionBlur.Config(sampleCount: 1, shutterFraction: 0.5, weightCurvePower: 1.5)
        let plan = MotionBlur.samplePlanUs(frameDurationUs: 33_333, config: c)
        XCTAssertEqual(plan, [MotionBlur.Sample(offsetUs: 0, weight: 1)])
    }
}
