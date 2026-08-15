import XCTest
import CoreGraphics
@testable import Reclip

/// A `.reclip` project must round-trip every editor setting through JSON with no loss.
final class ReclipProjectTests: XCTestCase {

    func testProjectRoundTrip() throws {
        var style = StyleOptions()
        style.paddingFraction = 0.09
        style.cornerRadiusFraction = 0.04
        style.shadowOpacity = 0.5
        style.backgroundBlur = 3
        style.aspect = .vertical
        style.crop = StyleOptions.CropInsets(top: 0.1, bottom: 0.05, left: 0.02, right: 0.03)
        style.background = .solid(red: 0.2, green: 0.4, blue: 0.6)

        var zoom = ZoomTimeline(regions: [
            ZoomRegion(start: 1, end: 3, scale: 2.2, focus: CGPoint(x: 0.4, y: 0.6))
        ])
        zoom.easing = .snappy
        var cam = WebcamSettings()
        cam.enabled = true; cam.mirror = false; cam.roundness = 0.5
        cam.corner = .topLeading; cam.marginFraction = 0.07; cam.sizeFraction = 0.3; cam.aspectRatio = 0.7
        var blur = Annotation(text: "", start: 0.3, end: 1.2)
        blur.kind = .blur; blur.blurRadius = 30; blur.regionSize = CGSize(width: 0.2, height: 0.15)
        let caps = [
            Annotation(text: "Hi", start: 0.5, end: 2.0, position: CGPoint(x: 0.5, y: 0.2), fontFraction: 0.06),
            blur
        ]
        var cs = CursorStyle(); cs.enabled = true; cs.kind = .dot; cs.size = 2.0
        let cues = [CaptionCue(text: "Subtitle", start: 0, end: 1)]

        let project = ReclipProject.capture(
            source: URL(fileURLWithPath: "/tmp/rec.mp4"),
            style: style, zoom: zoom, webcam: cam, annotations: caps,
            trimStart: 0.2, trimEnd: 4.0, speed: 1.5,
            cursorStyle: cs, captionCues: cues, captionsEnabled: true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip.reclip")
        try? FileManager.default.removeItem(at: url)
        try project.save(to: url)
        let loaded = try ReclipProject.load(from: url)

        // The serialized form survives losslessly.
        XCTAssertEqual(loaded, project)

        // And it reconstructs the runtime types (ZoomRegion/Annotation carry a fresh
        // identity UUID by design, so compare their data rather than full equality).
        XCTAssertEqual(loaded.style(), style)
        XCTAssertEqual(loaded.webcamSettings(), cam)
        let zr = loaded.zoomTimeline().regions
        XCTAssertEqual(zr.count, 1)
        XCTAssertEqual(zr.first?.start ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(zr.first?.end ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(Double(zr.first?.scale ?? 0), 2.2, accuracy: 1e-9)
        XCTAssertEqual(zr.first?.focus.x ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(zr.first?.focus.y ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(loaded.trimStart, 0.2, accuracy: 1e-9)
        XCTAssertEqual(loaded.trimEnd, 4.0, accuracy: 1e-9)
        XCTAssertEqual(loaded.speed, 1.5, accuracy: 1e-9)

        // Zoom easing persists.
        XCTAssertEqual(loaded.zoomTimeline().easing, .snappy)

        // Both annotations (text + blur) round-trip with their kind + data.
        let restored = loaded.annotationList()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first?.text, "Hi")
        let blurBack = restored.first(where: { $0.kind == .blur })
        XCTAssertNotNil(blurBack)
        XCTAssertEqual(blurBack?.blurRadius ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(blurBack?.regionSize.width ?? -1, 0.2, accuracy: 1e-9)

        // Cursor style + caption cues persist.
        XCTAssertEqual(loaded.cursorStyleValue(), cs)
        XCTAssertEqual(loaded.captionCueList().count, 1)
        XCTAssertEqual(loaded.captionCueList().first?.text, "Subtitle")
        XCTAssertTrue(loaded.captionsEnabled)
    }

    func testDirtyStateTracking() {
        var style = StyleOptions(); style.paddingFraction = 0.05
        let base = ReclipProject.capture(
            source: URL(fileURLWithPath: "/tmp/d.mp4"),
            style: style, zoom: ZoomTimeline(), webcam: WebcamSettings(),
            annotations: [], trimStart: 0, trimEnd: 0, speed: 1.0)

        var doc = DocumentState()
        XCTAssertFalse(doc.hasEverBeenSaved)
        XCTAssertTrue(doc.isDirty(base), "never-saved project is dirty")

        doc.markSaved(base)
        XCTAssertTrue(doc.hasEverBeenSaved)
        XCTAssertFalse(doc.isDirty(base), "identical to saved baseline → clean")

        var edited = style; edited.paddingFraction = 0.2
        let changed = ReclipProject.capture(
            source: URL(fileURLWithPath: "/tmp/d.mp4"),
            style: edited, zoom: ZoomTimeline(), webcam: WebcamSettings(),
            annotations: [], trimStart: 0, trimEnd: 0, speed: 1.0)
        XCTAssertTrue(doc.isDirty(changed), "an edit flips dirty")

        doc.markSaved(changed)
        XCTAssertFalse(doc.isDirty(changed), "re-saving clears dirty")
    }

    func testGradientAndSourceAspectRoundTrip() throws {
        var style = StyleOptions()
        style.background = .gradient(topRGB: (0.1, 0.2, 0.3), bottomRGB: (0.4, 0.5, 0.6))
        style.aspect = .source
        let project = ReclipProject.capture(
            source: URL(fileURLWithPath: "/tmp/x.mp4"),
            style: style, zoom: ZoomTimeline(), webcam: WebcamSettings(),
            annotations: [], trimStart: 0, trimEnd: 0, speed: 1.0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grad.reclip")
        try project.save(to: url)
        let loaded = try ReclipProject.load(from: url)
        XCTAssertEqual(loaded.style(), style)
        XCTAssertEqual(loaded.style().aspect, .source)
    }
}
