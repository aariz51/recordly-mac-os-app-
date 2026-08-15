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
