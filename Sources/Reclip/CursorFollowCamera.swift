import CoreGraphics

/// Cursor-follow camera — while zoomed in, keeps a persistent camera center and only
/// recenters after the cursor leaves an inner "safe zone", shifting just enough to bring
/// the cursor back inside it. Port of Recordly's `cursorFollowCamera.ts`. This gives the
/// smooth "the zoomed view follows my pointer" behaviour instead of a fixed focus point.
struct CursorFollowCamera {
    var initialized = false
    var lastTimeMs = 0.0
    var focusX = 0.5
    var focusY = 0.5
    var wasZoomed = false
    var reachedFullZoom = false
    var frozenFocusX = 0.5
    var frozenFocusY = 0.5

    static let defaultSafeZoneRatio = 0.25

    /// Half the visible span (normalized) at a given zoom scale.
    static func halfSpan(_ scale: Double) -> Double { 0.5 / max(scale, 1.0) }

    /// Clamps a focus so the zoomed viewport stays within [0,1] on both axes.
    static func clampFocus(_ fx: Double, _ fy: Double, scale: Double) -> (Double, Double) {
        let h = halfSpan(scale)
        guard h <= 0.5 else { return (0.5, 0.5) }
        return (min(max(fx, h), 1 - h), min(max(fy, h), 1 - h))
    }

    private mutating func recenter(cursorX: Double, cursorY: Double,
                                   scale: Double, safeZoneRatio: Double) -> (Double, Double) {
        let half = CursorFollowCamera.halfSpan(scale)
        let inset = (half * 2) * min(max(safeZoneRatio, 0), 0.49)
        let safeLeft = focusX - half + inset, safeRight = focusX + half - inset
        let safeTop = focusY - half + inset, safeBottom = focusY + half - inset
        var nx = focusX, ny = focusY
        if cursorX < safeLeft || cursorX > safeRight { nx = cursorX }
        if cursorY < safeTop || cursorY > safeBottom { ny = cursorY }
        return CursorFollowCamera.clampFocus(nx, ny, scale: scale)
    }

    /// Camera focus for this frame, updating internal state. `zoomStrength` is the eased
    /// ramp envelope (0 = no zoom, 1 = fully zoomed); `regionFocus` is the region's target.
    mutating func focus(cursorX: Double?, cursorY: Double?, timeMs: Double,
                        zoomScale: Double, zoomStrength: Double,
                        regionFocus: CGPoint,
                        safeZoneRatio: Double = defaultSafeZoneRatio) -> CGPoint {
        let (rcx, rcy) = CursorFollowCamera.clampFocus(regionFocus.x, regionFocus.y, scale: zoomScale)

        // Not zoomed: reset and return the region focus.
        if zoomStrength < 0.01 {
            if wasZoomed { wasZoomed = false; initialized = false; reachedFullZoom = false }
            return CGPoint(x: rcx, y: rcy)
        }
        // No cursor sample: hold the last camera (or region focus if uninitialized).
        guard let cx = cursorX, let cy = cursorY else {
            return initialized ? CGPoint(x: focusX, y: focusY) : CGPoint(x: rcx, y: rcy)
        }
        if zoomStrength >= 0.99 { reachedFullZoom = true }
        // Zooming out after having been fully zoomed: freeze the camera.
        if reachedFullZoom && zoomStrength < 0.99 {
            return CGPoint(x: frozenFocusX, y: frozenFocusY)
        }
        let timeWentBackwards = initialized && timeMs + 0.5 < lastTimeMs
        if !initialized || !wasZoomed || timeWentBackwards {
            lastTimeMs = timeMs; initialized = true; wasZoomed = true
            focusX = rcx; focusY = rcy; frozenFocusX = rcx; frozenFocusY = rcy
            return CGPoint(x: rcx, y: rcy)
        }
        lastTimeMs = timeMs
        let (nx, ny) = recenter(cursorX: cx, cursorY: cy, scale: zoomScale, safeZoneRatio: safeZoneRatio)
        focusX = nx; focusY = ny; frozenFocusX = nx; frozenFocusY = ny
        return CGPoint(x: nx, y: ny)
    }
}
