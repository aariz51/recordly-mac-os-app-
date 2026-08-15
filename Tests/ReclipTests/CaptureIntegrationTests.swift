import XCTest
import AVFoundation
import ScreenCaptureKit
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
}
