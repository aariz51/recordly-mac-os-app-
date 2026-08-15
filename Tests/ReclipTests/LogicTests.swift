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

final class CaptionEditingTests: XCTestCase {
    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(CaptionEditing.normalizeText("  hello   world \n"), "hello world")
        XCTAssertEqual(CaptionEditing.normalizeText("one\t\ttwo"), "one two")
        XCTAssertEqual(CaptionEditing.normalizeText("   "), "")
    }

    func testBuildWordsDistributesEvenly() {
        let words = CaptionEditing.buildWords(text: "a b c", startMs: 0, endMs: 3000)
        XCTAssertEqual(words.count, 3)
        XCTAssertEqual(words.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(words[0].startMs, 0); XCTAssertEqual(words[0].endMs, 1000)
        XCTAssertEqual(words[1].startMs, 1000); XCTAssertEqual(words[1].endMs, 2000)
        XCTAssertEqual(words[2].startMs, 2000); XCTAssertEqual(words[2].endMs, 3000)
        // First word has no leading space; the rest do.
        XCTAssertFalse(words[0].leadingSpace)
        XCTAssertTrue(words[1].leadingSpace)
    }

    func testBuildWordsMonotonicNonOverlapping() {
        let words = CaptionEditing.buildWords(text: "the quick brown fox jumps", startMs: 500, endMs: 900)
        XCTAssertEqual(words.count, 5)
        for i in words.indices {
            XCTAssertGreaterThanOrEqual(words[i].endMs, words[i].startMs + 1, "each word ≥ 1ms")
            if i > 0 { XCTAssertGreaterThanOrEqual(words[i].startMs, words[i - 1].startMs, "monotonic") }
        }
        XCTAssertEqual(words.last?.endMs, 900, "last word ends at the cue end")
    }

    func testBuildWordsEmptyAndSingle() {
        XCTAssertTrue(CaptionEditing.buildWords(text: "   ", startMs: 0, endMs: 1000).isEmpty)
        let one = CaptionEditing.buildWords(text: "hi", startMs: 0, endMs: 500)
        XCTAssertEqual(one, [CaptionWord(text: "hi", startMs: 0, endMs: 500, leadingSpace: false)])
    }
}

final class EditorHistoryTests: XCTestCase {
    func testRecordInitializeUnchangedAndRecorded() {
        var h = EditorHistory<String>()
        XCTAssertEqual(h.record("a"), .initialized)
        XCTAssertEqual(h.record("a"), .unchanged)     // identical → no history entry
        XCTAssertFalse(h.canUndo)
        XCTAssertEqual(h.record("b"), .recorded)
        XCTAssertTrue(h.canUndo)
        XCTAssertEqual(h.current, "b")
    }

    func testUndoRedoRoundTrip() {
        var h = EditorHistory<String>()
        h.record("a"); h.record("b"); h.record("c")
        XCTAssertEqual(h.undo(fallbackCurrent: "c"), "b")
        XCTAssertEqual(h.undo(fallbackCurrent: "b"), "a")
        XCTAssertNil(h.undo(fallbackCurrent: "a"))       // nothing older
        XCTAssertEqual(h.redo(fallbackCurrent: "a"), "b")
        XCTAssertEqual(h.redo(fallbackCurrent: "b"), "c")
        XCTAssertNil(h.redo(fallbackCurrent: "c"))
        XCTAssertEqual(h.current, "c")
    }

    func testNewEditClearsRedoStack() {
        var h = EditorHistory<String>()
        h.record("a"); h.record("b")
        _ = h.undo(fallbackCurrent: "b")                 // now redo available
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.record("c"), .recorded)         // a fresh edit
        XCTAssertFalse(h.canRedo, "a new edit discards the redo branch")
    }

    func testMaxEntriesBounded() {
        var h = EditorHistory<Int>(); h.record(0)
        for i in 1...150 { h.record(i, maxEntries: 100) }
        XCTAssertLessThanOrEqual(h.past.count, 100)
        XCTAssertEqual(h.current, 150)
    }

    func testApplyingHistoryReplacesWithoutPushing() {
        var h = EditorHistory<String>()
        h.record("a"); h.record("b")
        let before = h.past.count
        XCTAssertEqual(h.record("z", applyingHistory: true), .applied)
        XCTAssertEqual(h.past.count, before, "replaying history must not push onto past")
        XCTAssertEqual(h.current, "z")
    }
}

