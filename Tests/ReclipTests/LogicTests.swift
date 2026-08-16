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

    func testConnectNeighborsMergesCloseRegions() {
        var tl = ZoomTimeline(regions: [
            ZoomRegion(start: 0, end: 2, scale: 2.0, focus: CGPoint(x: 0.5, y: 0.5)),
            ZoomRegion(start: 2.3, end: 4, scale: 2.5, focus: CGPoint(x: 0.2, y: 0.8)),  // gap 0.3 → merge
            ZoomRegion(start: 6, end: 8, scale: 2.0, focus: CGPoint(x: 0.5, y: 0.5)),     // gap 2 → separate
        ])
        tl.connectNeighbors(maxGap: 0.5)
        XCTAssertEqual(tl.regions.count, 2)
        XCTAssertEqual(tl.regions[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(tl.regions[0].end, 4, accuracy: 1e-9)
        XCTAssertEqual(Double(tl.regions[0].scale), 2.5, accuracy: 1e-9)   // deeper scale kept
        XCTAssertEqual(tl.regions[0].focus.x, 0.2, accuracy: 1e-9)         // …and its focus
        // Far region untouched.
        XCTAssertEqual(tl.regions[1].start, 6, accuracy: 1e-9)
    }

    func testConnectNeighborsNoopWhenFarApart() {
        var tl = ZoomTimeline(regions: [
            ZoomRegion(start: 0, end: 1, scale: 2, focus: CGPoint(x: 0.5, y: 0.5)),
            ZoomRegion(start: 5, end: 6, scale: 2, focus: CGPoint(x: 0.5, y: 0.5)),
        ])
        tl.connectNeighbors(maxGap: 0.5)
        XCTAssertEqual(tl.regions.count, 2)
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

final class AnnotationFadeTests: XCTestCase {
    func testFadeEnvelope() {
        // start=1, end=5, fade=1s
        XCTAssertEqual(Annotations.fadeFactor(time: 1.0, start: 1, end: 5, fade: 1), 0, accuracy: 1e-9)  // at start
        XCTAssertEqual(Annotations.fadeFactor(time: 1.5, start: 1, end: 5, fade: 1), 0.5, accuracy: 1e-9) // mid fade-in
        XCTAssertEqual(Annotations.fadeFactor(time: 3.0, start: 1, end: 5, fade: 1), 1, accuracy: 1e-9)  // fully in
        XCTAssertEqual(Annotations.fadeFactor(time: 4.5, start: 1, end: 5, fade: 1), 0.5, accuracy: 1e-9) // mid fade-out
        XCTAssertEqual(Annotations.fadeFactor(time: 5.0, start: 1, end: 5, fade: 1), 0, accuracy: 1e-9)  // at end
        // fade=0 → always fully opaque
        XCTAssertEqual(Annotations.fadeFactor(time: 3, start: 1, end: 5, fade: 0), 1, accuracy: 1e-9)
    }
}

final class CutMapTests: XCTestCase {
    func testCutMapConcatenatesKeptRanges() {
        // Keep [0,2] and [5,8] of a 10s source (cut out [2,5] and [8,10]).
        let m = CutMap(keptRanges: [(0, 2), (5, 8)])
        XCTAssertEqual(m.outputDuration, 5, accuracy: 1e-9)          // 2 + 3
        XCTAssertEqual(m.sourceTime(forOutput: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(forOutput: 1.5), 1.5, accuracy: 1e-9)  // still in first kept range
        XCTAssertEqual(m.sourceTime(forOutput: 2.5), 5.5, accuracy: 1e-9)  // 0.5 into the second kept range → 5 + 0.5
        XCTAssertEqual(m.sourceTime(forOutput: 3.5), 6.5, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(forOutput: 5.0), 8.0, accuracy: 1e-9)
    }
}

final class SpeedMapTests: XCTestCase {
    func testPiecewiseMappingAndDuration() {
        // 10s source, [0,4] played at 2×, rest 1×.
        let m = SpeedMap(regions: [SpeedSegment(start: 0, end: 4, speed: 2)], sourceDuration: 10)
        XCTAssertEqual(m.outputDuration, 8, accuracy: 1e-9)          // 4/2 + 6/1
        XCTAssertEqual(m.sourceTime(forOutput: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(forOutput: 2), 4, accuracy: 1e-9) // end of the fast part
        XCTAssertEqual(m.sourceTime(forOutput: 3), 5, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(forOutput: 8), 10, accuracy: 1e-9)
        XCTAssertFalse(m.isIdentity)
    }

    func testGapsFilledAtNormalSpeed() {
        // A slow region in the middle; ends run at 1×.
        let m = SpeedMap(regions: [SpeedSegment(start: 4, end: 6, speed: 0.5)], sourceDuration: 10)
        // segments: [0,4]@1, [4,6]@0.5, [6,10]@1  → output 4 + 4 + 4 = 12
        XCTAssertEqual(m.segments.count, 3)
        XCTAssertEqual(m.outputDuration, 12, accuracy: 1e-9)
        // output 5 → still in first 1× segment → source 5; output 4 → source 4 (start of slow)
        XCTAssertEqual(m.sourceTime(forOutput: 4), 4, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(forOutput: 6), 5, accuracy: 1e-9) // 2s into 0.5× = 1s source
    }

    func testIdentityWhenNoRegions() {
        let m = SpeedMap(regions: [], sourceDuration: 5)
        XCTAssertTrue(m.isIdentity)
        XCTAssertEqual(m.outputDuration, 5, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(forOutput: 2.5), 2.5, accuracy: 1e-9)
    }

    func testMonotonicMapping() {
        let m = SpeedMap(regions: [SpeedSegment(start: 1, end: 3, speed: 3),
                                   SpeedSegment(start: 5, end: 7, speed: 0.5)], sourceDuration: 8)
        var prev = -1.0
        var t = 0.0
        while t <= m.outputDuration {
            let s = m.sourceTime(forOutput: t)
            XCTAssertGreaterThanOrEqual(s + 1e-9, prev, "source time must be non-decreasing")
            prev = s; t += 0.1
        }
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

final class PermissionStatusTests: XCTestCase {
    func testStatusMappingIsTotal() {
        // Every AVAuthorizationStatus maps to a CapturePermission (no crash / default).
        XCTAssertEqual(CapturePermission.fromAVStatus(.authorized), .authorized)
        XCTAssertEqual(CapturePermission.fromAVStatus(.denied), .denied)
        XCTAssertEqual(CapturePermission.fromAVStatus(.restricted), .restricted)
        XCTAssertEqual(CapturePermission.fromAVStatus(.notDetermined), .notDetermined)
    }

    func testPreflightReturnsWithoutPrompting() {
        // These must return a defined status synchronously (no prompt, no crash).
        let all: [CapturePermission] = [PermissionStatus.screenRecording(),
                                        PermissionStatus.camera(),
                                        PermissionStatus.microphone()]
        for p in all {
            XCTAssertTrue([.authorized, .denied, .notDetermined, .restricted].contains(p))
        }
    }
}

final class AudioLevelMeterTests: XCTestCase {
    func testRMS() {
        XCTAssertEqual(AudioLevelMeter.rms([]), 0, accuracy: 1e-9)
        XCTAssertEqual(AudioLevelMeter.rms([0, 0, 0]), 0, accuracy: 1e-9)
        XCTAssertEqual(AudioLevelMeter.rms([1, -1, 1, -1]), 1, accuracy: 1e-9)     // full-scale square
        XCTAssertEqual(AudioLevelMeter.rms([0.5, 0.5, 0.5]), 0.5, accuracy: 1e-9)
    }

    func testNormalizeWithGainAndClamp() {
        XCTAssertEqual(AudioLevelMeter.normalize(rms: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(AudioLevelMeter.normalize(rms: 0.25), 50, accuracy: 1e-9)   // 0.25·200
        XCTAssertEqual(AudioLevelMeter.normalize(rms: 0.5), 100, accuracy: 1e-9)   // 2× gain saturates
        XCTAssertEqual(AudioLevelMeter.normalize(rms: 1.0), 100, accuracy: 1e-9)   // clamped
    }

    func testSmoothingConvergesAndSilenceDecays() {
        var m = AudioLevelMeter(smoothingFactor: 0.8)
        // Silence stays ~0.
        for _ in 0..<10 { m.update(samples: [0, 0, 0, 0]) }
        XCTAssertEqual(m.level, 0, accuracy: 1e-9)
        // Full-scale input converges up toward 100 (smoothed, not instant).
        var loud = m
        let first = loud.update(samples: [1, -1, 1, -1])   // 0·0.8 + 100·0.2 = 20
        XCTAssertEqual(first, 20, accuracy: 1e-9)
        for _ in 0..<60 { loud.update(samples: [1, -1, 1, -1]) }
        XCTAssertEqual(loud.level, 100, accuracy: 0.5)
        // Then silence decays back down.
        for _ in 0..<60 { loud.update(samples: [0, 0, 0, 0]) }
        XCTAssertEqual(loud.level, 0, accuracy: 0.5)
        loud.reset()
        XCTAssertEqual(loud.level, 0, accuracy: 1e-12)
    }
}

final class DeviceEnumeratorTests: XCTestCase {
    func testEnumerationReturnsWellFormedLists() {
        // Enumeration must never crash and every entry must be addressable (non-empty
        // id + name). The list may be empty on a headless CI box — that's valid.
        for device in DeviceEnumerator.microphones() + DeviceEnumerator.cameras() {
            XCTAssertFalse(device.id.isEmpty, "device id must be usable for selection")
            XCTAssertFalse(device.name.isEmpty)
        }
        // At most one default per media type.
        XCTAssertLessThanOrEqual(DeviceEnumerator.microphones().filter(\.isDefault).count, 1)
        XCTAssertLessThanOrEqual(DeviceEnumerator.cameras().filter(\.isDefault).count, 1)
    }

    func testResolveFallsBackToDefault() {
        // An unknown id resolves to the system default (or nil if none) — never crashes.
        _ = DeviceEnumerator.microphone(id: "nonexistent-device-id")
        _ = DeviceEnumerator.camera(id: nil)
    }
}

final class WebcamSyncTests: XCTestCase {
    func testTargetTimeShiftsByOffsetAndClamps() {
        // 500ms offset shifts the webcam back half a second.
        XCTAssertEqual(WebcamSync.targetTimeSeconds(currentTime: 5, webcamDuration: 10, timeOffsetMs: 500),
                       4.5, accuracy: 1e-9)
        // Clamped to the webcam duration.
        XCTAssertEqual(WebcamSync.targetTimeSeconds(currentTime: 5, webcamDuration: 4, timeOffsetMs: 0),
                       4, accuracy: 1e-9)
        // Nil duration → no clamp (negative offset can push past current time).
        XCTAssertEqual(WebcamSync.targetTimeSeconds(currentTime: 5, webcamDuration: nil, timeOffsetMs: -1000),
                       6, accuracy: 1e-9)
    }

    func testShouldSeek() {
        // Actively seeking → never trigger another seek.
        XCTAssertFalse(WebcamSync.shouldSeek(desiredTime: 5, isPlaying: true, isSeeking: true,
                                             previousTimelineTime: 1, timelineTime: 9, webcamCurrentTime: 1))
        // First frame (nil previous) counts as a jump → seek.
        XCTAssertTrue(WebcamSync.shouldSeek(desiredTime: 5, isPlaying: true, isSeeking: false,
                                            previousTimelineTime: nil, timelineTime: 5, webcamCurrentTime: 5))
        // In sync while playing (drift below 0.35) → no seek.
        XCTAssertFalse(WebcamSync.shouldSeek(desiredTime: 5, isPlaying: true, isSeeking: false,
                                             previousTimelineTime: 4.9, timelineTime: 5, webcamCurrentTime: 4.8))
        // Large drift while playing → seek.
        XCTAssertTrue(WebcamSync.shouldSeek(desiredTime: 5, isPlaying: true, isSeeking: false,
                                            previousTimelineTime: 4.9, timelineTime: 5, webcamCurrentTime: 3))
        // Paused uses a tight 0.01 threshold.
        XCTAssertTrue(WebcamSync.shouldSeek(desiredTime: 5, isPlaying: false, isSeeking: false,
                                            previousTimelineTime: 5, timelineTime: 5, webcamCurrentTime: 5.02))
    }
}

final class FocusUtilsTests: XCTestCase {
    func testClampIsNoOpForCentre() {
        let f = FocusUtils.clampFocusToScale(CGPoint(x: 0.5, y: 0.5), scale: 2)
        XCTAssertEqual(f.x, 0.5, accuracy: 1e-9); XCTAssertEqual(f.y, 0.5, accuracy: 1e-9)
        // Focus already inside bounds is unchanged.
        let g = FocusUtils.clampFocusToScale(CGPoint(x: 0.4, y: 0.6), scale: 2.2)
        XCTAssertEqual(g.x, 0.4, accuracy: 1e-9); XCTAssertEqual(g.y, 0.6, accuracy: 1e-9)
    }

    func testEdgeFocusPulledIn() {
        // scale 2 → margin 0.25 → bounds [0.25, 0.75].
        let f = FocusUtils.clampFocusToScale(CGPoint(x: 0.0, y: 1.0), scale: 2)
        XCTAssertEqual(f.x, 0.25, accuracy: 1e-9); XCTAssertEqual(f.y, 0.75, accuracy: 1e-9)
        // scale 4 → margin 0.125 → bounds [0.125, 0.875].
        let g = FocusUtils.clampFocusToScale(CGPoint(x: 0.9, y: 0.1), scale: 4)
        XCTAssertEqual(g.x, 0.875, accuracy: 1e-9); XCTAssertEqual(g.y, 0.125, accuracy: 1e-9)
    }

    func testHigherScaleTightensBounds() {
        let b2 = FocusUtils.focusBounds(scale: 2)
        let b4 = FocusUtils.focusBounds(scale: 4)
        XCTAssertGreaterThan(b2.minX, 0); XCTAssertLessThan(b4.minX, b2.minX,
            "higher zoom → tighter focus bounds (viewport shrinks)")
    }
}

final class ShortcutsTests: XCTestCase {
    func testMatchesRespectsModifiers() {
        // addZoom = "z" with no primary modifier.
        XCTAssertTrue(Shortcuts.matches(KeyChord(key: "z"), Shortcuts.defaults[.addZoom]!))
        XCTAssertTrue(Shortcuts.matches(KeyChord(key: "Z"), Shortcuts.defaults[.addZoom]!), "case-insensitive")
        // deleteSelected = Cmd+d — requires the primary modifier.
        XCTAssertTrue(Shortcuts.matches(KeyChord(key: "d", primaryModifier: true), Shortcuts.defaults[.deleteSelected]!))
        XCTAssertFalse(Shortcuts.matches(KeyChord(key: "d"), Shortcuts.defaults[.deleteSelected]!), "no modifier → no match")
    }

    func testFindConflictConfigurableAndFixed() {
        // Rebinding splitClip to "z" collides with addZoom (configurable).
        XCTAssertEqual(Shortcuts.findConflict(ShortcutBinding(key: "z"), forAction: .splitClip, config: Shortcuts.defaults),
                       .configurable(.addZoom))
        // Rebinding addZoom to Tab collides with a fixed shortcut.
        XCTAssertEqual(Shortcuts.findConflict(ShortcutBinding(key: "tab"), forAction: .addZoom, config: Shortcuts.defaults),
                       .fixed("Cycle Annotations Forward"))
        // A free key has no conflict; a binding equal to its own action isn't a self-conflict.
        XCTAssertNil(Shortcuts.findConflict(ShortcutBinding(key: "q"), forAction: .addZoom, config: Shortcuts.defaults))
        XCTAssertNil(Shortcuts.findConflict(ShortcutBinding(key: "z"), forAction: .addZoom, config: Shortcuts.defaults))
    }

    func testFormatBinding() {
        XCTAssertEqual(Shortcuts.formatBinding(ShortcutBinding(key: "d", ctrl: true), isMac: true), "⌘ + D")
        XCTAssertEqual(Shortcuts.formatBinding(ShortcutBinding(key: "d", ctrl: true), isMac: false), "Ctrl + D")
        XCTAssertEqual(Shortcuts.formatBinding(ShortcutBinding(key: " "), isMac: true), "Space")
        XCTAssertEqual(Shortcuts.formatBinding(ShortcutBinding(key: "a", shift: true, alt: true), isMac: true), "⇧ + ⌥ + A")
    }

    func testMergeWithDefaults() {
        let merged = Shortcuts.mergeWithDefaults([.addZoom: ShortcutBinding(key: "x")])
        XCTAssertEqual(merged[.addZoom], ShortcutBinding(key: "x"))     // overridden
        XCTAssertEqual(merged[.splitClip], ShortcutBinding(key: "c"))   // default kept
        XCTAssertEqual(merged.count, ShortcutAction.allCases.count)
    }
}

final class ExtensionManifestTests: XCTestCase {
    private func manifest(id: String = "com.example.sparkles", main: String = "index.js",
                          version: String = "1.2.0",
                          permissions: [ExtensionPermission] = [.render, .cursor]) -> ExtensionManifest {
        ExtensionManifest(id: id, name: "Sparkles", version: version, description: "click sparkles",
                          author: nil, homepage: nil, license: "MIT", engine: nil, icon: nil,
                          main: main, permissions: permissions)
    }

    func testValidManifestValidates() throws {
        XCTAssertNoThrow(try manifest().validate())
    }

    func testMissingFieldsRejected() {
        XCTAssertThrowsError(try manifest(main: "").validate()) {
            XCTAssertEqual($0 as? ExtensionManifest.ValidationError, .missingField("main"))
        }
        XCTAssertThrowsError(try manifest(id: "  ").validate()) {
            XCTAssertEqual($0 as? ExtensionManifest.ValidationError, .missingField("id"))
        }
        XCTAssertThrowsError(try manifest(version: "v2").validate()) {
            XCTAssertEqual($0 as? ExtensionManifest.ValidationError, .invalidVersion("v2"))
        }
    }

    func testJSONRoundTrip() throws {
        let m = manifest()
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.permissions, [.render, .cursor])
    }

    func testPermissionGating() throws {
        var reg = ExtensionRegistry()
        let m = manifest(permissions: [.render])
        try reg.install(m)
        XCTAssertEqual(reg.installed.count, 1)
        XCTAssertNoThrow(try reg.requirePermission(.render, of: m, for: "registerRenderHook"))
        XCTAssertThrowsError(try reg.requirePermission(.cursor, of: m, for: "registerCursorEffect")) {
            XCTAssertEqual($0 as? ExtensionRegistryError, .permissionDenied(.cursor, action: "registerCursorEffect"))
        }
    }

    func testInstallReplacesSameId() throws {
        var reg = ExtensionRegistry()
        try reg.install(manifest(version: "1.0.0"))
        try reg.install(manifest(version: "2.0.0"))
        XCTAssertEqual(reg.installed.count, 1, "same id replaces, not duplicates")
        XCTAssertEqual(reg.manifest(id: "com.example.sparkles")?.version, "2.0.0")
    }

    func testAllPermissionsCovered() {
        XCTAssertEqual(Set(ExtensionPermission.allCases.map(\.rawValue)),
                       ["render", "cursor", "audio", "timeline", "ui", "assets", "export"])
    }
}

final class TimelineModelTests: XCTestCase {
    func testSpansOverlap() {
        XCTAssertTrue(TimelineModel.spansOverlap(.init(start: 0, end: 5), .init(start: 3, end: 8)))
        XCTAssertFalse(TimelineModel.spansOverlap(.init(start: 0, end: 5), .init(start: 5, end: 8)), "touching edges don't overlap")
        XCTAssertFalse(TimelineModel.spansOverlap(.init(start: 6, end: 9), .init(start: 0, end: 5)))
    }

    func testNormalizeRegionSpan() {
        // Normal case within bounds.
        XCTAssertEqual(TimelineModel.normalizeRegionSpan(startMs: 100, endMs: 400, totalMs: 1000, minDurationMs: 50),
                       .init(start: 100, end: 400))
        // Start past total is pulled back so min-duration still fits.
        XCTAssertEqual(TimelineModel.normalizeRegionSpan(startMs: 990, endMs: 995, totalMs: 1000, minDurationMs: 100),
                       .init(start: 900, end: 1000))
        // End below start+min is pushed to satisfy min duration.
        XCTAssertEqual(TimelineModel.normalizeRegionSpan(startMs: 200, endMs: 210, totalMs: 1000, minDurationMs: 100),
                       .init(start: 200, end: 300))
        // Negative start clamps to 0.
        XCTAssertEqual(TimelineModel.normalizeRegionSpan(startMs: -50, endMs: 300, totalMs: 1000, minDurationMs: 50).start, 0)
    }

    func testFormatPlayheadTime() {
        XCTAssertEqual(TimelineModel.formatPlayheadTime(ms: 5300), "5.3s")
        XCTAssertEqual(TimelineModel.formatPlayheadTime(ms: 65300), "1:05.3")
        XCTAssertEqual(TimelineModel.formatPlayheadTime(ms: 0), "0.0s")
    }

    func testFormatTimeLabel() {
        XCTAssertEqual(TimelineModel.formatTimeLabel(ms: 125_000, intervalMs: 1000), "2:05")       // no fraction
        XCTAssertEqual(TimelineModel.formatTimeLabel(ms: 125_250, intervalMs: 100), "2:05.25")     // 2 digits
        XCTAssertEqual(TimelineModel.formatTimeLabel(ms: 125_200, intervalMs: 500), "2:05.2")      // 1 digit
        XCTAssertEqual(TimelineModel.formatTimeLabel(ms: 3_725_000, intervalMs: 1000), "1:02:05")  // hours
    }

    func testTrackRowIds() {
        XCTAssertEqual(TimelineModel.annotationTrackRowId(2), "row-annotation-2")
        XCTAssertTrue(TimelineModel.isAnnotationTrackRowId("row-annotation-2"))
        XCTAssertTrue(TimelineModel.isAnnotationTrackRowId("row-annotation"))
        XCTAssertFalse(TimelineModel.isAnnotationTrackRowId("row-audio-1"))
        XCTAssertEqual(TimelineModel.annotationTrackIndex("row-annotation-3"), 3)
        XCTAssertEqual(TimelineModel.annotationTrackIndex("row-annotation"), 0)
        XCTAssertEqual(TimelineModel.audioTrackRowId(1), "row-audio-1")
        XCTAssertEqual(TimelineModel.audioTrackIndex("row-audio-4"), 4)
        XCTAssertTrue(TimelineModel.isAudioTrackRowId("row-audio"))
    }
}

final class ZoomTransformTests: XCTestCase {
    let stage = ZoomTransform.Size(width: 1000, height: 1000)
    let mask = ZoomTransform.Rect(x: 0, y: 0, width: 1000, height: 1000)

    func testCentersFocusAndScales() {
        let t = ZoomTransform.compute(stage: stage, baseMask: mask, zoomScale: 2,
                                      progress: 1, focusX: 0.5, focusY: 0.5)
        XCTAssertEqual(t.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(t.x, -500, accuracy: 1e-9)   // 500 − 500·2
        XCTAssertEqual(t.y, -500, accuracy: 1e-9)
    }

    func testProgressZeroIsIdentity() {
        let t = ZoomTransform.compute(stage: stage, baseMask: mask, zoomScale: 3,
                                      progress: 0, focusX: 0.2, focusY: 0.8)
        XCTAssertEqual(t, ZoomTransform(scale: 1, x: 0, y: 0))
    }

    func testDegenerateStageIsIdentity() {
        let t = ZoomTransform.compute(stage: .init(width: 0, height: 0), baseMask: mask,
                                      zoomScale: 2, focusX: 0.5, focusY: 0.5)
        XCTAssertEqual(t, ZoomTransform(scale: 1, x: 0, y: 0))
    }

    func testFocusRoundTrips() {
        for (fx, fy, z) in [(0.3, 0.7, 2.0), (0.1, 0.9, 3.5), (0.5, 0.5, 1.5)] {
            let t = ZoomTransform.compute(stage: stage, baseMask: mask, zoomScale: z,
                                          progress: 1, focusX: fx, focusY: fy)
            let f = ZoomTransform.focusFromTransform(stage: stage, baseMask: mask,
                                                     zoomScale: z, x: t.x, y: t.y)
            XCTAssertEqual(f.cx, fx, accuracy: 1e-9)
            XCTAssertEqual(f.cy, fy, accuracy: 1e-9)
        }
    }
}

final class CursorClickEffectTests: XCTestCase {
    func testBounceDurationClamped() {
        XCTAssertEqual(CursorClickEffect.clampBounceDuration(30), 60, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.clampBounceDuration(600), 500, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.clampBounceDuration(200), 200, accuracy: 1e-9)
    }

    func testBounceProgressDecays() {
        XCTAssertEqual(CursorClickEffect.bounceProgress(ageMs: 0, bounceDurationMs: 300), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.bounceProgress(ageMs: 150, bounceDurationMs: 300), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.bounceProgress(ageMs: 300, bounceDurationMs: 300), 0, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.bounceProgress(ageMs: 400, bounceDurationMs: 300), 0, accuracy: 1e-9)
    }

    func testBounceScaleDipsAndFloors() {
        // Progress 0 or 1 → no dip (scale 1); peak dip at progress 0.5.
        XCTAssertEqual(CursorClickEffect.bounceScale(progress: 0, clickBounce: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.bounceScale(progress: 1, clickBounce: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.bounceScale(progress: 0.5, clickBounce: 1), 0.92, accuracy: 1e-9)
        // A large clickBounce is floored at 0.72.
        XCTAssertEqual(CursorClickEffect.bounceScale(progress: 0.5, clickBounce: 100), 0.72, accuracy: 1e-9)
    }

    func testRippleDelayedThenFades() {
        // Delay = half the bounce duration (150ms here); ripple starts then.
        XCTAssertEqual(CursorClickEffect.rippleProgress(ageMs: 100, bounceDurationMs: 300, effectDurationMs: 400), 0, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.rippleProgress(ageMs: 150, bounceDurationMs: 300, effectDurationMs: 400), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.rippleProgress(ageMs: 350, bounceDurationMs: 300, effectDurationMs: 400), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CursorClickEffect.rippleProgress(ageMs: 550, bounceDurationMs: 300, effectDurationMs: 400), 0, accuracy: 1e-9)
    }
}

final class MotionSmoothingTests: XCTestCase {
    func testClampDeltaMs() {
        XCTAssertEqual(MotionSmoothing.clampDeltaMs(30), 30, accuracy: 1e-9)
        XCTAssertEqual(MotionSmoothing.clampDeltaMs(200), 80, accuracy: 1e-9)     // capped
        XCTAssertEqual(MotionSmoothing.clampDeltaMs(0.5), 1, accuracy: 1e-9)      // floored
        XCTAssertEqual(MotionSmoothing.clampDeltaMs(-5), 1000.0 / 60.0, accuracy: 1e-9) // fallback
    }

    func testSpringConvergesAndStaysBounded() {
        let cfg = MotionSmoothing.cursorSpringConfig(smoothing: 0.3)
        var s = SpringState()
        _ = MotionSmoothing.stepSpring(&s, target: 0, deltaMs: 16, config: cfg)   // init at 0
        var last = 0.0
        for _ in 0..<800 {
            last = MotionSmoothing.stepSpring(&s, target: 100, deltaMs: 16, config: cfg)
            XCTAssertTrue(last.isFinite, "spring must never diverge to NaN/Inf")
            XCTAssertGreaterThan(last, -50); XCTAssertLessThan(last, 200) // bounded, no runaway
        }
        XCTAssertEqual(last, 100, accuracy: 0.5, "spring settles at its target")
    }

    func testSpringFirstFrameSnaps() {
        var s = SpringState(initialValue: 42)
        let v = MotionSmoothing.stepSpring(&s, target: 7, deltaMs: 16,
                                           config: MotionSmoothing.cursorSpringConfig(smoothing: 1.0))
        XCTAssertEqual(v, 7, accuracy: 1e-9, "first step initializes to the target")
        XCTAssertTrue(s.initialized)
    }

    func testMoreSmoothingIsFloatier() {
        // Higher smoothing → lower stiffness (a slower, floatier settle).
        XCTAssertGreaterThan(MotionSmoothing.cursorSpringConfig(smoothing: 0.1).stiffness,
                             MotionSmoothing.cursorSpringConfig(smoothing: 1.5).stiffness)
        XCTAssertEqual(MotionSmoothing.cursorSpringConfig(smoothing: 0).stiffness, 1000, accuracy: 1e-9)
        XCTAssertEqual(MotionSmoothing.zoomSpringConfig(smoothness: 0).stiffness, 1000, accuracy: 1e-9)
    }

    func testCursorSway() {
        // No sway or negligible motion → no rotation.
        XCTAssertEqual(CursorSway.rotation(dx: 100, dy: 0, deltaMs: 16, sway: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(CursorSway.rotation(dx: 0.001, dy: 0, deltaMs: 16, sway: 1), 0, accuracy: 1e-12)
        // Fast rightward motion → positive rotation; leftward → mirrored negative.
        let right = CursorSway.rotation(dx: 200, dy: 0, deltaMs: 16, sway: 1)
        let left = CursorSway.rotation(dx: -200, dy: 0, deltaMs: 16, sway: 1)
        XCTAssertGreaterThan(right, 0)
        XCTAssertEqual(right, -left, accuracy: 1e-9)
        // Bounded by maxRotation·sway·intensityScale.
        let bound = CursorSway.maxRotation * 1 * CursorSway.intensityScale
        XCTAssertLessThanOrEqual(abs(right), bound + 1e-9)
        // Slider mapping round-trips.
        XCTAssertEqual(CursorSway.fromSliderValue(CursorSway.toSliderValue(1.4)), 1.4, accuracy: 1e-9)
    }
}

final class MediaTimingTests: XCTestCase {
    func testClampMediaTime() {
        XCTAssertEqual(MediaTiming.clampMediaTime(5, duration: 10), 5, accuracy: 1e-9)
        XCTAssertEqual(MediaTiming.clampMediaTime(15, duration: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(MediaTiming.clampMediaTime(-3, duration: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(MediaTiming.clampMediaTime(7, duration: nil), 7, accuracy: 1e-9, "nil duration → unchanged")
    }

    func testEffectiveStreamDuration() {
        // Small mismatch → trust the stream duration.
        XCTAssertEqual(MediaTiming.effectiveStreamDurationSeconds(duration: 10, streamDuration: 9.9), 9.9, accuracy: 1e-9)
        // Large mismatch (>max(2, 10%)) → fall back to the container duration.
        XCTAssertEqual(MediaTiming.effectiveStreamDurationSeconds(duration: 10, streamDuration: 5), 10, accuracy: 1e-9)
        // One side missing → use the other; both missing → 0.
        XCTAssertEqual(MediaTiming.effectiveStreamDurationSeconds(duration: nil, streamDuration: 8), 8, accuracy: 1e-9)
        XCTAssertEqual(MediaTiming.effectiveStreamDurationSeconds(duration: 12, streamDuration: nil), 12, accuracy: 1e-9)
        XCTAssertEqual(MediaTiming.effectiveStreamDurationSeconds(duration: nil, streamDuration: nil), 0, accuracy: 1e-9)
    }

    func testEffectiveRecordingDurationMatchesClock() {
        // Same scenario as RecordingClock: 5000ms wall, 700ms paused → 4300ms.
        XCTAssertEqual(MediaTiming.effectiveRecordingDurationMs(
            startTimeMs: 0, endTimeMs: 5000, accumulatedPausedDurationMs: 700), 4300, accuracy: 1e-9)
        // Active (in-progress) pause is also excluded.
        XCTAssertEqual(MediaTiming.effectiveRecordingDurationMs(
            startTimeMs: 0, endTimeMs: 5000, accumulatedPausedDurationMs: 0, pauseStartedAtMs: 3000),
            3000, accuracy: 1e-9)
        // Equivalence with RecordingClock on the same inputs.
        var clock = RecordingClock()
        clock.start(at: 0); clock.pause(at: 2000); clock.resume(at: 2700)
        XCTAssertEqual(clock.elapsedMs(at: 5000),
                       MediaTiming.effectiveRecordingDurationMs(startTimeMs: 0, endTimeMs: 5000,
                                                                accumulatedPausedDurationMs: 700),
                       accuracy: 1e-9)
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
