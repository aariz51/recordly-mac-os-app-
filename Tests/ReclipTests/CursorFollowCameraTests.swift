import XCTest
import CoreGraphics
@testable import Reclip

final class CursorFollowCameraTests: XCTestCase {

    func testNotZoomedReturnsRegionFocus() {
        var cam = CursorFollowCamera()
        let f = cam.focus(cursorX: 0.9, cursorY: 0.1, timeMs: 0, zoomScale: 2, zoomStrength: 0.0,
                          regionFocus: CGPoint(x: 0.4, y: 0.6))
        XCTAssertEqual(f.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(f.y, 0.6, accuracy: 1e-9)
    }

    func testFirstZoomedFrameInitializesToRegionFocus() {
        var cam = CursorFollowCamera()
        let f = cam.focus(cursorX: 0.5, cursorY: 0.5, timeMs: 0, zoomScale: 2, zoomStrength: 1.0,
                          regionFocus: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(f.x, 0.5, accuracy: 1e-9)
        XCTAssertTrue(cam.initialized)
    }

    func testCursorInsideSafeZoneKeepsFocus() {
        var cam = CursorFollowCamera()
        _ = cam.focus(cursorX: 0.5, cursorY: 0.5, timeMs: 0, zoomScale: 2, zoomStrength: 1.0,
                      regionFocus: CGPoint(x: 0.5, y: 0.5))
        // At 2x, halfSpan=0.25, inset=0.5*0.25=0.125 → safe zone is [0.375,0.625]. Cursor at 0.55 is inside.
        let f = cam.focus(cursorX: 0.55, cursorY: 0.55, timeMs: 100, zoomScale: 2, zoomStrength: 1.0,
                          regionFocus: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(f.x, 0.5, accuracy: 1e-9, "focus unchanged while cursor stays in safe zone")
        XCTAssertEqual(f.y, 0.5, accuracy: 1e-9)
    }

    func testCursorLeavingSafeZoneShiftsFocus() {
        var cam = CursorFollowCamera()
        _ = cam.focus(cursorX: 0.5, cursorY: 0.5, timeMs: 0, zoomScale: 2, zoomStrength: 1.0,
                      regionFocus: CGPoint(x: 0.5, y: 0.5))
        // Cursor jumps to 0.7 (> safeRight 0.625) → focus recenters toward it, clamped to ≤0.75.
        let f = cam.focus(cursorX: 0.7, cursorY: 0.5, timeMs: 100, zoomScale: 2, zoomStrength: 1.0,
                          regionFocus: CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(f.x, 0.5, "camera pans toward the cursor")
        XCTAssertLessThanOrEqual(f.x, 0.75 + 1e-9, "focus clamped so the view stays on-screen")
    }

    func testFocusClampKeepsViewOnScreen() {
        // At 2x, focus must stay within [0.25, 0.75].
        let (cx, _) = CursorFollowCamera.clampFocus(0.95, 0.5, scale: 2)
        XCTAssertEqual(cx, 0.75, accuracy: 1e-9)
        let (cx2, _) = CursorFollowCamera.clampFocus(0.02, 0.5, scale: 2)
        XCTAssertEqual(cx2, 0.25, accuracy: 1e-9)
    }

    func testZoomingOutFreezesCamera() {
        var cam = CursorFollowCamera()
        _ = cam.focus(cursorX: 0.5, cursorY: 0.5, timeMs: 0, zoomScale: 2, zoomStrength: 1.0,
                      regionFocus: CGPoint(x: 0.5, y: 0.5))
        // pan the camera by moving the cursor out of the zone at full zoom
        let panned = cam.focus(cursorX: 0.72, cursorY: 0.5, timeMs: 100, zoomScale: 2, zoomStrength: 1.0,
                               regionFocus: CGPoint(x: 0.5, y: 0.5))
        // now zoom out (strength < 0.99) → focus frozen at the panned value regardless of cursor
        let frozen = cam.focus(cursorX: 0.1, cursorY: 0.1, timeMs: 200, zoomScale: 2, zoomStrength: 0.5,
                               regionFocus: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(frozen.x, panned.x, accuracy: 1e-9, "camera frozen during zoom-out")
    }
}
