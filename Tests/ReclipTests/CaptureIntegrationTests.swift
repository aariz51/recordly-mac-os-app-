import XCTest
import AVFoundation
import ScreenCaptureKit
import ImageIO
import CoreGraphics
@testable import Reclip

/// End-to-end capture test driving the real `ScreenRecorder` against a live display.
/// Skipped automatically where screen-recording isn't authorized (CI); on an authorized
/// Mac it actually records, exercises pause/resume, and verifies a real video comes out.
final class CaptureIntegrationTests: XCTestCase {
    @MainActor
    func testRealScreenCaptureWithPauseResume() async throws {
        try XCTSkipUnless(PermissionStatus.screenRecording() == .authorized,
                          "screen-recording permission not granted in this environment")

        let rec = ScreenRecorder()
        let displays = try await rec.availableDisplays()
        let display = try XCTUnwrap(displays.first, "no display to capture")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclip-capture-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)

        rec.captureSystemAudio = false     // keep the test to the video path only
        rec.captureMicrophone = false
        rec.captureWebcam = false

        try await rec.start(source: .display(display.displayID), to: out)
        XCTAssertTrue(rec.isRecording)

        try await Task.sleep(nanoseconds: 1_000_000_000)   // record ~1s
        rec.pause()
        XCTAssertTrue(rec.isPaused, "pause() should flip isPaused")
        try await Task.sleep(nanoseconds: 500_000_000)     // paused span (frames dropped)
        rec.resume()
        XCTAssertFalse(rec.isPaused, "resume() should clear isPaused")
        try await Task.sleep(nanoseconds: 1_000_000_000)   // record ~1s more

        try await rec.stop()
        XCTAssertFalse(rec.isRecording)

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "output file must exist")
        let dur = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertGreaterThan(dur, 0.5, "captured video should contain real frames")
        XCTAssertLessThan(dur, 4.0, "paused span should keep duration well under wall time")
        try? FileManager.default.removeItem(at: out)
    }

    /// Records a short clip and returns its URL (nil-skips if unauthorized).
    @MainActor
    private func recordClip(seconds: Double, systemAudio: Bool) async throws -> URL {
        let rec = ScreenRecorder()
        let displays = try await rec.availableDisplays()
        let display = try XCTUnwrap(displays.first)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclip-flow-\(UUID().uuidString).mp4")
        rec.captureSystemAudio = systemAudio
        rec.captureMicrophone = false
        rec.captureWebcam = false
        try await rec.start(source: .display(display.displayID), to: out)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await rec.stop()
        return out
    }

    /// System-audio capture must add a real audio track alongside the video.
    @MainActor
    func testCaptureWithSystemAudioHasBothTracks() async throws {
        try XCTSkipUnless(PermissionStatus.screenRecording() == .authorized, "screen-recording not granted")
        let url = try await recordClip(seconds: 2.0, systemAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(video.isEmpty, "must have a video track")
        XCTAssertFalse(audio.isEmpty, "system-audio capture must produce an audio track")
    }

    /// The full user flow: record real footage, then run it through the polish→export
    /// pipeline (styled background + zoom + re-encode) and confirm a valid file comes out.
    @MainActor
    func testCaptureThenStyledExportAndReencode() async throws {
        try XCTSkipUnless(PermissionStatus.screenRecording() == .authorized, "screen-recording not granted")
        let src = try await recordClip(seconds: 2.0, systemAudio: false)
        defer { try? FileManager.default.removeItem(at: src) }

        var style = StyleOptions()
        style.background = .gradient(topRGB: (0.2, 0.3, 0.9), bottomRGB: (0.6, 0.3, 0.9))
        style.paddingFraction = 0.08
        style.shadowOpacity = 0.4
        var zoom = ZoomTimeline()
        zoom.addRegion(start: 0.3, end: 1.2, depth: .medium, focus: CGPoint(x: 0.5, y: 0.5))

        // Preset export path.
        let styled = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-styled-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: styled) }
        try await StyledExport.export(source: src, to: styled, style: style, zoom: zoom)
        let styledDur = try await AVURLAsset(url: styled).load(.duration).seconds
        XCTAssertGreaterThan(styledDur, 0.5, "styled export of real footage should be valid")

        // Re-encode path (explicit fps/bitrate) on the same real footage.
        let reenc = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-reenc-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: reenc) }
        try await StyledExport.exportReencoded(source: src, to: reenc, style: style, zoom: zoom, frameRate: .fps30)
        let reencDur = try await AVURLAsset(url: reenc).load(.duration).seconds
        XCTAssertGreaterThan(reencDur, 0.5, "re-encode of real footage should be valid")
    }

    // NOTE: Window capture (`.window` source / `availableWindows()`) can't run in the
    // headless XCTest runner — it needs a window-server-connected process and aborts with
    // `CGS_REQUIRE_INIT` otherwise. It shares the exact append/writer path proven by the
    // display-capture tests (only the SCContentFilter differs) and is exercised by the
    // live .app (which offers a Window source toggle and runs window-server-connected).
    // Verified there rather than here to avoid crashing the suite.

    /// Records with the cursor sampler running, then exports with the cursor track + a
    /// blur annotation + a burned-in caption — the full overlay stack on real footage.
    @MainActor
    func testCaptureThenOverlaysAndGif() async throws {
        try XCTSkipUnless(PermissionStatus.screenRecording() == .authorized, "screen-recording not granted")

        // Record with the cursor sampler active (ScreenRecorder starts it), so a real
        // cursor sidecar track is written next to the movie.
        let rec = ScreenRecorder()
        let displays = try await rec.availableDisplays()
        let display = try XCTUnwrap(displays.first)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-ov-\(UUID().uuidString).mp4")
        rec.captureSystemAudio = false; rec.captureMicrophone = false; rec.captureWebcam = false
        try await rec.start(source: .display(display.displayID), to: src)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await rec.stop()
        defer { try? FileManager.default.removeItem(at: src) }

        // Load the real cursor track the recorder saved beside the movie.
        let cursorTrack = CursorTrack.load(besides: src)
        var cursorStyle = CursorStyle(); cursorStyle.enabled = true; cursorStyle.kind = .arrow

        var blur = Annotation(text: "", start: 0.2, end: 1.5)
        blur.kind = .blur; blur.position = CGPoint(x: 0.3, y: 0.3)
        blur.regionSize = CGSize(width: 0.2, height: 0.15); blur.blurRadius = 28
        let cues = [CaptionCue(text: "Recorded on device", start: 0.2, end: 1.8)]
        var caps = CaptionSettings(); caps.enabled = true

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-ov-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await StyledExport.export(source: src, to: out, style: StyleOptions(),
                                      annotations: [blur], cursor: cursorTrack, cursorStyle: cursorStyle,
                                      captions: cues, captionSettings: caps)
        let ovDur = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertGreaterThan(ovDur, 0.5, "overlay export of real footage should be valid")

        // GIF from real footage.
        let gif = FileManager.default.temporaryDirectory.appendingPathComponent("reclip-ov-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gif) }
        try await GifExport.export(source: src, to: gif, style: StyleOptions(), fps: 8, maxWidth: GifSize.medium.maxWidth)
        let gifSource = CGImageSourceCreateWithURL(gif as CFURL, nil)
        XCTAssertNotNil(gifSource)
        XCTAssertGreaterThan(CGImageSourceGetCount(gifSource!), 1, "GIF from real footage should have frames")
    }
}