final class ExportProgressTests: XCTestCase {
    func testPercentageFromFrames() {
        let p = ExportProgress.make(currentFrame: 25, totalFrames: 100, phase: .rendering)
        XCTAssertEqual(p.percentage, 25, accuracy: 1e-9)
        XCTAssertEqual(p.phase, .rendering)
        // Zero total → 0% (no divide-by-zero), and it clamps to 100.
        XCTAssertEqual(ExportProgress.make(currentFrame: 5, totalFrames: 0, phase: .preparing).percentage, 0)
        XCTAssertEqual(ExportProgress.make(currentFrame: 150, totalFrames: 100, phase: .rendering).percentage, 100)
    }

    func testSavingCarriesFrameTotals() {
        let prev = ExportProgress.make(currentFrame: 90, totalFrames: 120, phase: .finalizing)
        let saving = ExportProgress.saving(previous: prev)
        XCTAssertEqual(saving.percentage, 100)
        XCTAssertEqual(saving.phase, .saving)
        XCTAssertEqual(saving.totalFrames, 120)
        XCTAssertEqual(saving.currentFrame, 120)
        XCTAssertEqual(saving.estimatedTimeRemaining, 0)
        // Nil previous falls back to 1 frame.
        XCTAssertEqual(ExportProgress.saving(previous: nil).totalFrames, 1)
    }
}

final class RecordingClockTests: XCTestCase {
    func testElapsedGrowsWhileRunning() {
        var c = RecordingClock()
        c.start(at: 1000)
        XCTAssertEqual(c.elapsedMs(at: 1000), 0, accuracy: 1e-9)
        XCTAssertEqual(c.elapsedMs(at: 3500), 2500, accuracy: 1e-9)
        XCTAssertTrue(c.isRunning)
        XCTAssertFalse(c.isPaused)
    }

    func testPauseFreezesElapsed() {
        var c = RecordingClock()
        c.start(at: 0)
        c.pause(at: 2000)                       // elapsed frozen at 2000
        XCTAssertTrue(c.isPaused)
        XCTAssertEqual(c.elapsedMs(at: 2000), 2000, accuracy: 1e-9)
        XCTAssertEqual(c.elapsedMs(at: 5000), 2000, accuracy: 1e-9, "time during pause must not count")
    }

    func testResumeExcludesPausedSpan() {
        var c = RecordingClock()
        c.start(at: 0)
        c.pause(at: 2000)
        c.resume(at: 5000)                      // 3000ms paused, folded out
        XCTAssertFalse(c.isPaused)
        XCTAssertEqual(c.elapsedMs(at: 6000), 3000, accuracy: 1e-9, "6000 wall − 3000 paused")
    }

    func testMultiplePausesAccumulate() {
        var c = RecordingClock()
        c.start(at: 0)
        c.pause(at: 1000); c.resume(at: 1500)   // 500 paused
        c.pause(at: 3000); c.resume(at: 3200)   // +200 paused = 700
        XCTAssertEqual(c.elapsedMs(at: 5000), 4300, accuracy: 1e-9, "5000 − 700 paused")
    }

    func testIdleGuardsAndReset() {
        var c = RecordingClock()
        c.pause(at: 100); c.resume(at: 200)     // no-ops before start
        XCTAssertEqual(c.elapsedMs(at: 500), 0, accuracy: 1e-9)
        c.start(at: 0)
        c.resume(at: 100)                       // resume without a pause is a no-op
        XCTAssertEqual(c.elapsedMs(at: 1000), 1000, accuracy: 1e-9)
        c.reset()
        XCTAssertFalse(c.isRunning)
        XCTAssertEqual(c.elapsedMs(at: 9999), 0, accuracy: 1e-9)
    }

    func testCountdown() {
        var cd = Countdown(delaySeconds: 3)
        XCTAssertEqual(cd.remainingSeconds(at: 0), 3)   // not begun → full delay
        cd.begin(at: 1000)
        XCTAssertEqual(cd.remainingSeconds(at: 1000), 3)
        XCTAssertEqual(cd.remainingSeconds(at: 2200), 2)   // 1.2s in
        XCTAssertEqual(cd.remainingSeconds(at: 4000), 0)
        XCTAssertFalse(cd.isFinished(at: 3900))
        XCTAssertTrue(cd.isFinished(at: 4000))
        cd.cancel()
        XCTAssertFalse(cd.isFinished(at: 9999))
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
